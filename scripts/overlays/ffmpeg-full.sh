#!/usr/bin/env bash
# Re-apply local customizations on top of the AUR ffmpeg-full package after
# every AUR sync. Synced PKGBUILDs are overwritten wholesale by
# sync-aur-packages.sh, so everything this repository adds on top of AUR
# must be re-applied here. Every operation below is idempotent so running
# the overlay repeatedly (manual runs + scheduled syncs) never duplicates
# anything, and any upstream structural change that breaks an assertion
# fails the sync loudly instead of silently shipping a vanilla build.

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

# 1. NVIDIA NPP-accelerated filters (scale_npp, transpose_npp, overlay_npp):
#    compiled against the CUDA toolkit's NPP libraries. The libraries are
#    resolved at runtime through the ld.so configuration shipped by the cuda
#    package, so the runtime dependency stays optional.
sed -i 's|^        --disable-libnpp \\$|        --enable-libnpp \\|' "$pkgbuild"

# 2. Declare the cuda runtime dependency for the NPP filters.
new_optdepend="    'cuda: for NVIDIA NPP filters (scale_npp, transpose_npp, overlay_npp)'"
if ! grep -qF 'cuda: for NVIDIA NPP filters' "$pkgbuild"; then
    awk -v line="$new_optdepend" '
        /nvidia-utils: for NVIDIA CUVID/ && !optdepend_done {
            print
            print line
            optdepend_done = 1
            next
        }
        { print }
        END {
            if (!optdepend_done) {
                exit 3
            }
        }
    ' "$pkgbuild" > "${pkgbuild}.tmp" || fail 'PKGBUILD optdepend insertion failed'
    mv "${pkgbuild}.tmp" "$pkgbuild"
fi

# 3. Distinguish local builds from the AUR package so pacman treats them as
#    separate revisions even at the same upstream pkgrel.
sed -i -E 's/^pkgrel=([0-9]+)(\.[0-9]+)?$/pkgrel=\1.3/' "$pkgbuild"

# 3b. Do not inherit the builder host's -march=native.
python3 - "$pkgbuild" <<'PY2'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
start = s.index("    # Do not inherit the repository host's -march=native.") if "    # Do not inherit the repository host's -march=native." in s else s.index("    export CFLAGS+=' -isystem/opt/cuda/include'")
end = s.index("    ./configure \\", start)
block = """    export CFLAGS='-march=x86-64-v3 -mtune=generic -O2 -pipe -fno-plt -fexceptions'
    export CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"
    export LDFLAGS='-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now'
    export CFLAGS+=' -isystem/opt/cuda/include'
    export LDFLAGS+=' -L/opt/cuda/lib64'

    # fix build of libavfilter/asrc_flite.c with gcc 14+
    export CFLAGS+=' -Wno-error=incompatible-pointer-types'

"""
p.write_text(s[:start] + block + s[end:])
PY2

# 4. Mirror the changes into .SRCINFO: regenerate with makepkg when available
#    (local sync runs); patch the two changed entries textually otherwise
#    (CI sync runners have no pacman).
base_pkgrel="$(sed -nE 's/^pkgrel=([0-9]+)\.[0-9]+$/\1/p' "$pkgbuild")"
[[ -n "$base_pkgrel" ]] || fail 'unable to parse overlaid pkgrel'

if command -v makepkg > /dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
else
    sed -i -E 's/^(\tpkgrel = )[0-9]+(\.[0-9]+)?$/\1'"${base_pkgrel}"'.3/' "$srcinfo"
    if ! grep -qF 'optdepends = cuda: for NVIDIA NPP filters' "$srcinfo"; then
        awk -v line="\toptdepends = cuda: for NVIDIA NPP filters (scale_npp, transpose_npp, overlay_npp)" '
            /\toptdepends = nvidia-utils:/ && !optdepend_done {
                print
                print line
                optdepend_done = 1
                next
            }
            { print }
            END {
                if (!optdepend_done) {
                    exit 3
                }
            }
        ' "$srcinfo" > "${srcinfo}.tmp" || fail '.SRCINFO optdepend insertion failed'
        mv "${srcinfo}.tmp" "$srcinfo"
    fi
fi

# Assertions.
grep -q '^        --enable-libnpp \\' "$pkgbuild" ||
    fail 'libnpp flag missing after rewrite'
grep -q '^        --disable-lto \\' "$pkgbuild" ||
    fail 'LTO must remain disabled for the stable custom build'
grep -q -- '--disable-libnpp' "$pkgbuild" &&
    fail 'libnpp disable flag still present'
[[ "$(grep -cF 'cuda: for NVIDIA NPP filters' "$pkgbuild")" == 1 ]] ||
    fail 'cuda optdepend duplicated or missing in PKGBUILD'
grep -q "^pkgrel=${base_pkgrel}\.3$" "$pkgbuild" ||
    fail 'pkgrel bump missing'
grep -qE "$(printf '\t')pkgrel = ${base_pkgrel}\.3$" "$srcinfo" ||
    fail 'pkgrel missing in .SRCINFO'
[[ "$(grep -cF 'optdepends = cuda: for NVIDIA NPP filters' "$srcinfo")" == 1 ]] ||
    fail 'cuda optdepend duplicated or missing in .SRCINFO'

printf 'ffmpeg-full overlay applied: libnpp enabled, LTO disabled, pkgrel %s.3.\n' \
    "$base_pkgrel"
