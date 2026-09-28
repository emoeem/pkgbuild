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
sed -i -E 's/^pkgrel=([0-9]+)(\.[0-9]+)?$/pkgrel=\1.6/' "$pkgbuild"

# 3b. Do not inherit the builder host's -march=native.
# The replacement starts either at its own marker or, on a freshly synced
# PKGBUILD that has never been overlaid, at the first of the three exported
# variables. Anchoring only on the later ' -isystem/opt/cuda/include' line
# would re-emit those three lines on every run and duplicate them.
python3 - "$pkgbuild" <<'PY2'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
marker = "    # Do not inherit the repository host's -march=native.\n"
first = "    export CFLAGS='-march=x86-64-v3 -mtune=generic -O2 -pipe -fno-plt -fexceptions'\n"
start = s.index(marker) if marker in s else s.index(first)
end = s.index("    ./configure \\", start)
block = marker + """    export CFLAGS='-march=x86-64-v3 -mtune=generic -O2 -pipe -fno-plt -fexceptions'
    export CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"
    export LDFLAGS='-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now'
    export CFLAGS+=' -isystem/opt/cuda/include'
    export LDFLAGS+=' -L/opt/cuda/lib64'

    # fix build of libavfilter/asrc_flite.c with gcc 14+
    export CFLAGS+=' -Wno-error=incompatible-pointer-types'

"""
p.write_text(s[:start] + block + s[end:])
PY2

# 3c. openapv 1.1 (API set 1) changed oapvm_create() to take a descriptor
#     argument, so the liboapv encoder of ffmpeg 9.0.2 no longer compiles.
#     Backport the upstream fix (FFmpeg commit c54710db, "avcodec/liboapvenc:
#     fix build with openapv >= 1.1"). Without it a rebuild against
#     openapv 1.1.1.0 fails, while the already published ffmpeg-full still
#     needs the removed liboapv.so.2 -- which breaks every consumer of
#     libavcodec, mpv included. The patch is guarded by `#if OAPV_VER_APISET
#     >= 1` in C, so it stays correct if openapv is ever downgraded again.
oapv_patch='080-ffmpeg-liboapvenc-openapv-1.1.patch'
oapv_patch_url='https://github.com/FFmpeg/FFmpeg/commit/c54710db21c1827dbc3e47658a562525af0fe528.patch'
oapv_patch_sum='f773a85ec68f3b26e0b2ab3cddb7a304df5be8eb5c1887c9b627e23e782c7ec2'

if ! grep -qF "'${oapv_patch}'" "$pkgbuild"; then
    python3 - "$pkgbuild" "$oapv_patch" "$oapv_patch_url" "$oapv_patch_sum" <<'PY3'
from pathlib import Path
import sys

path = Path(sys.argv[1])
name, url, digest = sys.argv[2], sys.argv[3], sys.argv[4]
s = path.read_text()

source_anchor = "        '070-ffmpeg-whisper.cpp-fix-pkgconfig.patch'\n"
sums_anchor = "            '2c846c629ad129ae8ce50791de4f1d390714db6d6420a35406b83b9b44999d4a'\n"
prepare_anchor = '    patch -d "ffmpeg-${pkgver}" -Np1 -i "${srcdir}/050-ffmpeg-fix-cuda-nvcc-with-gcc14.patch"\n'

for label, anchor in (('source', source_anchor),
                      ('sha256sums', sums_anchor),
                      ('prepare', prepare_anchor)):
    if s.count(anchor) != 1:
        raise SystemExit(f'{label} anchor not found exactly once')

s = s.replace(source_anchor,
              source_anchor + f"        '{name}'::\"{url}\"\n", 1)
s = s.replace(sums_anchor,
              sums_anchor + f"            '{digest}'\n", 1)
s = s.replace(prepare_anchor,
              prepare_anchor +
              '    patch -d "ffmpeg-${pkgver}" -Np1 -i "${srcdir}/' + name + '"\n', 1)
path.write_text(s)
PY3
fi

# 4. Mirror the changes into .SRCINFO: regenerate with makepkg when available
#    (local sync runs); patch the two changed entries textually otherwise
#    (CI sync runners have no pacman).
base_pkgrel="$(sed -nE 's/^pkgrel=([0-9]+)\.[0-9]+$/\1/p' "$pkgbuild")"
[[ -n "$base_pkgrel" ]] || fail 'unable to parse overlaid pkgrel'

if command -v makepkg > /dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
else
    sed -i -E 's/^(\tpkgrel = )[0-9]+(\.[0-9]+)?$/\1'"${base_pkgrel}"'.6/' "$srcinfo"
    if ! grep -qF "	source = ${oapv_patch}::" "$srcinfo"; then
        python3 - "$srcinfo" "$oapv_patch" "$oapv_patch_url" "$oapv_patch_sum" <<'PY4'
from pathlib import Path
import sys

path = Path(sys.argv[1])
name, url, digest = sys.argv[2], sys.argv[3], sys.argv[4]
source_anchor = '\tsource = 070-ffmpeg-whisper.cpp-fix-pkgconfig.patch\n'
sums_anchor = '\tsha256sums = 2c846c629ad129ae8ce50791de4f1d390714db6d6420a35406b83b9b44999d4a\n'

lines = path.read_text().splitlines(keepends=True)
if sum(line == source_anchor for line in lines) != 1 or \
        sum(line == sums_anchor for line in lines) != 1:
    raise SystemExit('.SRCINFO anchors not found exactly once')

out = []
for line in lines:
    out.append(line)
    if line == source_anchor:
        out.append(f'\tsource = {name}::{url}\n')
    elif line == sums_anchor:
        out.append(f'\tsha256sums = {digest}\n')
path.write_text(''.join(out))
PY4
    fi
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
grep -q -- '--disable-libnpp' "$pkgbuild" &&
    fail 'libnpp disable flag still present'
[[ "$(grep -cF 'cuda: for NVIDIA NPP filters' "$pkgbuild")" == 1 ]] ||
    fail 'cuda optdepend duplicated or missing in PKGBUILD'
[[ "$(grep -cF "'${oapv_patch}'::\"${oapv_patch_url}\"" "$pkgbuild")" == 1 ]] ||
    fail 'liboapv patch source entry duplicated or missing in PKGBUILD'
[[ "$(grep -cF "'${oapv_patch_sum}'" "$pkgbuild")" == 1 ]] ||
    fail 'liboapv patch checksum duplicated or missing in PKGBUILD'
[[ "$(grep -cF "${oapv_patch}" "$pkgbuild")" == 2 ]] ||
    fail 'liboapv patch not applied in prepare()'
[[ "$(grep -cF "	source = ${oapv_patch}::${oapv_patch_url}" "$srcinfo")" == 1 ]] ||
    fail 'liboapv patch source entry duplicated or missing in .SRCINFO'
grep -q "^pkgrel=${base_pkgrel}\.6$" "$pkgbuild" ||
    fail 'pkgrel bump missing'
grep -qE "$(printf '\t')pkgrel = ${base_pkgrel}\.6$" "$srcinfo" ||
    fail 'pkgrel missing in .SRCINFO'
[[ "$(grep -cF 'optdepends = cuda: for NVIDIA NPP filters' "$srcinfo")" == 1 ]] ||
    fail 'cuda optdepend duplicated or missing in .SRCINFO'

printf 'ffmpeg-full overlay applied: libnpp enabled, liboapv 1.1 fix backported, pkgrel %s.6.\n' \
    "$base_pkgrel"
