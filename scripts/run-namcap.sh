#!/usr/bin/env bash
set -Eeuo pipefail

# Per-package rule exclusion: packages/<name>/.namcap-exclude holds namcap rule
# names, one per line. It exists for packages that ship an upstream-built
# runtime inside the payload (deepseek-harness-desktop bundles CPython,
# site-packages and native extensions): namcap infers dependencies from system
# packages only, so modules resolved inside the payload look missing, and the
# shipped binaries keep their build-host RPATH. Neither is a packaging defect
# this repository can fix without rewriting upstream artifacts.
#
# namcap's --exclude cannot express several names: its loop runs
# `active_modules.update(modules)` on every iteration, so a comma list
# re-adds each rule the previous iteration removed and only the last name
# takes effect. Invert instead: list every enabled rule except the excluded
# ones and pass that as --rules, which accumulates without clearing.

backup="$(mktemp)"
trap 'cp "$backup" /etc/pacman.conf; rm -f "$backup"' EXIT
cp /etc/pacman.conf "$backup"

# CachyOS pacman supports this container-only option, while the current
# pycman parser used by namcap does not. Keep it enabled for pacman and
# hide it only for namcap's read of pacman.conf. This has to happen before
# anything invokes namcap, including `namcap -L` below.
sed -i '/^DisableSandboxNetwork$/d' /etc/pacman.conf

exclude_list=()
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname -- "$script_dir")"
target="${1:-}"
package_dir=""
case "$target" in
    *.pkg.tar.*)
        # The filename is not authoritative for the package name; .PKGINFO is.
        package_name="$(bsdtar -xOf "$target" .PKGINFO 2>/dev/null |
            awk -F ' = ' '$1 == "pkgname" { print $2; exit }')"
        [[ -n "$package_name" ]] && package_dir="${repo_root}/packages/${package_name}"
        ;;
    *)
        [[ -f "$target" ]] && package_dir="$(cd -- "$(dirname -- "$target")" && pwd)"
        ;;
esac
if [[ -n "$package_dir" && -f "${package_dir}/.namcap-exclude" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && exclude_list+=("$line")
    done <"${package_dir}/.namcap-exclude"
fi

namcap_args=()
if (( ${#exclude_list[@]} > 0 )); then
    # `namcap -L` prints a banner, the raw module dict, then one
    # "%-20s: description" line per rule; only those lines are parsed.
    all_rules="$(runuser -u builder -- env HOME=/home/builder namcap -L 2>/dev/null |
        awk '$0 ~ /^[a-z][a-z0-9_-]*[[:space:]]+: / { print $1 }')"
    keep=""
    for rule in $all_rules; do
        excluded=0
        for name in "${exclude_list[@]}"; do
            if [[ "$rule" == "$name" ]]; then
                excluded=1
                break
            fi
        done
        (( excluded )) || keep="${keep:+$keep,}${rule}"
    done
    if [[ -z "$keep" ]]; then
        printf 'run-namcap: no rule left after exclusions; refusing to skip the gate.\n' >&2
        exit 1
    fi
    namcap_args=(--rules "$keep")
fi

runuser -u builder -- env HOME=/home/builder namcap "${namcap_args[@]}" "$@"
