#!/usr/bin/env bash
set -Eeuo pipefail

# Force the C locale: the checks below parse tool output (readelf, pacman,
# ldd, ...) whose labels are localized, and a translated label silently
# turns the check into a no-op instead of failing loudly.
export LC_ALL=C

repo_dir="${1:-}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$repo_dir" ]] || { echo "usage: $0 <published-repo-dir> [repo-root] [stale-file]" >&2; exit 2; }
stale_file="${3:-}"

if [[ -n "${LOCAL_REPO_DIR:-}" ]]; then
    local_copy="$(mktemp -d)"
    trap 'rm -rf "$local_copy"' EXIT
    cp -a "${LOCAL_REPO_DIR}/." "$local_copy/"
    shopt -s nullglob
    local_packages=("$local_copy"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#local_packages[@]} > 0 )); then
        repo-add --remove "$local_copy/emoeem.db.tar.gz" "${local_packages[@]}" >/dev/null
        printf '[emoeem]\nSigLevel = Never\nServer = file://%s\n' "$local_copy" > /tmp/emo-repo.conf
        awk '/^\[emoeem\]$/{skip=1;next} skip && /^\[/{skip=0} !skip{print}' /etc/pacman.conf >> /tmp/emo-repo.conf
        cat /tmp/emo-repo.conf > /etc/pacman.conf
        # 注册后立即同步:emoeem 内部包互相依赖时 pacman -Si 才能解析到已发布
        # 版本,否则这些依赖全部计入 unresolved,变成漏报的漂移盲区。
        pacman -Sy --noconfirm >/dev/null
    fi
fi

strip_dep() { printf '%s' "$1" | sed -E 's/[<>=].*$//'; }

# .BUILDINFO records `installed = <name>-<version>-<pkgrel>-<arch>` (for example
# `7zip-26.03-1.1-x86_64_v3`) while `pacman -Si` prints `Version : 26.03-1.1`, so
# both sides are reduced to `<version>-<pkgrel>` before comparing.  The pkgrel is
# deliberately part of the comparison: a dependency rebuilt with a new pkgrel can
# have bumped its SONAMEs, so a pkgrel-only difference is still a reason to
# rebuild this package.
recorded_version() { # <buildinfo> <name>; prints the recorded <version>-<pkgrel>
    local buildinfo="$1" name="$2"
    awk -F ' = ' -v p="$name-" '
        $1 == "installed" && index($2, p) == 1 {
            rest = substr($2, length(p) + 1) # <version>-<pkgrel>-<arch>
            arch = rest; sub(/^.*-/, "", arch)
            body = rest; sub(/-[^-]*$/, "", body)
            rel = body; sub(/^.*-/, "", rel)
            ver = body; sub(/-[^-]*$/, "", ver)
            # `<name>-` also prefixes packages called `<name>-something`, and the
            # installed list is not sorted, so a plain prefix match can return a
            # *different* package (looking up `nss` once returned the version of
            # `nss-mdns`).  Keep only the candidate that really parses as
            # version-pkgrel-arch: a pkgver never contains a dash and a pkgrel is
            # digits and dots.
            if (ver ~ /-/ || rel !~ /^[0-9][0-9.]*$/ || arch !~ /^[A-Za-z0-9_]+$/) next
            if (found == "") found = ver "-" rel
        }
        END { if (found != "") print found }
    ' "$buildinfo"
}
# `pacman -Si` prints `Version         : 1.0-1`.  With `-F ': +'` the first field
# is `Version         ` — the padding *before* the colon is part of it — so the
# old `$1 == "Version"` never matched and this lookup returned an empty version
# for every package, which made the whole drift check a silent no-op.  Trim the
# label before comparing.
current_version() { # <name>; prints the repository's <version>-<pkgrel>
    pacman -Si "$1" 2>/dev/null |
        awk -F ': +' '{key=$1; sub(/[[:space:]]+$/, "", key); if (key == "Version") {print $2; exit}}'
}

# Compare one dependency against what the published build recorded.
#   0 = the versions disagree (stale), 1 = in sync, 2 = not resolvable here.
check_dep() { # <buildinfo> <package-name> <dependency> <label>
    local buildinfo="$1" name="$2" dep="$3" label="$4" old new
    old="$(recorded_version "$buildinfo" "$dep")"
    new="$(current_version "$dep")"
    # Nothing was recorded for this dependency, so there is nothing to compare;
    # counting it would turn "not covered" into "verified".
    [[ -n "$old" ]] || return 1
    compared=$((compared + 1))
    if [[ -n "$new" && "$old" != "$new" ]]; then
        stale=$((stale + 1))
        printf 'STALE %s: %s %s changed %s -> %s\n' "$name" "$label" "$dep" "$old" "$new"
        [[ -n "$stale_file" ]] && printf '%s\n' "$name" >> "$stale_file"
        return 0
    fi
    if [[ -z "$new" ]]; then
        unresolved_count=$((unresolved_count + 1))
        return 2
    fi
    return 1
}

# packages/<dir>/.rebuild-on is the per-package declaration of the rebuild
# triggers .SRCINFO cannot express (`package <name>`) plus the provider of each
# externally linked SONAME (`soname <soname> <provider>`).  archlinuxcn's
# `update_on: - alpm:` says the same thing from lilac.yaml; here it lives next
# to the package it belongs to.  A declaration that names a package this
# container can resolve becomes a drift trigger even when the current .SRCINFO
# no longer lists it, which is exactly the case that used to go silent.
list_triggers="${root}/scripts/list-rebuild-triggers.sh"

packages=0
compared=0
stale=0
unresolved_count=0

packages=0
compared=0
unresolved=0
stale=0

for pkg in "$repo_dir"/*.pkg.tar.zst; do
    [[ -e "$pkg" ]] || continue
    name="$(bsdtar -xOf "$pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    buildinfo="$(mktemp)"; bsdtar -xOf "$pkg" .BUILDINFO > "$buildinfo"
    src="${root}/packages/${name}/.SRCINFO"
    [[ -f "$src" ]] || { rm -f "$buildinfo"; continue; }
    packages=$((packages + 1))

    declared=()
    if [[ -f "$list_triggers" ]]; then
        while IFS=$'\t' read -r kind directory first second; do
            [[ "$directory" == "$name" ]] || continue
            case "$kind" in
                package) declared+=("$first") ;;
                soname) declared+=("$second") ;;
            esac
        done < <(bash "$list_triggers" "$root/packages" "$name")
    fi

    declare -A handled=()
    while IFS= read -r raw; do
        dep="$(strip_dep "$raw")"; [[ -n "$dep" && "$dep" != *.so* ]] || continue
        handled["$dep"]=1
        check_dep "$buildinfo" "$name" "$dep" "direct dependency" || true
    done < <(awk -F ' = ' '$1 ~ /^\t(depends|makedepends|checkdepends)$/ {print $2}' "$src")

    unresolved=""
    for dep in ${declared[@]+"${declared[@]}"}; do
        [[ -n "$dep" && "$dep" != *.so* ]] || continue
        [[ -n "${handled[$dep]:-}" ]] && continue
        handled["$dep"]=1
        status=0
        check_dep "$buildinfo" "$name" "$dep" "declared dependency" || status=$?
        (( status == 2 )) && unresolved+=" $dep"
    done
    if [[ -n "$unresolved" ]]; then
        # Only declarations get this note: they are a deliberate statement about
        # a dependency, so "cannot verify it here" is worth a line instead of a
        # silent hole.  The same note for every external .SRCINFO dependency
        # would be a long, unread list.
        printf 'NOTE %s: declared dependency not resolvable in this container (external repository?):%s\n' \
            "$name" "$unresolved"
    fi
    rm -f "$buildinfo"
done

# This line is what the workflow asserts on: it must appear even when there is
# nothing to report, because "the detector crashed" and "there really is no
# drift" are otherwise indistinguishable in the log -- which is exactly how the
# openvino SONAME drift stayed invisible.
printf 'SUMMARY packages=%d compared=%d stale=%d unresolved=%d\n' \
    "$packages" "$compared" "$stale" "$unresolved_count"

if (( compared == 0 )); then
    printf 'Nothing could be compared: the pacman databases are probably not synced (run pacman -Syu first) or no published package records dependency versions.\n' >&2
    printf 'Refusing to report "no drift" from an incomplete scan.\n' >&2
    exit 3
fi

if (( unresolved_count > 0 )); then
    printf 'WARNING: %d dependency version(s) could not be resolved against the current repositories; drift may be under-reported.\n' \
        "$unresolved_count" >&2
fi
