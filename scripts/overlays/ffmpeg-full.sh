#!/usr/bin/env bash
# Re-apply local customizations on top of the AUR ffmpeg-full package after
# every AUR sync. Synced PKGBUILDs are overwritten wholesale by
# sync-aur-packages.sh, so everything this repository adds on top of AUR
# must be re-applied here. Any upstream structural change that breaks an
# assertion below fails the sync loudly instead of silently shipping a
# vanilla build.

set -Eeuo pipefail

package_dir="${1:?usage: ffmpeg-full.sh <package-dir>}"
pkgbuild="${package_dir}/PKGBUILD"
srcinfo="${package_dir}/.SRCINFO"

fail() {
    printf 'ffmpeg-full overlay: %s\n' "$1" >&2
    exit 1
}

[[ -f "$pkgbuild" ]] || fail "PKGBUILD not found in ${package_dir}"
[[ -f "$srcinfo" ]] || fail ".SRCINFO not found in ${package_dir}"

# NVIDIA NPP-accelerated filters (scale_npp, transpose_npp, overlay_npp):
# compiled against the CUDA toolkit's NPP libraries. The libraries are
# resolved at runtime through the ld.so configuration shipped by the cuda
# package, so the runtime dependency stays optional.
new_optdepend="    'cuda: for NVIDIA NPP filters (scale_npp, transpose_npp, overlay_npp)'"

awk -v new_optdepend="$new_optdepend" '
    /^pkgrel=[0-9]/ {
        pkgrel = $0
        sub(/^pkgrel=/, "", pkgrel)
        sub(/\.[0-9]+$/, "", pkgrel)
        print "pkgrel=" pkgrel ".1"
        next
    }
    /^        --disable-libnpp/ {
        sub(/--disable-libnpp/, "--enable-libnpp")
        print
        next
    }
    /nvidia-utils: for NVIDIA CUVID/ && !optdepend_done {
        print
        print new_optdepend
        optdepend_done = 1
        next
    }
    { print }
    END {
        if (!optdepend_done) {
            exit 3
        }
    }
' "$pkgbuild" > "${pkgbuild}.tmp" || fail 'PKGBUILD rewrite failed'
mv "${pkgbuild}.tmp" "$pkgbuild"

base_pkgrel="$(sed -nE 's/^pkgrel=([0-9]+)\.1$/\1/p' "$pkgbuild")"
[[ -n "$base_pkgrel" ]] || fail 'unable to parse overlaid pkgrel'

# Regenerate .SRCINFO when makepkg is available (local sync runs); patch the
# two changed entries textually otherwise (CI sync runners have no pacman).
if command -v makepkg > /dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
else
    sed -i -E \
        's/^(\tpkgrel = )[0-9]+(\.[0-9]+)?$/\1'"${base_pkgrel}"'.1/' \
        "$srcinfo"
    awk -v srcinfo_optdepend="\toptdepends = cuda: for NVIDIA NPP filters (scale_npp, transpose_npp, overlay_npp)" '
        /\toptdepends = nvidia-utils:/ && !optdepend_done {
            print
            print srcinfo_optdepend
            optdepend_done = 1
            next
        }
        { print }
        END {
            if (!optdepend_done) {
                exit 3
            }
        }
    ' "$srcinfo" > "${srcinfo}.tmp" || fail '.SRCINFO rewrite failed'
    mv "${srcinfo}.tmp" "$srcinfo"
fi

grep -q '^        --enable-libnpp \\' "$pkgbuild" ||
    fail 'libnpp flag missing after rewrite'
grep -q -- '--disable-libnpp' "$pkgbuild" &&
    fail 'libnpp disable flag still present'
grep -q "^pkgrel=${base_pkgrel}\.1$" "$pkgbuild" ||
    fail 'pkgrel bump missing'
grep -qF 'cuda: for NVIDIA NPP filters' "$pkgbuild" ||
    fail 'cuda optdepend missing in PKGBUILD'
grep -qE "^$(printf '\t')pkgrel = ${base_pkgrel}\.1$" "$srcinfo" ||
    fail 'pkgrel missing in .SRCINFO'
grep -qF 'optdepends = cuda: for NVIDIA NPP filters' "$srcinfo" ||
    fail 'cuda optdepend missing in .SRCINFO'

printf 'ffmpeg-full overlay applied: libnpp enabled, pkgrel %s.1.\n' \
    "$base_pkgrel"
