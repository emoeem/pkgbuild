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

# 1b. Pin the vendored lensfun checkout. AUR ships the PKGBUILD with an
#     unpinned `git+...lensfun.git` URL, so a rebuild would fetch master
#     unconditionally: not reproducible, and a master API break fails the
#     build without any way to say which commit worked last. The pin lives in
#     .lensfun-pin (single source of truth): this step re-applies it to the
#     synced PKGBUILD, and the nvchecker entry `lensfun-master` reads the same
#     file as its baseline so upstream-check opens an issue when the pin lags.
lensfun_pin="$(tr -d '[:space:]' < "${package_dir}/.lensfun-pin" 2>/dev/null)" ||
    fail 'the vendored lensfun pin file is missing: .lensfun-pin'
[[ "$lensfun_pin" =~ ^[0-9a-f]{40}$ ]] ||
    fail ".lensfun-pin does not contain a 40-character commit: ${lensfun_pin}"
python3 - "$pkgbuild" "$lensfun_pin" <<'PY1B' || fail 'lensfun pin injection failed'
import re
import sys
from pathlib import Path

path, pin = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
rewritten, count = re.subn(
    r"'git\+https://github\.com/lensfun/lensfun\.git(?:#commit=[0-9a-f]{40})?'",
    f"'git+https://github.com/lensfun/lensfun.git#commit={pin}'",
    text,
)
if count != 1:
    raise SystemExit(f"lensfun source entry matches {count} time(s), expected exactly 1")
path.write_text(rewritten)
PY1B
grep -qF "'git+https://github.com/lensfun/lensfun.git#commit=${lensfun_pin}'" "$pkgbuild" ||
    fail 'the lensfun pin is missing after the rewrite'

# 1c. Keep the lensfun system database path out of the build tree. lensfun's
#     config.h bakes SYSTEM_DB_PATH from CMAKE_INSTALL_FULL_DATAROOTDIR,
#     which resolves against CMAKE_INSTALL_PREFIX (= ${srcdir}/staging here),
#     so the statically linked liblensfun looked for its database at
#     /build/ffmpeg-full/src/staging/share/lensfun and found nothing at
#     runtime — a silent lensfun-filter outage (elf:leak:staging, verified
#     against the published 9.0.2-3.45 artifact on 2026-11-17). Pointing
#     DATAROOTDIR at an absolute path also redirects the install step into
#     /usr/share, which fakeroot cannot write (run 43932960088), so instead:
#     install into staging, patch the generated config.h to the runtime
#     location, rebuild the static library and reinstall it.
lensfun_patch='s|#define SYSTEM_DB_PATH .*|#define SYSTEM_DB_PATH "/usr/share/lensfun"|'
if ! grep -qF 'liblensfun.a still carries the staging prefix' "$pkgbuild"; then
    python3 - "$pkgbuild" <<'PY1C' || fail 'lensfun datadir fixup failed'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
anchor = "    cmake --build build/lensfun --target install\n"
if anchor not in text:
    raise SystemExit('lensfun install anchor not found')
replacement = anchor + """    # lensfun bakes SYSTEM_DB_PATH from CMAKE_INSTALL_FULL_DATAROOTDIR, which
    # resolves against CMAKE_INSTALL_PREFIX (${_stagingdir}) — the statically
    # linked liblensfun would look for its database inside the build tree and
    # the lensfun filter would find nothing at runtime. Install into staging
    # (fakeroot cannot write /usr/share), then patch the generated config.h to
    # the real runtime location and rebuild + reinstall the static library.
    # Run 44858172826 proved a SYSTEM_DB_PATH-only rewrite is not enough: the
    # rebuilt liblensfun.a still carried a staging reference and the post-build
    # feature gate failed on elf:leak. Rewrite every staging path in config.h
    # (SYSTEM_DB_PATH first for the runtime DB location, then any other baked
    # prefix), assert the file is clean, and force the second install to
    # actually replace the previously installed archive.
    sed -i -e 's|#define SYSTEM_DB_PATH .*|#define SYSTEM_DB_PATH "/usr/share/lensfun"|' \\
        -e "s|${_stagingdir}|/usr/share|g" \\
        build/lensfun/config.h
    if grep -qF "${_stagingdir}" build/lensfun/config.h; then
        printf 'lensfun config.h still references the staging prefix:\\n'
        grep -nF "${_stagingdir}" build/lensfun/config.h
        exit 1
    fi
    # CONFIGURE_FILE does not wire config.h into the dependency graph,
    # so a plain rebuild would be a no-op: clean and rebuild the target.
    # cmake >= 4 rejects mixing 'clean' with other targets in one --target
    # list ("Building 'clean' and other targets together is not supported",
    # run 44788431213), so the clean and the rebuild are separate invocations.
    cmake --build build/lensfun --target clean
    cmake --build build/lensfun --target lensfun
    # cmake's file(INSTALL) skips byte-identical targets ("Up-to-date"); the
    # archive left by the first install is exactly the staging-flavoured build
    # being replaced, so remove it to make the reinstall unconditional.
    rm -f "${_stagingdir}/lib/liblensfun.a"
    cmake --install build/lensfun
    if strings -a "${_stagingdir}/lib/liblensfun.a" | grep -F "${_stagingdir}"; then
        printf 'liblensfun.a still carries the staging prefix after the rebuild.\\n'
        exit 1
    fi
"""
path.write_text(text.replace(anchor, replacement, 1))
PY1C
    grep -qF 'liblensfun.a still carries the staging prefix' "$pkgbuild" ||
        fail 'the lensfun SYSTEM_DB_PATH patch is missing after the rewrite'
fi

# 1d. Declare the lensfun runtime dependency: the library is statically
#     linked, so the binary needs the system database (usr/share/lensfun)
#     shipped by the lensfun package, not the lensfun library itself.
if ! grep -qE "^[[:space:]]*'lensfun'$" "$pkgbuild"; then
    python3 - "$pkgbuild" <<'PY1D' || fail 'lensfun depend insertion failed'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
anchor = "depends=(\n"
if anchor not in text:
    raise SystemExit('depends=() block not found')
text = text.replace(anchor, anchor + "    'lensfun'\n", 1)
path.write_text(text)
PY1D
fi

# 1e. ffmpeg 9.1's libastcenc feature check compiles <astcenc/astcenc.h>, but
#     the astc-encoder package ships the header flat (/usr/include/astcenc.h;
#     the CachyOS v3 repositories do not carry the package at all, so yay
#     builds the flat-layout AUR version at build time). AUR's prepare()
#     symlinks the flat header to include/astcenc/astcenc.h under $startdir,
#     but ffmpeg's configure never searches that tree, so the check dies with
#     "libastcenc not found" (CI run 44995240968). Two halves: retarget the
#     symlink when it dangles (here), and put the tree on the compiler's
#     search path in the flag block (step 3b). Skipped for AUR trees that do
#     not declare the symlink at all (pre-9.1 baselines).
if grep -qF 'ln -sf /usr/include/astcenc.h include/astcenc/astcenc.h' "$pkgbuild" &&
   ! grep -qF "configure dies with \"libastcenc not found\"" "$pkgbuild"; then
    python3 - "$pkgbuild" <<'PY1E' || fail 'astcenc include fixup failed'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
anchor = "    ln -sf /usr/include/astcenc.h include/astcenc/astcenc.h\n"
if anchor not in text:
    raise SystemExit('astcenc symlink anchor not found')
replacement = anchor + """    # The astc-encoder package ships the header flat (/usr/include/astcenc.h,
    # the AUR build installed by yay here) or in a subdirectory
    # (/usr/include/astcenc/astcenc.h); when the flat header is absent the
    # symlink above dangles and configure dies with "libastcenc not found".
    [[ -e include/astcenc/astcenc.h ]] ||
        ln -sf /usr/include/astcenc/astcenc.h include/astcenc/astcenc.h
"""
path.write_text(text.replace(anchor, replacement, 1))
PY1E
    grep -qF "configure dies with \"libastcenc not found\"" "$pkgbuild" ||
        fail 'the astcenc symlink retarget is missing after the rewrite'
fi

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

    # ffmpeg 9.1's libastcenc feature check compiles <astcenc/astcenc.h> while
    # the astc-encoder package ships the header flat (/usr/include/astcenc.h):
    # prepare() builds an include/astcenc tree under $startdir and this flag
    # puts it on the compiler's search path for the check and the build. The
    # directory may not exist on pre-9.1 baselines; an absent -I path is
    # harmless to gcc.
    export CFLAGS+=" -I${startdir}/include"

"""
p.write_text(s[:start] + block + s[end:])
PY2

# 3c. openapv 1.1 (API set 1) changed oapvm_create() to take a descriptor
#     argument, so the liboapv encoder of ffmpeg 9.0.x no longer compiles.
#     Without the upstream fix (FFmpeg commit c54710db) a rebuild against
#     openapv 1.1.1.0 fails, while the already published ffmpeg-full still
#     needs the removed liboapv.so.2 -- which breaks every consumer of
#     libavcodec, mpv included.
#
#     FFmpeg absorbed the fix upstream and first shipped it in 9.1; AUR
#     dropped the patch in the same commit that bumped to 9.1. The vendored
#     copy is therefore version-gated: while the tracked release predates the
#     upstream fix the overlay keeps injecting it (an AUR that stops carrying
#     it must not silently build without the fix), and from 9.1 on it must
#     stay out -- re-applying the patch to the fixed source fails in prepare()
#     ("Reversed (or previously applied) patch detected"). A release that
#     carries the fix while AUR still declares an openapv patch is an
#     upstream inconsistency and fails the sync loudly instead of being
#     patched over.
#
#     While vendored: this repository carries the commit as a file instead of
#     fetching it from code.ffmpeg.org: that endpoint re-renders the
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

pkgver="$(sed -nE 's/^pkgver=([0-9.]+)$/\1/p' "$pkgbuild")"
[[ -n "$pkgver" ]] || fail 'unable to parse a numeric pkgver for the openapv gate'
oapv_fix_upstream="$(python3 - "$pkgver" <<'PY0'
import sys

pkgver = tuple(int(part) for part in sys.argv[1].split('.'))
print('yes' if pkgver >= (9, 1) else 'no')
PY0
)"
[[ "$oapv_fix_upstream" == yes || "$oapv_fix_upstream" == no ]] ||
    fail "unable to compare the ffmpeg version for the openapv gate: ${pkgver}"

if [[ "$oapv_fix_upstream" == no ]]; then
    [[ -f "$oapv_path" ]] || fail "vendored openapv patch is missing: ${oapv_patch}"
    oapv_sum="$(sha256sum -- "$oapv_path" | cut -d' ' -f1)"
fi
oapv_sum="${oapv_sum:-}"

# AUR's .SRCINFO supplies the source/checksum ordering used below. Refresh it
# from the PKGBUILD first when possible so a stale AUR copy cannot shift the
# index onto a different checksum. makepkg refuses to run as root, and the CI
# integration job does run as root: fall back to the textual path there.
if command -v makepkg > /dev/null 2>&1 && (( EUID != 0 )); then
    ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO ) ||
        fail 'unable to refresh .SRCINFO before reconciling the openapv patch'
fi

python3 - "$pkgbuild" "$srcinfo" "$oapv_patch" "$oapv_sum" "$oapv_fix_upstream" <<'PY3'
from pathlib import Path
import re
import sys

pkgbuild_path = Path(sys.argv[1])
srcinfo_path = Path(sys.argv[2])
patch_name = sys.argv[3]
patch_sum = sys.argv[4]
upstream = sys.argv[5]
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

if upstream == 'yes':
    # The tracked ffmpeg release carries the fix (9.1 and later): the source
    # list must not declare the patch, or prepare() would re-apply hunks that
    # are already upstream ("Reversed (or previously applied) patch detected").
    if index is not None:
        fail('ffmpeg >= 9.1 carries the openapv 1.1 fix upstream, but the '
             'source list still declares an openapv patch: ' + sources[index])
    # Nothing to edit in this mode; the caller retires the vendored copy.
    sys.exit(0)

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

    # Anchor on the prepare() line that APPLIES the 050 patch, not on the first
    # mention of the name: the source array also lists the patch, and matching
    # that entry would splice the "patch -d ..." command into source=(),
    # splitting it into bogus array elements (ffmpeg-full 9.1 sync, 2026-11-22,
    # caught by check-package as "lists a missing local source: patch").
    match = re.search(r'^([ \t]*)patch [^\n]*050-ffmpeg-fix-cuda-nvcc-with-gcc14[.]patch[^\n]*$', text, re.M)
    if not match:
        fail('prepare() has no 050-ffmpeg-fix-cuda-nvcc-with-gcc14.patch apply line')
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

if [[ "$oapv_fix_upstream" == yes ]]; then
    rm -f -- "$oapv_path"
    printf 'ffmpeg-full overlay: openapv 1.1 fix is upstream since 9.1; the vendored patch is retired.\n'
else
    [[ "$(grep -cF "'${oapv_patch}'" "$pkgbuild")" == 1 ]] ||
        fail 'the vendored openapv source entry is missing or duplicated in PKGBUILD'
    [[ "$(grep -cF "'${oapv_sum}'" "$pkgbuild")" == 1 ]] ||
        fail 'the vendored openapv checksum is missing or duplicated in PKGBUILD'
    grep -qF "'${oapv_patch}'::" "$pkgbuild" &&
        fail 'the openapv source still points at a remote URL'
    [[ "$(grep -cE '^    patch .*openapv.*[.]patch' "$pkgbuild")" == 1 ]] ||
        fail 'the openapv patch is not applied exactly once in prepare()'
fi

# 4. Mirror the changes into .SRCINFO: regenerate with makepkg when available
#    (local sync runs); patch the two changed entries textually otherwise
#    (CI sync runners have no pacman).
# final_pkgrel 来自第 3 步（只升不降）：这里只复核 PKGBUILD 没被中途改过。
[[ "$(sed -nE 's/^pkgrel=([0-9]+(\.[0-9]+)?)$/\1/p' "$pkgbuild")" == "$final_pkgrel" ]] ||
    fail 'pkgrel changed between overlay steps'

if command -v makepkg > /dev/null 2>&1 && (( EUID != 0 )); then
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

if [[ "$oapv_fix_upstream" == yes ]]; then
    printf 'ffmpeg-full overlay applied: libnpp enabled, openapv 1.1 fix upstream, pkgrel %s.\n' \
        "$final_pkgrel"
else
    printf 'ffmpeg-full overlay applied: libnpp enabled, openapv 1.1 fix from the vendored patch, pkgrel %s.\n' \
        "$final_pkgrel"
fi
