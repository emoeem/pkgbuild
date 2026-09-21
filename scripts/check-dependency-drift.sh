#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="${1:-}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$repo_dir" ]] || { echo "usage: $0 <published-repo-dir> [repo-root] [stale-file]" >&2; exit 2; }
stale_file="${3:-}"

if [[ -n "${LOCAL_REPO_DIR:-}" ]]; then
    local_copy="$(mktemp -d)"
    cp -a "${LOCAL_REPO_DIR}/." "$local_copy/"
    shopt -s nullglob
    local_packages=("$local_copy"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#local_packages[@]} > 0 )); then
        repo-add --remove "$local_copy/emoeem.db.tar.gz" "${local_packages[@]}" >/dev/null
        printf '[emoeem]\nSigLevel = Never\nServer = file://%s\n' "$local_copy" > /tmp/emo-repo.conf
        awk '/^\[emoeem\]$/{skip=1;next} skip && /^\[/{skip=0} !skip{print}' /etc/pacman.conf >> /tmp/emo-repo.conf
        cat /tmp/emo-repo.conf > /etc/pacman.conf
    fi
fi

strip_dep() { printf '%s' "$1" | sed -E 's/[<>=].*$//'; }
recorded_version() {
    local buildinfo="$1" name="$2"
    awk -F ' = ' -v n="$name" '$1 == "installed" && $2 ~ ("^" n "-") {v=$2} END {if(v) print v}' "$buildinfo" |
        sed -E 's/-[^-]+$//' | sed -E "s/^${name}-//"
}
current_version() { pacman -Si "$1" 2>/dev/null | awk -F ': +' '$1 == "Version" {print $2; exit}'; }

for pkg in "$repo_dir"/*.pkg.tar.zst; do
    [[ -e "$pkg" ]] || continue
    name="$(bsdtar -xOf "$pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    buildinfo="$(mktemp)"; bsdtar -xOf "$pkg" .BUILDINFO > "$buildinfo"
    src="${root}/packages/${name}/.SRCINFO"
    [[ -f "$src" ]] || { rm -f "$buildinfo"; continue; }
    while IFS= read -r raw; do
        dep="$(strip_dep "$raw")"; [[ -n "$dep" && "$dep" != *.so* ]] || continue
        old="$(recorded_version "$buildinfo" "$dep")"; new="$(current_version "$dep")"
        if [[ -n "$old" && -n "$new" && "$old" != "$new" ]]; then
            printf 'STALE %s: direct dependency %s changed %s -> %s\n' "$name" "$dep" "$old" "$new"
            [[ -n "$stale_file" ]] && printf '%s\n' "$name" >> "$stale_file"
        fi
    done < <(awk -F ' = ' '$1 ~ /^\t(depends|makedepends|checkdepends)$/ {print $2}' "$src")
    rm -f "$buildinfo"
done
