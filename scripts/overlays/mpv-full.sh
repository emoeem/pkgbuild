#!/usr/bin/env bash
# Local mpv-Emo build policy layered on top of AUR mpv-full.
# Keep the package close to upstream; private core patches are intentionally
# not enabled here. They will live in an explicit optional patch layer.

set -Eeuo pipefail

package_dir="${1:?usage: mpv-full.sh <package-dir>}"
pkgbuild="${package_dir}/PKGBUILD"
srcinfo="${package_dir}/.SRCINFO"

fail() {
    printf 'mpv-full overlay: %s\n' "$1" >&2
    exit 1
}

[[ -f "$pkgbuild" ]] || fail "PKGBUILD not found in ${package_dir}"
[[ -f "$srcinfo" ]] || fail ".SRCINFO not found in ${package_dir}"

# Distinguish the private rebuild from the AUR package while retaining the
# upstream package version and all upstream build logic.
sed -i -E 's/^pkgrel=([0-9]+)(\.[0-9]+)?$/pkgrel=\1.1/' "$pkgbuild"

# Explicitly require the Linux/native feature set used by mpv-Emo.
for flag in \
    "-Dcuda-hwaccel='enabled'" \
    "-Dcuda-interop='enabled'" \
    "-Dvapoursynth='enabled'" \
    "-Dvulkan='enabled'" \
    "-Dwayland='enabled'" \
    "-Dpipewire='enabled'"; do
    grep -qF -- "$flag" "$pkgbuild" || fail "required build option missing: $flag"
done

# Rebuild .SRCINFO from the final PKGBUILD. This keeps the AUR-sync overlay
# deterministic and lets the existing package checker validate the result.
if command -v makepkg >/dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
else
    base_pkgrel="$(sed -nE 's/^pkgrel=([0-9]+)\.1$/\1/p' "$pkgbuild")"
    [[ -n "$base_pkgrel" ]] || fail 'unable to parse overlaid pkgrel'
    sed -i -E 's/^(\tpkgrel = )[0-9]+(\.[0-9]+)?$/\1'"${base_pkgrel}"'.1/' "$srcinfo"
fi

pkgrel="$(sed -nE 's/^pkgrel=([0-9]+\.[0-9]+)$/\1/p' "$pkgbuild")"
[[ -n "$pkgrel" ]] || fail 'unable to read final pkgrel'
grep -qE "^$(printf '\t')pkgrel = ${pkgrel//./\.}$" "$srcinfo" ||
    fail '.SRCINFO pkgrel does not match PKGBUILD'

printf 'mpv-full overlay applied: Linux-native feature set verified, pkgrel %s.\n' "$pkgrel"
