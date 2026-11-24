#!/usr/bin/env bash
# Validate the restored source cache against what the package declares.
#
# The cache is a build accelerator, never a source of truth: a file that the
# cache returned but that no longer matches the package's declared checksum
# must not be handed to makepkg. makepkg prints `-> Found <name>` for any file
# already sitting in SRCDEST and does NOT re-fetch it, so a stale entry fails
# the validity check in exactly the same way a genuinely changed upstream
# source would -- and re-running the build can never tell the two apart.
#
# This script runs before the build and settles the question by content:
#
#   * Git sources        -- makepkg clones with `git clone --mirror`, so a
#                           healthy entry is a bare repository and carries no
#                           .git directory at all. The cached remote must be
#                           the declared remote.
#   * Dependency caches  -- the same SRCDEST is exported into the AUR
#                           dependency builds yay performs for this package,
#                           so those mirrors land in this directory without
#                           ever appearing in the package's own source list.
#                           The directory is therefore swept as a whole: an
#                           entry that names no readable upstream cannot be a
#                           clone of anything and is removed, one that does is
#                           left alone.
#   * Remote file sources -- a same-named file in the package directory wins
#                           over both SRCDEST and the network, because makepkg
#                           resolves $startdir first for every non-VCS source.
#                           It is therefore hashed like a local source, and a
#                           mismatch is a repository defect. Otherwise the
#                           cached copy is hashed; a mismatch means the cache
#                           is stale, so the entry is deleted and the build
#                           re-fetches it in this same run.
#   * Local file sources  -- the repository's own copy is hashed. A mismatch
#                           there is a defect in the repository (the declared
#                           checksum does not describe the committed file), not
#                           something a cache can repair, so the script fails
#                           fast with the file named instead of letting makepkg
#                           fail ten minutes later with a generic message.
#
# Usage: validate-source-cache.sh <package-dir> <source-cache-dir>
# Exit:  0 clean (or healed), 1 repository defect, 2 usage error.

set -Eeuo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <package-dir> <source-cache-dir>\n' "$0" >&2
    exit 2
fi

package_dir="$1"
source_cache_dir="$2"

[[ -f "${package_dir}/.SRCINFO" ]] || {
    printf 'Missing .SRCINFO: %s\n' "${package_dir}" >&2
    exit 2
}

# A healthy cache entry is a *bare* mirror (makepkg runs `git clone --mirror`),
# so testing for a .git subdirectory declared every healthy entry a collision
# and deleted it: the build re-cloned the whole source on every run, and the
# check could never tell that apart from a genuinely broken directory.
is_git_cache() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    [[ -d "$path/.git" ]] && return 0
    local inside
    inside="$(git -C "$path" -c safe.bareRepository=all rev-parse --is-bare-repository 2>/dev/null || true)"
    [[ "$inside" == "true" ]]
}

# -c safe.bareRepository=all: the same escape makepkg uses, so a global
# safe.bareRepository=explicit cannot make a legitimate bare mirror unreadable
# and turn it into a false "stale" verdict.
git_cache_remote() {
    local path="$1"
    git -C "$path" -c safe.bareRepository=all config --get remote.origin.url 2>/dev/null || true
}

canonical_git_url() {
    local url="$1"
    url="${url%%#*}"
    url="${url%/}"
    printf '%s' "${url%.git}"
}

# makepkg's file name for a source entry: `name::url` names it explicitly,
# otherwise it is the last path component of the URL (or of the local path).
source_filename() {
    local spec="$1"
    if [[ "$spec" == *"::"* ]]; then
        printf '%s' "${spec%%::*}"
        return
    fi
    local path="${spec#git+}"
    path="${path%%#*}"
    path="${path%%\?*}"
    printf '%s' "${path##*/}"
}

# Hash a file with the one algorithm the package declares. Every .SRCINFO in
# this repository uses sha256sums; an unknown or absent declaration returns an
# empty string so the caller can skip instead of guessing.
file_digest() {
    local file="$1" sum="$2"
    case "${#sum}" in
        64) sha256sum -- "$file" | cut -d' ' -f1 ;;
        128) sha512sum -- "$file" | cut -d' ' -f1 ;;
        32) md5sum -- "$file" | cut -d' ' -f1 ;;
        *) printf '' ;;
    esac
}

# `source` and `sha256sums` are positional arrays aligned by index.
mapfile -t sources < <(awk -F ' = ' '$1 ~ /^[[:space:]]*source$/ { print $2 }' "${package_dir}/.SRCINFO")
mapfile -t sums < <(awk -F ' = ' '$1 ~ /^[[:space:]]*sha256sums$/ { print $2 }' "${package_dir}/.SRCINFO")

if (( ${#sums[@]} > 0 && ${#sums[@]} != ${#sources[@]} )); then
    printf 'WARNING: %s declares %s source(s) but %s sha256sums entry/entries; skipping per-file checks.\n' \
        "${package_dir}" "${#sources[@]}" "${#sums[@]}" >&2
    sums=()
fi

checked=0
healed=0
verified_local=0
defects=0
# Names this package declares as git sources; the sweep below must not second
# guess an entry the loop already verified.
declare -A declared_git_names=()

for (( i = 0; i < ${#sources[@]}; i++ )); do
    spec="${sources[i]}"
    [[ -n "$spec" ]] || continue
    expected="${sums[i]:-}"

    if [[ "$spec" == *"git+"* ]]; then
        if [[ "$spec" == *"::git+"* ]]; then
            name="${spec%%::*}"
            url="${spec#*::git+}"
        else
            url="${spec#git+}"
            name="${url%%#*}"
            name="${name##*/}"
            name="${name%.git}"
        fi

        cache_path="${source_cache_dir}/${name}"
        declared_git_names["$name"]=1
        [[ -e "$cache_path" ]] || continue

        if ! is_git_cache "$cache_path"; then
            printf 'Removing non-git source cache collision: %s\n' "$cache_path"
            rm -rf "$cache_path"
            healed=$(( healed + 1 ))
            continue
        fi

        remote="$(git_cache_remote "$cache_path")"
        if [[ "$(canonical_git_url "$remote")" == "$(canonical_git_url "$url")" ]]; then
            continue
        fi

        printf 'Removing stale git source cache: %s\n' "$cache_path"
        printf '  cached: %s\n' "$remote"
        printf '  needed: %s\n' "${url%%#*}"
        rm -rf "$cache_path"
        healed=$(( healed + 1 ))
        continue
    fi

    name="$(source_filename "$spec")"
    [[ -n "$name" ]] || continue

    if [[ "$spec" == *"://"* ]]; then
        # makepkg resolves $startdir/<name> before SRCDEST for URL-declared
        # files too, so a committed copy of the same name is what actually gets
        # hashed. If it disagrees with the declaration, the build cannot pass
        # regardless of what the cache holds -- that is a repository defect, not
        # a stale cache, and deleting it here would silently switch the build to
        # the network copy.
        local_path="${package_dir}/${name}"
        if [[ -f "$local_path" && -n "$expected" && "$expected" != "SKIP" ]]; then
            actual="$(file_digest "$local_path" "$expected")"
            verified_local=$(( verified_local + 1 ))
            if [[ -n "$actual" && "$actual" != "$expected" ]]; then
                printf 'ERROR: %s shadows the remote source declared for %s and does not match its checksum.\n' \
                    "$local_path" "$name" >&2
                printf '  actual:   %s\n' "$actual" >&2
                printf '  declared: %s\n' "$expected" >&2
                printf 'makepkg prefers the package directory copy over the source cache, so this file is what the build would hash.\n' >&2
                defects=$(( defects + 1 ))
            fi
        fi

        # Remote file: the cached copy is what makepkg would hash when the
        # package directory has no copy of its own.
        cache_path="${source_cache_dir}/${name}"
        [[ -f "$cache_path" ]] || continue
        [[ -n "$expected" && "$expected" != "SKIP" ]] || continue

        actual="$(file_digest "$cache_path" "$expected")"
        checked=$(( checked + 1 ))
        if [[ -z "$actual" ]]; then
            printf 'WARNING: cannot hash %s with the declared checksum format; leaving it alone.\n' "$cache_path" >&2
            continue
        fi
        if [[ "$actual" == "$expected" ]]; then
            continue
        fi

        printf 'Removing stale source cache entry: %s\n' "$cache_path"
        printf '  cached:  %s\n' "$actual"
        printf '  declared:%s\n' "$expected"
        printf '  the build will re-fetch it from %s\n' "${spec#*::}"
        rm -f "$cache_path"
        healed=$(( healed + 1 ))
        continue
    fi

    # Local file: the repository's own copy is authoritative (makepkg prefers
    # $startdir over $SRCDEST), so a mismatch here is a repository defect.
    local_path="${package_dir}/${name}"
    [[ -f "$local_path" ]] || continue
    [[ -n "$expected" && "$expected" != "SKIP" ]] || continue

    actual="$(file_digest "$local_path" "$expected")"
    verified_local=$(( verified_local + 1 ))
    [[ -n "$actual" ]] || continue
    if [[ "$actual" != "$expected" ]]; then
        printf 'ERROR: %s does not match its declared checksum.\n' "$local_path" >&2
        printf '  actual:   %s\n' "$actual" >&2
        printf '  declared: %s\n' "$expected" >&2
        printf 'The file is part of this repository and the checksum describes a different revision of it.\n' >&2
        defects=$(( defects + 1 ))
    fi
done

# ---------------------------------------------------------------------------
# Sweep the directory, not just the declaration.
#
# $SRCDEST is a single directory per package (build-in-arch.sh:12,
# build-in-clean-chroot.sh:154) and the AUR dependency builds yay performs for
# that package export the same $SRCDEST, so their mirrors land here too -- and
# they appear in no source list at all. The loop above can only check what the
# package declares, which is exactly how a corrupted dependency mirror survived
# a full rebuild in the ffmpeg-full incident: makepkg found an existing
# directory, compared its remote, printed "%s is not a clone of %s" and aborted
# before anything hashed. Nothing in the declaration could see it.
#
# Without the expected URL for an undeclared entry there is no way to judge
# *which* upstream it should point at, so this only decides what is objectively
# broken: a directory that is not a git repository, or one whose origin remote
# cannot be read, can be a clone of nothing. Those are removed and the owning
# build re-clones. A structurally sound mirror is left alone -- guessing at its
# intended URL would delete working caches.
swept=0
if [[ -d "$source_cache_dir" ]]; then
    for entry in "$source_cache_dir"/*; do
        [[ -d "$entry" ]] || continue
        base="${entry##*/}"
        [[ -n "${declared_git_names[$base]:-}" ]] && continue
        if [[ ! -f "$entry/HEAD" && ! -f "$entry/config" ]]; then
            printf 'Removing non-git source cache collision: %s\n' "$entry"
            rm -rf "$entry"
            healed=$(( healed + 1 ))
            continue
        fi
        if ! is_git_cache "$entry" || [[ -z "$(git_cache_remote "$entry")" ]]; then
            printf 'Removing unreadable dependency source cache: %s\n' "$entry"
            printf '  makepkg aborts on an existing cache directory whose origin remote it cannot read,\n'
            printf '  before it fetches or hashes anything; the dependency build re-clones it.\n'
            rm -rf "$entry"
            healed=$(( healed + 1 ))
            continue
        fi
        swept=$(( swept + 1 ))
    done
fi

if (( defects > 0 )); then
    printf 'Source cache validation failed: %s source(s) do not match their declared checksum.\n' "$defects" >&2
    exit 1
fi

if (( healed > 0 || checked > 0 || verified_local > 0 )); then
    printf 'Source cache: %s cached file(s) verified, %s stale entry/entries removed, %s local source(s) verified.\n' \
        "$checked" "$healed" "$verified_local"
fi

if (( swept > 0 )); then
    printf 'Source cache: %s dependency mirror(s) present and readable.\n' "$swept"
fi
