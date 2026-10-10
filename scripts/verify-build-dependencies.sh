#!/usr/bin/env bash
set -Eeuo pipefail

# Force the C locale: the checks below parse tool output (readelf, pacman,
# ldd, ...) whose labels are localized, and a translated label silently
# turns the check into a no-op instead of failing loudly.
export LC_ALL=C

buildinfo="$1"
[[ -f "$buildinfo" ]] || exit 2

declare -A installed_names
while read -r name version; do
    installed_names["$name-$version-x86_64"]="$name"
done < <(pacman -Q)

while IFS=' = ' read -r key value; do
    [[ "$key" == "installed" ]] || continue
    arch="${value##*-}"
    case "$arch" in
        x86_64|x86_64_v3|any) ;;
        x86_64_v4|*znver4*|*znver5*)
            printf 'Zen4/v4 build dependency rejected: %s\n' "$value" >&2
            exit 1
            ;;
        *)
            printf 'Unsupported build dependency architecture: %s\n' "$value" >&2
            exit 1
            ;;
    esac
    name="${installed_names[$value]:-}"
    [[ -n "$name" ]] || continue
    info="$(pacman -Si "$name" 2>/dev/null || true)"
    # `pacman -Si` prints `Repository      : cachyos-v3`; with `-F ': +'` the
    # first field keeps the padding before the colon, so a plain equality test
    # never matched and this check silently passed for every package.  Trim the
    # label first so a v4 repository is actually rejected.
    repo="$(awk -F ': +' '{key=$1; sub(/[[:space:]]+$/, "", key); if (key == "Repository") {print $2; exit}}' <<< "$info")"
    case "$repo" in
        *v4*|*znver4*|*znver5*)
            printf 'Zen4/v4 repository dependency detected: %s -> %s\n' "$name" "$repo" >&2
            exit 1
            ;;
    esac
done < "$buildinfo"
