#!/usr/bin/env bash
# Print one package file per pkgname, choosing the newest Arch version via vercmp.
set -Eeuo pipefail
incoming="${1:?usage: $0 <incoming-dir>}"
[[ -d "$incoming" ]] || { printf 'not a directory: %s\n' "$incoming" >&2; exit 2; }
declare -A chosen_path=() chosen_version=()
while IFS= read -r -d '' file; do
    info="$(bsdtar -xOf "$file" .PKGINFO 2>/dev/null)" || continue
    name="$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' <<<"$info")"
    pkgver="$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<<"$info")"
    pkgrel="$(awk -F ' = ' '$1 == "pkgrel" {print $2; exit}' <<<"$info")"
    epoch="$(awk -F ' = ' '$1 == "epoch" {print $2; exit}' <<<"$info")"
    [[ -n "$name" && -n "$pkgver" && -n "$pkgrel" ]] || continue
    version="${pkgver}-${pkgrel}"
    if [[ -n "$epoch" && "$epoch" != 0 ]]; then version="${epoch}:${version}"; fi
    if [[ -z "${chosen_path[$name]:-}" ]] || (( $(vercmp "$version" "${chosen_version[$name]}") > 0 )); then
        chosen_path["$name"]="$file"
        chosen_version["$name"]="$version"
    fi
done < <(find "$incoming" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0 | sort -z)
for name in "${!chosen_path[@]}"; do printf '%s\t%s\n' "$name" "${chosen_path[$name]}"; done | sort -k1,1
