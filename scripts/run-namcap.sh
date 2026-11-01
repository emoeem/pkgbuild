#!/usr/bin/env bash
set -Eeuo pipefail

# Per-package rule exclusion: packages/<name>/.namcap-exclude holds namcap rule
# names, one per line or comma-separated. It exists for packages that ship an
# upstream-built runtime inside the payload (deepseek-harness-desktop bundles
# CPython, site-packages and native extensions): namcap infers dependencies
# from system packages only, so modules resolved inside the payload look
# missing, and the shipped binaries keep their build-host RPATH. Neither is a
# packaging defect this repository can fix without rewriting upstream
# artifacts. namcap's -e takes a comma-separated RULELIST, so the lines are
# joined into one argument.
exclude_names=""
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
        [[ -n "$line" ]] && exclude_names="${exclude_names:+$exclude_names,}${line}"
    done <"${package_dir}/.namcap-exclude"
fi
namcap_args=()
[[ -n "$exclude_names" ]] && namcap_args=(--exclude "$exclude_names")

backup="$(mktemp)"
trap 'cp "$backup" /etc/pacman.conf; rm -f "$backup"' EXIT
cp /etc/pacman.conf "$backup"

# CachyOS pacman supports this container-only option, while the current
# pycman parser used by namcap does not. Keep it enabled for pacman and
# hide it only for namcap's read of pacman.conf.
sed -i '/^DisableSandboxNetwork$/d' /etc/pacman.conf

runuser -u builder -- env HOME=/home/builder namcap "${namcap_args[@]}" "$@"
