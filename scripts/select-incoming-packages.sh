#!/usr/bin/env bash
# Print one package file per pkgname, choosing the newest Arch version via vercmp.
set -Eeuo pipefail
incoming="${1:?usage: $0 <incoming-dir>}"
[[ -d "$incoming" ]] || { printf 'not a directory: %s\n' "$incoming" >&2; exit 2; }
# The incoming tree holds one directory per package base, so the search has to
# be recursive; scanning only the top level found nothing.
#
# The version comes from the single .PKGINFO pkgver field: makepkg writes the
# whole `[epoch:]pkgver-pkgrel` there and no pkgrel line of its own, so the
# previous split into pkgver/pkgrel/epoch dropped every real package and the
# publish install test died with "no valid incoming package files found".
declare -A chosen_path=() chosen_version=()
while IFS= read -r -d '' file; do
    info="$(bsdtar -xOf "$file" .PKGINFO 2>/dev/null)" || continue
    name="$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' <<<"$info")"
    version="$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<<"$info")"
    [[ -n "$name" && -n "$version" ]] || continue
    if [[ -z "${chosen_path[$name]:-}" ]] || (( $(vercmp "$version" "${chosen_version[$name]}") > 0 )); then
        chosen_path["$name"]="$file"
        chosen_version["$name"]="$version"
    fi
done < <(find "$incoming" -type f -name '*.pkg.tar.zst' -print0 | sort -z)
for name in "${!chosen_path[@]}"; do printf '%s\t%s\n' "$name" "${chosen_path[$name]}"; done | sort -k1,1
