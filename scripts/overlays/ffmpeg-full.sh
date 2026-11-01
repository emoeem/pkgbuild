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
#    Raise-only: the .6 floor marks "this is our build of the upstream base",
#    but a pkgrel that is already higher (bump_pkgrel rebuilds, pkgrel-floor.sh
#    alignment, the pkgrel write-back) must survive the overlay. Forcing the
#    literal .6 here reset 2.11 back to 2.6 on every AUR sync, and repo-add
#    happily republished the older number — clients on 2.11 could never update
#    again. Keep the higher revision instead; a new upstream base (2 -> 3)
#    still lands on 3.6, which is above any 2.x.
current_pkgrel="$(sed -nE 's/^pkgrel=([0-9]+(\.[0-9]+)?)$/\1/p' "$pkgbuild")"
[[ -n "$current_pkgrel" ]] || fail 'unable to parse a numeric pkgrel'
base_pkgrel="${current_pkgrel%%.*}"
final_pkgrel="${base_pkgrel}.6"
if [[ "$current_pkgrel" == *.* ]] && (( 10#${current_pkgrel#*.} >= 6 )); then
    final_pkgrel="$current_pkgrel"
fi
sed -i -E "s/^pkgrel=.*/pkgrel=${final_pkgrel}/" "$pkgbuild"

# 3b. Do not inherit the builder host's -march=native.
# The flag block is replaced from its first line up to the configure call. That
# first line is either this overlay's own marker (already overlaid PKGBUILD) or
# the first CFLAGS/CXXFLAGS/LDFLAGS assignment (freshly synced upstream
# PKGBUILD, which has no -march line at all). Anything else inside the replaced
# region would be dropped silently, so it aborts instead.
python3 - "$pkgbuild" <<'PY2'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

end = s.index("    ./configure \\")
anchor = re.compile(
    r"^    (?:# Do not inherit the repository host|export (?:CFLAGS|CXXFLAGS|LDFLAGS)[+<>=])",
    re.M,
)
starts = [match.start() for match in anchor.finditer(s[:end])]
if not starts:
    raise SystemExit('ffmpeg flag block anchor not found')
start = starts[0]

unexpected = [
    line for line in s[start:end].splitlines()
    if line.strip()
    and not line.lstrip().startswith('#')
    and not re.match(r"^    export (?:CFLAGS|CXXFLAGS|LDFLAGS)[+<>=]", line)
]
if unexpected:
    raise SystemExit('unexpected lines inside the ffmpeg flag block: '
                     + ' | '.join(unexpected))

block = """    # Do not inherit the repository host's -march=native.
    export CFLAGS='-march=x86-64-v3 -mtune=generic -O2 -pipe -fno-plt -fexceptions'
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
#     Without the upstream fix (FFmpeg commit c54710db) a rebuild against
#     openapv 1.1.1.0 fails, while the already published ffmpeg-full still
#     needs the removed liboapv.so.2 -- which breaks every consumer of
#     libavcodec, mpv included.
#
#     This repository vendors that commit as 080-ffmpeg-openapv1.1-fix.patch
#     instead of fetching it from code.ffmpeg.org: that endpoint re-renders the
#     patch text, so its `index` abbreviation changes under a constant commit id
#     and a remote checksum goes stale. AUR meanwhile declares the patch as a
#     URL source. Both forms must agree: makepkg resolves a file source from
#     $startdir before SRCDEST or the network, so the committed file is what
#     gets hashed. A sync that brought back AUR's URL declaration while keeping
#     the vendored bytes made ffmpeg-full 9.0.2-2.36 die in the validity check
#     at ced12ff. Reconcile on every sync: one plain source entry whose
#     checksum is the hash of the committed file.
oapv_patch='080-ffmpeg-openapv1.1-fix.patch'
oapv_path="${package_dir}/${oapv_patch}"
[[ -f "$oapv_path" ]] || fail "vendored openapv patch is missing: ${oapv_patch}"
oapv_sum="$(sha256sum -- "$oapv_path" | cut -d' ' -f1)"

# AUR's .SRCINFO supplies the source/checksum ordering used below. Refresh it
# from the PKGBUILD first when possible so a stale AUR copy cannot shift the
# index onto a different checksum.
if command -v makepkg > /dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO ) ||
        fail 'unable to refresh .SRCINFO before reconciling the openapv patch'
fi

python3 - "$pkgbuild" "$srcinfo" "$oapv_patch" "$oapv_sum" <<'PY3'
from pathlib import Path
import re
import sys

pkgbuild_path = Path(sys.argv[1])
srcinfo_path = Path(sys.argv[2])
patch_name = sys.argv[3]
patch_sum = sys.argv[4]
markers = ('openapv', 'c54710db')


def fail(message):
    raise SystemExit(f'ffmpeg-full overlay: {message}')


def field_lines(lines, field):
    prefix = f'\t{field} = '
    return [i for i, line in enumerate(lines) if line.startswith(prefix)]


def field_values(lines, field):
    prefix = f'\t{field} = '
    return [line[len(prefix):].rstrip('\n') for line in lines if line.startswith(prefix)]


def filename_of(spec):
    if '::' in spec:
        return spec.split('::', 1)[0]
    value = spec[len('git+'):] if spec.startswith('git+') else spec
    value = value.split('#', 1)[0].split('?', 1)[0]
    return value.rsplit('/', 1)[-1]


def line_end(text, pos):
    end = text.find('\n', pos)
    return len(text) if end < 0 else end + 1


srcinfo_lines = srcinfo_path.read_text().splitlines(keepends=True)
source_rows = field_lines(srcinfo_lines, 'source')
sum_rows = field_lines(srcinfo_lines, 'sha256sums')
sources = field_values(srcinfo_lines, 'source')
sums = field_values(srcinfo_lines, 'sha256sums')
if not sources or len(sources) != len(sums):
    fail(f'.SRCINFO declares {len(sources)} source(s) but {len(sums)} checksum(s)')

matches = [i for i, spec in enumerate(sources) if any(m in spec for m in markers)]
if len(matches) > 1:
    fail('more than one openapv source entry in .SRCINFO')
index = matches[0] if matches else None

text = pkgbuild_path.read_text()
source_decl = re.search(r'^source=\(', text, re.M)
sums_decl = re.search(r'^sha256sums=\(', text, re.M)
if not source_decl or not sums_decl:
    fail('PKGBUILD is missing source=() or sha256sums=()')
source_end = text.find(')', source_decl.end())
sums_end = text.find(')', sums_decl.end())
if source_end < 0 or sums_end < 0:
    fail('PKGBUILD source and sha256sums arrays must be closed')

if index is not None:
    old_name = filename_of(sources[index])

    # Replace the checksum at the same index. The array is one quoted value per
    # entry, so the .SRCINFO index maps directly; only that token changes.
    if sums_end <= sums_decl.end():
        fail('sha256sums=() is empty')
    tokens = list(re.finditer(r"'[^']*'|\"[^\"]*\"", text[sums_decl.end():sums_end]))
    if len(tokens) != len(sums):
        fail(f'PKGBUILD declares {len(tokens)} checksum(s) but .SRCINFO has {len(sums)}')
    token = tokens[index]
    offset = sums_decl.end()
    text = text[:offset + token.start()] + f"'{patch_sum}'" + text[offset + token.end():]

    # Collapse the source entry to the committed file name. AUR may declare
    # `name::url`; the whole line goes, or the URL would remain attached.
    pattern = (r'^([ \t]*)' + re.escape("'" + old_name + "'") + r'[^\n]*$')
    match = re.search(pattern, text[source_decl.end():source_end], re.M)
    if not match:
        fail(f'source=() does not declare {old_name}')
    replacement = match.group(1) + f"'{patch_name}'"
    start = source_decl.end() + match.start()
    text = text[:start] + replacement + text[line_end(text, start) - 1:]

    # prepare() must apply the committed file, whatever AUR called it.
    prepared = 0
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.lstrip().startswith('patch') and old_name in line:
            lines[i] = line.replace(old_name, patch_name)
            prepared += 1
    if prepared != 1:
        fail(f'prepare() applies {old_name} {prepared} time(s)')
    text = ''.join(lines)

    srcinfo_lines[source_rows[index]] = f'\tsource = {patch_name}\n'
    srcinfo_lines[sum_rows[index]] = f'\tsha256sums = {patch_sum}\n'
else:
    # AUR dropped the patch entirely: add the committed copy after 070.
    anchor = next((i for i, spec in enumerate(sources)
                   if '070-ffmpeg-whisper.cpp-fix-pkgconfig.patch' in spec), None)
    if anchor is None:
        fail('no 070-ffmpeg-whisper.cpp-fix-pkgconfig.patch entry to anchor the openapv source')
    anchor_sum = sums[anchor]

    match = re.search(r'^([ \t]*)[^\n]*070-ffmpeg-whisper\.cpp-fix-pkgconfig[.]patch[^\n]*$',
                      text[source_decl.end():source_end], re.M)
    if not match:
        fail('source=() has no 070-ffmpeg-whisper.cpp-fix-pkgconfig.patch entry')
    position = source_decl.end() + match.end()
    text = text[:position] + f"\n{match.group(1)}'{patch_name}'" + text[position:]

    # The source insertion above moved everything that follows it, so the
    # sha256sums offsets from the original scan are no longer valid.
    sums_decl = re.search(r'^sha256sums=\(', text, re.M)
    sums_end = text.find(')', sums_decl.end()) if sums_decl else -1
    if sums_end < 0:
        fail('PKGBUILD sha256sums=() disappeared during the openapv rewrite')
    sums_block = text[sums_decl.end():sums_end]
    match = re.search(r'^([ \t]*)' + re.escape("'" + anchor_sum + "'") + r'[^\n]*$',
                      sums_block, re.M)
    if not match:
        fail('sha256sums=() has no checksum for the 070 patch')
    position = sums_decl.end() + match.end()
    text = text[:position] + f"\n{match.group(1)}'{patch_sum}'" + text[position:]

    match = re.search(r'^([ \t]*).*050-ffmpeg-fix-cuda-nvcc-with-gcc14[.]patch[^\n]*$', text, re.M)
    if not match:
        fail('prepare() has no 050-ffmpeg-fix-cuda-nvcc-with-gcc14.patch line')
    position = match.end()
    text = (text[:position] +
            f'\n    patch -d "ffmpeg-${{pkgver}}" -Np1 -i "${{srcdir}}/{patch_name}"' +
            text[position:])

    srcinfo_lines.insert(source_rows[anchor] + 1, f'\tsource = {patch_name}\n')
    srcinfo_lines.insert(sum_rows[anchor] + 2, f'\tsha256sums = {patch_sum}\n')

pkgbuild_path.write_text(text)
srcinfo_path.write_text(''.join(srcinfo_lines))

# The result must be a single plain entry whose checksum describes the file.
lines = pkgbuild_path.read_text().splitlines()
source_entries = [line for line in lines if line.strip().startswith("'")
                  and patch_name in line]
if len(source_entries) != 1 or '::' in source_entries[0]:
    fail(f'the vendored openapv source entry is missing, duplicated or still remote: {source_entries}')
declared = [line for line in lines if line.strip() == f"'{patch_sum}'"]
if len(declared) != 1:
    fail('the vendored openapv checksum is missing or duplicated')
applied = [line for line in lines if line.lstrip().startswith('patch') and patch_name in line]
if len(applied) != 1:
    fail('the vendored openapv patch is not applied exactly once in prepare()')
PY3

[[ "$(grep -cF "'${oapv_patch}'" "$pkgbuild")" == 1 ]] ||
    fail 'the vendored openapv source entry is missing or duplicated in PKGBUILD'
[[ "$(grep -cF "'${oapv_sum}'" "$pkgbuild")" == 1 ]] ||
    fail 'the vendored openapv checksum is missing or duplicated in PKGBUILD'
grep -qF "'${oapv_patch}'::" "$pkgbuild" &&
    fail 'the openapv source still points at a remote URL'
[[ "$(grep -cE '^    patch .*openapv.*[.]patch' "$pkgbuild")" == 1 ]] ||
    fail 'the openapv patch is not applied exactly once in prepare()'

# 4. Mirror the changes into .SRCINFO: regenerate with makepkg when available
#    (local sync runs); patch the two changed entries textually otherwise
#    (CI sync runners have no pacman).
# final_pkgrel 来自第 3 步（只升不降）：这里只复核 PKGBUILD 没被中途改过。
[[ "$(sed -nE 's/^pkgrel=([0-9]+(\.[0-9]+)?)$/\1/p' "$pkgbuild")" == "$final_pkgrel" ]] ||
    fail 'pkgrel changed between overlay steps'

if command -v makepkg > /dev/null 2>&1; then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
else
    sed -i -E "s/^(\tpkgrel = ).*/\1${final_pkgrel}/" "$srcinfo"
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
grep -q "^pkgrel=${final_pkgrel}$" "$pkgbuild" ||
    fail 'pkgrel bump missing'
grep -qE "$(printf '\t')pkgrel = ${final_pkgrel}$" "$srcinfo" ||
    fail 'pkgrel missing in .SRCINFO'
[[ "$(grep -cF 'optdepends = cuda: for NVIDIA NPP filters' "$srcinfo")" == 1 ]] ||
    fail 'cuda optdepend duplicated or missing in .SRCINFO'

printf 'ffmpeg-full overlay applied: libnpp enabled, openapv 1.1 fix from the vendored patch, pkgrel %s.\n' \
    "$final_pkgrel"
