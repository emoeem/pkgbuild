#!/usr/bin/env bash
# Detect published packages whose linked SONAMEs are no longer provided by the
# current repositories.
#
# Runs inside the container used by the build and maintenance workflows — the
# repository's own builder image, ghcr.io/<owner>/pkgbuild-builder:latest, which
# is built FROM the official CachyOS x86-64-v3 image — because it needs pacman,
# expac and bsdtar. That image is pulled anonymously from GHCR; the CachyOS base
# image on Docker Hub is not, and an unauthenticated Docker Hub pull is rate
# limited per runner IP (`toomanyrequests`, run 37989749507, `docker run` exit
# 125). Every input is a path, so the script can also be exercised by hand in
# that container.
#
# Usage: check-repository-sonames.sh <published-dir> <out-dir> <packages-dir>
#
#   <published-dir>  directory holding the downloaded *.pkg.tar.zst files
#   <out-dir>        receives report.txt, stale.txt and orphans.txt
#   <packages-dir>   repository source tree: a published package that no longer
#                    exists there is reported as an orphan instead of being
#                    dispatched as a rebuild, pkgname/pkgbase entries are mapped
#                    back to their source directory name, and the per-package
#                    packages/<dir>/.rebuild-on declarations are read from it
#
# Why the provider set is built from file inventories instead of only from
# `expac -S '%P'`:
#
#   * pacman SONAME provides use a different spelling than the dynamic
#     linker: the repository advertises `libx264.so=165-64` while the ELF
#     object asks for `libx264.so.165`. Matching one against the other never
#     succeeds, which is what made this check flag every package.
#   * several packages ship libraries without declaring any SONAME provide at
#     all (glibc: libc.so.6, ld-linux-x86-64.so.2; gcc-libs does not provide
#     libstdc++.so=6-64 here; openapv: liboapv.so.1). Those can only be
#     recognised from the file list of the repositories.

set -Eeuo pipefail

# Force the C locale: the checks below parse tool output (readelf, pacman,
# ldd, ...) whose labels are localized, and a translated label silently
# turns the check into a no-op instead of failing loudly.
export LC_ALL=C

published="${1:?usage: $0 <published-dir> <out-dir> [packages-dir]}"
out_dir="${2:?usage: $0 <published-dir> <out-dir> [packages-dir]}"
packages_dir="${3:-}"

[[ -d "$published" ]] || { printf 'not a directory: %s\n' "$published" >&2; exit 2; }
if [[ -z "$packages_dir" || ! -d "$packages_dir" ]]; then
    printf 'packages dir required; usage: %s <published-dir> <out-dir> <packages-dir>\n' \
        "$0" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
check_elf="${script_dir}/check-elf-needed.sh"
[[ -f "$check_elf" ]] || { printf 'missing helper: %s\n' "$check_elf" >&2; exit 2; }

mkdir -p "$out_dir"
: > "$out_dir/report.txt"
: > "$out_dir/stale.txt"
: > "$out_dir/orphans.txt"

report() { printf '%s\n' "$*" >> "$out_dir/report.txt"; }

# ---------------------------------------------------------------------------
# Same repositories as the build container, plus the published one. The
# provider set below can only be correct when those repositories are present,
# so a failure to configure them is fatal here.
# ---------------------------------------------------------------------------
if ! bash "${script_dir}/setup-container-repos.sh"; then
    printf 'third-party repositories unavailable; refusing to report false positives\n' >&2
    exit 3
fi
if ! grep -qx '\[emoeem\]' /etc/pacman.conf; then
    printf '\n[emoeem]\nSigLevel = Never\nServer = file://%s\n' "$published" >> /etc/pacman.conf
fi
pacman -Syu --noconfirm expac > /dev/null

mapfile -t repo_names < <(pacman -Slq)

# ---------------------------------------------------------------------------
# Provider set: every library name the current repositories can supply.
# ---------------------------------------------------------------------------
providers="$(mktemp)"
trap 'rm -f "$providers"' EXIT

if ! pacman -Fy > /dev/null 2>&1; then
    report "WARNING: pacman -Fy reported an error; using the file databases already present"
fi
if ! compgen -G '/var/lib/pacman/sync/*.files' > /dev/null; then
    printf 'no pacman files database available; refusing to report false positives\n' >&2
    exit 3
fi

{
    # 1. every file shipped by any repository package (the authoritative list
    #    for libraries that declare no SONAME provide)
    for db in /var/lib/pacman/sync/*.files; do
        bsdtar -xOf "$db" --include '*/files' 2>/dev/null || true
    done
    # 2. files shipped by the published packages themselves: the release file
    #    database can lag behind and a package may link against a library it
    #    ships itself (ffmpeg-full -> libavcodec.so.63)
    for package_file in "$published"/*.pkg.tar.zst; do
        [[ -e "$package_file" ]] || continue
        bsdtar -tf "$package_file" 2>/dev/null || true
    done
    # 3. declared SONAME provides, normalised to linker spelling:
    #    libx264.so=165-64 -> libx264.so.165
    expac -S '%P' "${repo_names[@]}" 2>/dev/null | tr ' ' '\n' |
        sed -nE 's/^(.*[.]so)=([0-9][0-9.]*)(-[0-9]+)?$/\1.\2/p'
    # 4. libraries installed in this container
    find /usr/lib /lib -maxdepth 1 -name '*.so*' -printf '%f\n' 2>/dev/null || true
    # Only shared libraries can satisfy a NEEDED entry; dropping the rest keeps
    # the table small (a full inventory is a few hundred thousand names).
} | sed 's:.*/::' | sed -n '/[.]so/p' | sed '/^$/d' | sort -u > "$providers"
provider_count="$(wc -l < "$providers")"
report "providers: ${provider_count} library names from the configured repositories"
if (( provider_count < 100 )); then
    printf 'provider list looks empty (%s entries); refusing to report false positives\n' \
        "$provider_count" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Source tree: map every pkgname/pkgbase back to its package directory so the
# rebuild dispatch can only ever contain directories that really exist.
# ---------------------------------------------------------------------------
declare -A source_dir=()
if [[ -n "$packages_dir" && -d "$packages_dir" ]]; then
    for dir in "$packages_dir"/*/; do
        [[ -f "${dir}PKGBUILD" ]] || continue
        directory="$(basename "$dir")"
        source_dir["$directory"]="$directory"
        [[ -f "${dir}.SRCINFO" ]] || continue
        while IFS= read -r name; do
            [[ -n "$name" ]] && source_dir["$name"]="$directory"
        done < <(awk -F ' = ' '$1 == "pkgbase" || $1 == "pkgname" { print $2 }' "${dir}.SRCINFO")
    done
fi

# ---------------------------------------------------------------------------
# Per-package declarations: packages/<dir>/.rebuild-on names the sonames a
# package links against that come from repositories the containers do not
# configure (archlinuxcn / arch4edu / AUR).  Those names used to live in one
# global list, and a global entry silenced the same missing library for *every*
# package; applying a declaration only to the package that declares it keeps
# the check honest, and lets a declaration that no longer matches the artifact
# fail the run instead of silently widening the exemption.
# ---------------------------------------------------------------------------
list_triggers="${script_dir}/list-rebuild-triggers.sh"
[[ -f "$list_triggers" ]] || { printf 'missing helper: %s\n' "$list_triggers" >&2; exit 2; }

declare -A declared_sonames=()
declared_total=0
triggers_file="$(mktemp)"
if ! bash "$list_triggers" "$packages_dir" > "$triggers_file"; then
    rm -f "$triggers_file"
    printf 'invalid .rebuild-on declarations under %s; refusing to guess\n' "$packages_dir" >&2
    exit 3
fi
while IFS=$'\t' read -r kind package soname _provider; do
    [[ "$kind" == "soname" ]] || continue
    declared_sonames["$package"]+="${soname} "
    declared_total=$((declared_total + 1))
done < "$triggers_file"
rm -f "$triggers_file"
report "declared external sonames: ${declared_total} across ${#declared_sonames[@]} package(s)"

# ---------------------------------------------------------------------------
# Inspect every published package.
# ---------------------------------------------------------------------------
declared_errors=0
for package_file in "$published"/*.pkg.tar.zst; do
    [[ -e "$package_file" ]] || continue
    pkgname="$(bsdtar -xOf "$package_file" .BUILDINFO 2>/dev/null |
        awk -F ' = ' '$1 == "pkgname" { print $2; exit }')"
    [[ -n "$pkgname" ]] || continue

    declared="$(bsdtar -xOf "$package_file" .PKGINFO .BUILDINFO 2>/dev/null |
        awk -F ' = ' '$1 == "depend" || $1 == "depends" { print $2 }' |
        grep '\.so=' | sort -u | tr '\n' ' ' || true)"

    directory="${source_dir[$pkgname]:-}"
    declared_for_package="${declared_sonames[$directory]:-}"

    tmpdir="$(mktemp -d)"
    bsdtar -xf "$package_file" -C "$tmpdir"

    # A declaring package gets its own provider set: the shared table plus the
    # sonames it declared.  Everything else keeps the strict table, so a package
    # that never declared libshine.so.3 is still reported when it starts linking
    # against it.
    package_providers="$providers"
    if [[ -n "$declared_for_package" ]]; then
        package_providers="$(mktemp)"
        {
            cat "$providers"
            tr ' ' '\n' <<<"$declared_for_package"
        } | sed '/^$/d' | sort -u > "$package_providers"
    fi

    missing_elf=""
    if ! missing_elf="$(bash "$check_elf" "$tmpdir" "$package_providers")"; then
        :
    fi

    # The declaration has to match the artifact: a soname listed in .rebuild-on
    # that the published package does not actually NEED is a stale exemption.
    declared_mismatch=""
    if [[ -n "$declared_for_package" ]]; then
        declared_file="$(mktemp)"
        tr ' ' '\n' <<<"$declared_for_package" | sed '/^$/d' > "$declared_file"
        if ! declared_mismatch="$(bash "$check_elf" --require-needed "$tmpdir" "$declared_file")"; then
            :
        fi
        rm -f "$declared_file"
    fi

    [[ "$package_providers" == "$providers" ]] || rm -f "$package_providers"
    rm -rf "$tmpdir"

    if [[ -n "$declared_mismatch" ]]; then
        declared_errors=$((declared_errors + 1))
        printf 'STALE-DECLARATION %s -> %s: .rebuild-on declares sonames the artifact does not NEED: %s\n' \
            "$pkgname" "$directory" "$declared_mismatch" >&2
        report "STALE-DECLARATION $pkgname -> $directory: .rebuild-on declares sonames the artifact does not NEED: $declared_mismatch"
    fi

    if [[ -z "$directory" ]]; then
        printf '%s\n' "$pkgname" >> "$out_dir/orphans.txt"
        report "ORPHAN $pkgname: published but not in the source tree (declared: ${declared:-none}; missing: ${missing_elf:-none})"
        continue
    fi

    if [[ -n "$missing_elf" ]]; then
        printf '%s\n' "$directory" >> "$out_dir/stale.txt"
        report "STALE $pkgname -> $directory: ELF NEEDED no longer provided: $missing_elf"
    else
        report "OK    $pkgname ($directory; declared soname deps: ${declared:-none}; .rebuild-on: ${declared_for_package:-none})"
    fi
done

sort -u -o "$out_dir/stale.txt" "$out_dir/stale.txt"
sort -u -o "$out_dir/orphans.txt" "$out_dir/orphans.txt"
cat "$out_dir/report.txt"
# Exit codes: 0 = clean, 2 = bad usage, 3 = unusable declarations/provider set
# (refusing to report rather than reporting nonsense), 4 = declarations that no
# longer match the artifacts (a human has to edit .rebuild-on; no rebuild can
# fix it).  maintenance.yml treats 4 as an annotation instead of a failure so a
# stale declaration cannot stop the unattended drift rebuilds.
if (( declared_errors > 0 )); then
    exit 4
fi
