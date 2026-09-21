#!/usr/bin/env bash
set -Eeuo pipefail

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
    repo="$(awk -F ': +' '$1 == "Repository" {print $2; exit}' <<< "$info")"
    case "$repo" in
        *v4*|*znver4*|*znver5*)
            printf 'Zen4/v4 repository dependency detected: %s -> %s\n' "$name" "$repo" >&2
            exit 1
            ;;
    esac
done < "$buildinfo"
