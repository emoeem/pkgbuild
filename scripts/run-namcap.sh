#!/usr/bin/env bash
set -Eeuo pipefail

# Per-package tag suppression: packages/<name>/.namcap-ignore-tags holds one
# namcap tag per line. It exists for packages that ship an upstream-built
# runtime inside the payload (deepseek-harness-desktop bundles CPython,
# site-packages and native extensions): namcap infers dependencies from system
# packages only, so modules resolved inside the payload look missing, and the
# shipped binaries keep their build-host RPATH. Neither is a packaging defect
# this repository can fix without rewriting upstream artifacts.
ignore_args=()
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
if [[ -n "$package_dir" && -f "${package_dir}/.namcap-ignore-tags" ]]; then
    while IFS= read -r tag; do
        tag="${tag%%#*}"
        tag="$(printf '%s' "$tag" | tr -d '[:space:]')"
        [[ -n "$tag" ]] && ignore_args+=(-i "$tag")
    done <"${package_dir}/.namcap-ignore-tags"
fi

backup="$(mktemp)"
trap 'cp "$backup" /etc/pacman.conf; rm -f "$backup"' EXIT
cp /etc/pacman.conf "$backup"

# CachyOS pacman supports this container-only option, while the current
# pycman parser used by namcap does not. Keep it enabled for pacman and
# hide it only for namcap's read of pacman.conf.
sed -i '/^DisableSandboxNetwork$/d' /etc/pacman.conf

runuser -u builder -- env HOME=/home/builder namcap "${ignore_args[@]}" "$@"
