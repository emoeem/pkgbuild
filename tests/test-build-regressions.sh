#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s\n' '1/5: verify Git source-cache collision is removed while matching cache survives'
grep -Fq 'source_cache_dir="${cache_dir}/sources/${package_name}"' "$root/scripts/build-in-arch.sh" \
    || fail 'Git source cache is not isolated per target package'
package_dir="$work/package"
cache_dir="$work/cache"
mkdir -p "$package_dir" "$cache_dir"
printf 'pkgbase = fixture\n\tsource = git+https://github.com/astrand/xclip\n' > "$package_dir/.SRCINFO"

git init -q "$cache_dir/xclip"
git -C "$cache_dir/xclip" -c safe.bareRepository=all remote add origin https://example.invalid/wrong-repository
bash "$root/scripts/validate-source-cache.sh" "$package_dir" "$cache_dir"
[[ ! -e "$cache_dir/xclip" ]] || fail 'stale Git cache collision was not removed'

git init -q "$cache_dir/xclip"
git -C "$cache_dir/xclip" -c safe.bareRepository=all remote add origin https://github.com/astrand/xclip.git
bash "$root/scripts/validate-source-cache.sh" "$package_dir" "$cache_dir"
[[ -d "$cache_dir/xclip/.git" ]] || fail 'matching Git source cache was removed'

printf '%s\n' '2/5: verify CUDA builder supplies the nvcc host compiler required by ffmpeg-full'
grep -Fq -- 'packages="$packages cuda gcc15"' "$root/.github/builder/Dockerfile" \
    || fail 'CUDA builder does not install gcc15 for nvcc'
grep -Fq -- "'cuda'" "$root/packages/ffmpeg-full/PKGBUILD" \
    || fail 'ffmpeg-full does not declare CUDA build dependency'
grep -Fq -- 'NVCC_CCBIN=/usr/bin/g++-15' "$root/scripts/build-in-arch.sh" \
    || fail 'ffmpeg-full builder path does not pin nvcc to GCC 15'
printf '%s\n' '3/5: verify local Zen 3 performance profile and RTX 4050 CUDA target'
grep -Fq -- '-march=znver3 -mtune=znver3 -O3' "$root/config/emo-native-flags.conf" || fail 'local Zen 3 profile missing'
# Published ffmpeg-full artifacts have to stay usable on every x86-64-v3
# machine, so the overlay pins the portable baseline instead of the local Zen 3
# profile and must never inherit the builder host's -march=native.
grep -Fq -- '-march=x86-64-v3 -mtune=generic' "$root/packages/ffmpeg-full/PKGBUILD" \
    || fail 'ffmpeg-full does not pin the portable x86-64-v3 baseline'
if grep -v '^[[:space:]]*#' "$root/packages/ffmpeg-full/PKGBUILD" | grep -Fq -- '-march=native'; then
    fail 'ffmpeg-full inherits the builder host -march=native'
fi
grep -Fq -- '--enable-lto' "$root/packages/ffmpeg-full/PKGBUILD" || fail 'ffmpeg-full LTO missing'
if grep -Fq -- '--enable-lto=full' "$root/packages/ffmpeg-full/PKGBUILD"; then
    fail 'ffmpeg-full uses the unsupported --enable-lto=full'
fi
grep -Fq -- 'EMO_CMAKE_CUDA_ARCHITECTURES="89"' "$root/config/emo-native-flags.sh" \
    || fail 'CUDA 89 target missing from the native profile'
grep -Fq -- 'objective-c -c' "$root/tests/test-cachyos-environment.sh" || fail 'Objective-C preflight missing'

printf '%s\n' '4/5: verify timing_resources survives the readonly build-in-arch.sh cache variable'
# build-in-arch.sh declares source_cache_dir readonly at top level; a
# "local source_cache_dir" inside timing_resources then fails with
# "readonly variable" and, under set -e, aborted every build before it started.
(
    readonly source_cache_dir="$work/sources"
    mkdir -p "$source_cache_dir"
    # shellcheck disable=SC1090
    source "$root/scripts/lib/timing.sh"
    timing_resources "$work/timing.env" "$work" "$source_cache_dir" 0
) || fail 'timing_resources aborts when source_cache_dir is readonly'
grep -Fq 'package_bytes=0' "$work/timing.env" || fail 'timing_resources did not write its report'
grep -Fq 'sources_dir=' "$root/scripts/lib/timing.sh" ||
    fail 'timing_resources does not keep a collision-free cache variable name'

printf '%s\n' '5/5: verify the ordering wait skips prerequisites that are not part of the run'
# The jobs API only lists the packages this run selected. A prerequisite that
# is absent (mpeghdec / svt-jpeg-xs-git for ffmpeg-full in run 38036057599) is
# not being rebuilt, so waiting for it deadlocks the whole build.
stub="$work/bin"
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"jobs":[{"name":"Build unrelated","status":"completed","conclusion":"success"}]}'
STUB
chmod +x "$stub/gh"
start=$SECONDS
PATH="$stub:$PATH" timeout 60 bash "$root/scripts/wait-for-build-dependencies.sh" \
    --package ffmpeg-full --run-id 1 --repository fixture/repo >"$work/wait.out" 2>&1 ||
    fail 'the ordering wait failed on prerequisites that are not part of the run'
(( SECONDS - start < 30 )) || fail 'the ordering wait slept on prerequisites that are absent'
grep -Fq 'Not part of this run' "$work/wait.out" ||
    fail 'absent prerequisites were not reported as skipped'
printf '%s\n' '6/6: verify clean-chroot systemd-nspawn disables host journal linking'
# Docker builders do not have a host machine-id/journal. devtools' arch-nspawn
# inherits PATH, so the temporary wrapper must disable journal linking without
# patching the installed devtools binary or changing the host configuration.
# The wrapper itself lives in scripts/lib/nspawn-shim.sh, shared with the
# upgrade-path test; the build script must source it and keep the shim ahead
# of the system PATH.
grep -Fq -- 'systemd-nspawn --link-journal=no --keep-unit "$@"' "$root/scripts/lib/nspawn-shim.sh" \
    || fail 'nspawn shim does not disable host journal linking'
grep -Fq -- 'source "$script_dir/lib/nspawn-shim.sh"' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot does not use the shared nspawn shim'
grep -Fq -- 'nspawn_shim_install' "$root/scripts/test-upgrade-path.sh" \
    || fail 'upgrade-path test does not use the shared nspawn shim'
grep -Fq -- 'PATH="$nspawn_wrapper_dir:/usr/lib/ccache/bin:$PATH"' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot nspawn wrapper is not ahead of the system PATH'
grep -Fq -- 'cleanup() { rm -rf -- "${cleanup_paths[@]}"; }' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot does not clean up the temporary nspawn wrapper'
grep -Fq -- 'cleanup_paths+=("$work_root")' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot work root is not registered for cleanup'
grep -Fq -- 'container_security_args+=(--privileged)' "$root/.github/workflows/build.yml" \
    || fail 'clean-chroot builder does not use the privileged disposable CI container'
if grep -Eq -- '--cgroup-parent|--cgroupns|runner_cgroup_(parent|dir)|/sys/fs/cgroup.*:rw' "$root/.github/workflows/build.yml"; then
    fail 'clean-chroot workflow still contains experimental host cgroup configuration'
fi
printf '%s\n' '7/7: verify an orphan published package cannot crash the soname scan'
# 发布过但源码树已没有的包（改名后遗留的旧 pkgname）没有 source 目录：
# 空的关联数组下标在 bash 里是硬错误（bad array subscript），会让整次漂移
# 扫描崩掉，走不到下面专门处理孤儿的 ORPHAN 分支（run 39172370345）。
# 查 .rebuild-on 之前必须先确认目录非空。
soname_script="$root/scripts/check-repository-sonames.sh"
lookup_guard="$(awk '
    /^[[:space:]]*if \[\[ -n "\$directory" \]\]; then$/ { guard = NR }
    /declared_for_package="\$\{declared_sonames\[\$directory\]:-\}"/ {
        if (guard == 0 || NR - guard > 2) { print "unguarded"; exit }
        print "guarded"
    }
' "$soname_script")"
[[ "$lookup_guard" == guarded ]] \
    || fail 'soname scan indexes declared_sonames by a possibly empty source directory'
printf '%s\n' '8/8: verify scx-scheds-git keeps shipping nothing that scx-tools owns'
# Upstream's package() installs every executable from target/release, and
# upstream started building scxtui -- which the scx-tools dependency already
# ships as /usr/bin/scxtui. pacman aborts the transaction with
# "scx-scheds-git: /usr/bin/scxtui exists in filesystem (owned by scx-tools)"
# after a 14 minute compile (run 39571220772).
#
# The fix is an overlay, not a PKGBUILD edit: sync-aur-packages.sh replaces the
# whole package directory on every AUR sync, which is how the previous direct
# edit was silently reverted by commit e38a21e. Both halves are asserted, so
# either losing the overlay or losing its application is caught.
scx_overlay="$root/scripts/overlays/scx-scheds-git.sh"
[[ -x "$scx_overlay" ]] || fail 'scx-scheds-git overlay is missing or not executable'
grep -Fq -- "! -name 'scxtui'" "$root/packages/scx-scheds-git/PKGBUILD" \
    || fail 'scx-scheds-git installs scxtui, which collides with scx-tools'
grep -Fq -- '# emoeem overlay: scxtui belongs to scx-tools' "$root/packages/scx-scheds-git/PKGBUILD" \
    || fail 'scx-scheds-git PKGBUILD carries no overlay marker'
grep -Fq -- 'scripts/overlays' "$root/scripts/sync-aur-packages.sh" \
    || fail 'AUR sync no longer re-applies overlaid package directories'

# The overlay must survive a sync: apply it to a pristine copy of upstream's
# rule, then apply it again and require an identical file.
scx_fixture="$work/scx-fixture"
mkdir -p "$scx_fixture"
cat > "$scx_fixture/PKGBUILD" <<'PKGBUILD'
package() {
  cd $_gitname

  # Install all built executables (skip .so and .d files)
  find target/release \
    -maxdepth 1 -type f -executable ! -name '*.so' \
    -exec install -Dm755 -t "$pkgdir/usr/bin/" {} +
}
PKGBUILD
bash "$scx_overlay" "$scx_fixture" || fail 'scx-scheds-git overlay failed on upstream package()'
grep -Fq -- "! -name 'scxtui'" "$scx_fixture/PKGBUILD" \
    || fail 'scx-scheds-git overlay did not exclude scxtui from install'
first_sum="$(sha256sum "$scx_fixture/PKGBUILD" | cut -d' ' -f1)"
bash "$scx_overlay" "$scx_fixture" || fail 'scx-scheds-git overlay is not idempotent'
[[ "$(sha256sum "$scx_fixture/PKGBUILD" | cut -d' ' -f1)" == "$first_sum" ]] \
    || fail 're-running the scx-scheds-git overlay rewrote the PKGBUILD'

printf '%s\n' '9: verify a stale cached source is removed before makepkg can hash it'
# The failure this guards: makepkg prints `-> Found <name>` for whatever SRCDEST
# returned and hashes that, so a cached copy whose bytes no longer match the
# package's declared checksum fails the validity check on every run and no
# rebuild can ever pass, because nothing re-fetches the file.
stale="$work/stale"
mkdir -p "$stale/cache"
empty_sum="$(printf '' | sha256sum | cut -d' ' -f1)"
cat >"$stale/.SRCINFO" <<EOF
pkgbase = fixture
	source = mine.patch::https://example.invalid/mine.patch
	sha256sums = $empty_sum
EOF
printf 'bytes that are not the declared content\n' >"$stale/cache/mine.patch"
bash "$root/scripts/validate-source-cache.sh" "$stale" "$stale/cache" >"$stale/out.txt" 2>&1 \
    || fail 'validator treated a stale cache entry as a fatal error instead of healing it'
[[ ! -e "$stale/cache/mine.patch" ]] || fail 'stale cached source survived validation'
grep -Fq 'stale entry/entries removed' "$stale/out.txt" || fail 'validator did not report the heal'

printf '%s\n' '10: verify a matching cached source survives validation'
: >"$stale/cache/mine.patch"
bash "$root/scripts/validate-source-cache.sh" "$stale" "$stale/cache" >"$stale/out2.txt" 2>&1 \
    || fail 'validator rejected a cache entry that matches the declaration'
[[ -f "$stale/cache/mine.patch" ]] || fail 'matching cached source was removed'

printf '%s\n' '11: verify a local source that drifted from its declared checksum fails fast'
# A local file in the package directory is part of the repository. If its content
# stops matching the declared checksum, that is a defect no cache can repair, so
# the build must stop with the file named instead of failing ten minutes later
# on a generic makepkg message.
localdir="$work/local"
mkdir -p "$localdir/cache"
printf 'patch body\n' >"$localdir/blob.patch"
blob_sum="$(sha256sum "$localdir/blob.patch" | cut -d' ' -f1)"
cat >"$localdir/.SRCINFO" <<EOF
pkgbase = fixture
	source = blob.patch
	sha256sums = $blob_sum
EOF
bash "$root/scripts/validate-source-cache.sh" "$localdir" "$localdir/cache" >/dev/null 2>&1 \
    || fail 'validator rejected an intact local source'
printf 'drifted\n' >>"$localdir/blob.patch"
if out="$(bash "$root/scripts/validate-source-cache.sh" "$localdir" "$localdir/cache" 2>&1)"; then
    fail 'validator accepted a local source that no longer matches its checksum'
fi
printf '%s' "$out" | grep -Fq 'blob.patch does not match its declared checksum' \
    || fail 'validator did not name the drifted local source'

printf '%s\n' '12: verify both build paths validate the source cache before makepkg runs'
grep -Fq 'validate-source-cache.sh' "$root/scripts/build-in-arch.sh" \
    || fail 'docker build path does not validate the source cache'
grep -Fq 'validate-source-cache.sh' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot build path does not validate the source cache'

printf '%s\n' '13: verify a URL source shadowed by a drifted package-dir file fails fast'
# makepkg resolves $startdir/<name> before SRCDEST for URL-declared files too.
# A committed copy that disagrees with the declared checksum is a repository
# defect (ffmpeg-full 9.0.2-2.36 at ced12ff), not a stale cache that a rebuild
# can heal.
shadow="$work/shadow"
mkdir -p "$shadow/cache"
printf 'committed bytes\n' >"$shadow/mine.patch"
shadow_sum="$(sha256sum "$shadow/mine.patch" | cut -d' ' -f1)"
cat >"$shadow/.SRCINFO" <<EOF
pkgbase = fixture
	source = mine.patch::https://example.invalid/mine.patch
	sha256sums = $shadow_sum
EOF
bash "$root/scripts/validate-source-cache.sh" "$shadow" "$shadow/cache" >/dev/null 2>&1 \
    || fail 'validator rejected a URL source whose package-dir copy matches'
printf 'remote rendering\n' >>"$shadow/mine.patch"
if out="$(bash "$root/scripts/validate-source-cache.sh" "$shadow" "$shadow/cache" 2>&1)"; then
    fail 'validator accepted a URL source shadowed by a drifted package-dir copy'
fi
printf '%s' "$out" | grep -Fq 'mine.patch shadows the remote source' \
    || fail 'validator did not name the package-dir copy that shadows the URL source'
printf '%s' "$out" | grep -Fq 'the build would hash' \
    || fail 'validator did not explain that makepkg prefers the package-dir copy'

printf '%s\n' '14: verify the ffmpeg-full overlay gates the vendored openapv patch by ffmpeg version'
# Pre-9.1 releases need the vendored openapv 1.1 fix (FFmpeg commit c54710db):
# the overlay must reconcile AUR's URL declaration to the committed file
# (2026-10-27 sync) and re-inject the patch when AUR drops it. From 9.1 on the
# fix is upstream: the vendored copy must retire, and an AUR that still
# declares the patch for such a release must fail the sync instead of being
# applied on top of already-fixed code.
overlay_fixture="$work/ffmpeg-full"
make_oapv_fixture() {
    rm -rf "$overlay_fixture"
    mkdir -p "$overlay_fixture"
    cp "$root/packages/ffmpeg-full/PKGBUILD" "$root/packages/ffmpeg-full/.SRCINFO" \
        "$root/packages/ffmpeg-full/.lensfun-pin" "$root/packages/ffmpeg-full"/0*.patch "$overlay_fixture/"
    printf 'synthetic openapv 1.1 fix\n' >"$overlay_fixture/080-ffmpeg-openapv1.1-fix.patch"
}
oapv_patch_sum() {
    sha256sum "$overlay_fixture/080-ffmpeg-openapv1.1-fix.patch" | cut -d' ' -f1
}
# Adds the plain vendored 080 entry (source, checksum, prepare() apply line)
# to a PKGBUILD/.SRCINFO pair that does not declare it.
add_vendored_oapv() {
    python3 - "$overlay_fixture/PKGBUILD" "$overlay_fixture/.SRCINFO" "$(oapv_patch_sum)" <<'PY'
from pathlib import Path
import re
import sys

pkgbuild, srcinfo, patch_sum = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
patch_name = '080-ffmpeg-openapv1.1-fix.patch'

text = pkgbuild.read_text()
anchor = re.search(r"^([ \t]*)'070-ffmpeg-whisper[.]cpp-fix-pkgconfig[.]patch'[^\n]*$", text, re.M)
assert anchor, 'no 070 source entry to anchor the vendored openapv patch'
text = text[:anchor.end()] + '\n' + anchor.group(1) + f"'{patch_name}'" + text[anchor.end():]
apply_line = re.search(r'^([ \t]*)patch [^\n]*050-ffmpeg-fix-cuda-nvcc-with-gcc14[.]patch[^\n]*$',
                       text, re.M)
assert apply_line, 'no 050 apply line to anchor the openapv prepare() call'
text = text[:apply_line.end()] + \
    f'\n{apply_line.group(1)}patch -d "ffmpeg-${{pkgver}}" -Np1 -i "${{srcdir}}/{patch_name}"' + \
    text[apply_line.end():]
# The 080 source goes last-but-one (after 070, before LICENSE), so its
# checksum must land immediately before the LICENSE checksum to keep the
# source/sum pairing positional.
license_sum = re.search(r"^([ \t]*)'[0-9a-f]{64}'\)\s*$", text, re.M)
assert license_sum, 'no LICENSE checksum entry to anchor the openapv checksum'
text = text[:license_sum.start()] + \
    f"{license_sum.group(1)}'{patch_sum}'\n" + text[license_sum.start():]
pkgbuild.write_text(text)

rows = srcinfo.read_text().splitlines(keepends=True)
source_rows = [i for i, row in enumerate(rows) if row.startswith('\tsource = ')]
sum_rows = [i for i, row in enumerate(rows) if row.startswith('\tsha256sums = ')]
anchor_pos = next(i for i, spec in enumerate(source_rows)
                  if '070-ffmpeg-whisper' in rows[source_rows[i]])
sum_insert = sum_rows[anchor_pos] + 1
source_insert = source_rows[anchor_pos] + 1
rows.insert(sum_insert, f'\tsha256sums = {patch_sum}\n')
rows.insert(source_insert, f'\tsource = {patch_name}\n')
srcinfo.write_text(''.join(rows))
PY
}
# Converts the plain vendored 080 entry into AUR's URL declaration form.
declare_oapv_url() {
    python3 - "$overlay_fixture/PKGBUILD" "$overlay_fixture/.SRCINFO" "$(oapv_patch_sum)" <<'PY'
from pathlib import Path
import sys

pkgbuild, srcinfo, vendored_sum = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
url = 'https://code.ffmpeg.org/FFmpeg/FFmpeg/commit/c54710db21c1827dbc3e47658a562525af0fe528.patch'
remote_sum = '6eda059a' + '0' * 56

text = pkgbuild.read_text()
text = text.replace("        '080-ffmpeg-openapv1.1-fix.patch'\n",
                    "        '080-ffmpeg-openapv1.1-fix.patch'::'" + url + "'\n", 1)
text = text.replace(vendored_sum, remote_sum, 1)
pkgbuild.write_text(text)

text = srcinfo.read_text()
text = text.replace('\tsource = 080-ffmpeg-openapv1.1-fix.patch\n',
                    '\tsource = 080-ffmpeg-openapv1.1-fix.patch::' + url + '\n', 1)
text = text.replace(f'\tsha256sums = {vendored_sum}\n',
                    f'\tsha256sums = {remote_sum}\n', 1)
srcinfo.write_text(text)
PY
}
# Removes every 080 declaration (AUR stopped carrying the patch). Works on
# both the plain vendored form and AUR's URL form: the checksum to remove is
# found through the .SRCINFO source/sum pairing, not by value.
strip_oapv() {
    python3 - "$overlay_fixture/PKGBUILD" "$overlay_fixture/.SRCINFO" <<'PY'
from pathlib import Path
import re
import sys

pkgbuild, srcinfo = Path(sys.argv[1]), Path(sys.argv[2])
patch_name = '080-ffmpeg-openapv1.1-fix.patch'

rows = srcinfo.read_text().splitlines(keepends=True)
source_rows = [i for i, row in enumerate(rows) if row.startswith('\tsource = ')]
sum_rows = [i for i, row in enumerate(rows) if row.startswith('\tsha256sums = ')]
index = next((i for i, row in enumerate(source_rows)
              if patch_name in rows[source_rows[i]]), None)
patch_sum = None
if index is not None:
    patch_sum = rows[sum_rows[index]].split(' = ', 1)[1].strip()
    del rows[sum_rows[index]]
    del rows[source_rows[index]]
    srcinfo.write_text(''.join(rows))

text = pkgbuild.read_text()
if patch_sum:
    text = text.replace(f"            '{patch_sum}'\n", '', 1)
text = re.sub(r"^[ \t]*'" + re.escape(patch_name) + r"'(?:::)?[^\n]*\n", '',
              text, count=1, flags=re.M)
text = '\n'.join(line for line in text.splitlines()
                 if not (line.lstrip().startswith('patch') and 'openapv' in line)) + '\n'
pkgbuild.write_text(text)
PY
}
# The 2026-11-22 regression: the prepare() re-injection anchor matched the 050
# entry inside source=() and spliced the "patch -d ..." command into the
# array. Every fixture that runs the overlay re-asserts the array shape.
assert_source_block_quoted() {
    python3 - "$overlay_fixture/PKGBUILD" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
match = re.search(r'^source=\([^\n]*\n(.*?)^[^\n]*\)\s*$', text, re.M | re.S)
assert match, 'source=() block not found'
lines = match.group(1).splitlines()
bad = [line for line in lines if line.strip() and not re.match(r"^\s*['\"]", line)]
assert not bad, 'unquoted tokens inside source=(): %r' % bad
PY
}

# Scenario A: a pre-9.1 ffmpeg where AUR declares 080 as a URL. The overlay
# must reconcile the declaration to the vendored bytes.
make_oapv_fixture
strip_oapv
sed -i 's/^pkgver=.*/pkgver=9.0.2/' "$overlay_fixture/PKGBUILD"
add_vendored_oapv
declare_oapv_url
vendored_sum="$(oapv_patch_sum)"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay failed on an AUR-style PKGBUILD'
grep -qF "        '080-ffmpeg-openapv1.1-fix.patch'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not restore the plain vendored openapv source entry'
grep -qF "'080-ffmpeg-openapv1.1-fix.patch'::" "$overlay_fixture/PKGBUILD" \
    && fail 'overlay left the openapv source pointing at a remote URL'
grep -qF "            '$vendored_sum'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not restore the checksum of the vendored openapv patch'
grep -qF '	source = 080-ffmpeg-openapv1.1-fix.patch' "$overlay_fixture/.SRCINFO" \
    || fail 'overlay did not restore the openapv entry in .SRCINFO'
lensfun_pin="$(tr -d '[:space:]' < "$overlay_fixture/.lensfun-pin")"
grep -qF "lensfun.git#commit=${lensfun_pin}" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not (re-)apply the vendored lensfun pin to the AUR-style PKGBUILD'
bash -n "$overlay_fixture/PKGBUILD" \
    || fail 'the overlaid ffmpeg PKGBUILD does not parse'
assert_source_block_quoted
grep -qF "	sha256sums = $vendored_sum" "$overlay_fixture/.SRCINFO" \
    || fail 'overlay did not restore the openapv checksum in .SRCINFO'
first_sum="$(sha256sum "$overlay_fixture/PKGBUILD" | cut -d' ' -f1)"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay is not idempotent'
[[ "$(sha256sum "$overlay_fixture/PKGBUILD" | cut -d' ' -f1)" == "$first_sum" ]] \
    || fail 're-running the ffmpeg-full overlay rewrote the PKGBUILD'

# Scenario B: a pre-9.1 ffmpeg where AUR drops the patch entirely. The overlay
# must add the committed copy back instead of building without the fix.
strip_oapv
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay failed to re-inject a missing openapv patch'
grep -qF "        '080-ffmpeg-openapv1.1-fix.patch'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not re-inject the vendored openapv source entry'
grep -qF "            '$vendored_sum'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not re-inject the vendored openapv checksum'
[[ "$(grep -cE '^    patch .*openapv.*[.]patch' "$overlay_fixture/PKGBUILD")" == 1 ]] \
    || fail 'overlay did not re-inject the openapv prepare line exactly once'
assert_source_block_quoted

# Scenario C: ffmpeg 9.1+ carries the fix, a leftover vendored copy exists
# (the transition sync). The overlay must retire the file and leave the
# declaration alone.
make_oapv_fixture
sed -i 's/^pkgver=.*/pkgver=9.1/' "$overlay_fixture/PKGBUILD"
strip_oapv
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay failed on a release that carries the openapv fix upstream'
[[ ! -e "$overlay_fixture/080-ffmpeg-openapv1.1-fix.patch" ]] \
    || fail 'overlay did not retire the vendored openapv patch for an ffmpeg that no longer needs it'
grep -qF '080-ffmpeg-openapv1.1-fix.patch' "$overlay_fixture/PKGBUILD" \
    && fail 'overlay re-declared the openapv patch for an ffmpeg that carries the fix upstream'
grep -qE '^    patch .*openapv.*[.]patch' "$overlay_fixture/PKGBUILD" \
    && fail 'overlay re-applied the openapv patch for an ffmpeg that carries the fix upstream'
# ffmpeg 9.1's libastcenc check compiles <astcenc/astcenc.h> while the
# astc-encoder package ships the header flat; the overlay must mirror the
# include tree to the stable $startdir location (makepkg runs prepare() with
# cwd=$srcdir) and put it on the compiler's search path.
grep -qF 'ln -sfn /usr/include/astcenc.h "$startdir/include/astcenc/astcenc.h"' \
    "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not add the astcenc $startdir mirror'
grep -qF 'export CFLAGS+=" -I${startdir}/include"' "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not put the astcenc include tree on the search path'

# Scenario D: ffmpeg 9.1+ but AUR still declares the patch. Applying it would
# die in prepare() ("Reversed (or previously applied) patch detected"); the
# sync must fail loudly instead.
make_oapv_fixture
sed -i 's/^pkgver=.*/pkgver=9.1/' "$overlay_fixture/PKGBUILD"
strip_oapv
add_vendored_oapv
declare_oapv_url
if oapv_out="$(bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" 2>&1)"; then
    fail 'overlay accepted an openapv patch declaration for a release that carries the fix upstream'
fi
printf '%s' "$oapv_out" | grep -Fq 'carries the openapv 1.1 fix upstream' \
    || fail 'overlay did not name the upstream openapv inconsistency'

printf '%s\n' '15: verify package checks hash declared sources before a sync commits'
grep -Fq 'validate-source-cache.sh' "$root/scripts/check-package.sh" \
    || fail 'check-package.sh does not validate source checksums at sync time'

printf '%s\n' '16: verify a bare mirror, which is what makepkg actually creates, survives validation'
# makepkg runs `git clone --origin=origin --mirror`, so every healthy cache entry
# is a bare repository with no .git subdirectory. Testing for .git declared each
# of them a collision, deleted it, and re-cloned the whole source on every build
# -- while still reporting the heal, so the cost was invisible.
bare_pkg="$work/bare-package"
bare_cache="$work/bare-cache"
mkdir -p "$bare_pkg" "$bare_cache"
printf 'pkgbase = fixture\n\tsource = git+https://github.com/astrand/xclip\n' >"$bare_pkg/.SRCINFO"
git init -q --bare "$bare_cache/xclip"
git -C "$bare_cache/xclip" -c safe.bareRepository=all remote add origin https://github.com/astrand/xclip
bash "$root/scripts/validate-source-cache.sh" "$bare_pkg" "$bare_cache" >"$work/bare-out.txt" 2>&1 \
    || fail 'validator failed on a healthy bare mirror'
[[ -d "$bare_cache/xclip" ]] || fail 'validator removed a healthy bare mirror'
grep -Fq 'Removing' "$work/bare-out.txt" && fail 'validator healed a healthy bare mirror'

# A bare mirror of the wrong repository must still be caught: the declaration is
# the authority, and a mismatched remote is what makes makepkg abort with
# "%s is not a clone of %s".
git -C "$bare_cache/xclip" -c safe.bareRepository=all remote set-url origin https://example.invalid/other
bash "$root/scripts/validate-source-cache.sh" "$bare_pkg" "$bare_cache" >/dev/null 2>&1 \
    || fail 'validator failed while removing a stale bare mirror'
[[ ! -e "$bare_cache/xclip" ]] || fail 'a bare mirror pointing at the wrong remote survived'

printf '%s\n' '17: verify an unreadable dependency mirror is removed and a healthy one is kept'
# $SRCDEST is one directory per package and the AUR dependency builds yay runs
# for that package export the same one, so dependency mirrors appear there
# without ever being declared in .SRCINFO. Nothing in the source list could see
# the corrupted astc-encoder mirror that made ffmpeg-full fail with
# "is not a clone of" on every rebuild.
dep_pkg="$work/dep-package"
dep_cache="$work/dep-cache"
mkdir -p "$dep_pkg" "$dep_cache"
printf 'pkgbase = fixture\n\tsource = git+https://github.com/astrand/xclip\n' >"$dep_pkg/.SRCINFO"
git init -q --bare "$dep_cache/xclip"
git -C "$dep_cache/xclip" -c safe.bareRepository=all remote add origin https://github.com/astrand/xclip
# A dependency mirror that is a real repository: not declared, so its intended
# URL is unknown and guessing would delete a working cache. It must survive.
git init -q --bare "$dep_cache/healthydep"
git -C "$dep_cache/healthydep" -c safe.bareRepository=all remote add origin https://example.invalid/healthydep
# A dependency mirror with no readable remote: makepkg aborts on it before it
# fetches anything, so it cannot be a clone of anything and must go.
mkdir -p "$dep_cache/brokendep/objects"
printf 'ref: refs/heads/main\n' >"$dep_cache/brokendep/HEAD"
bash "$root/scripts/validate-source-cache.sh" "$dep_pkg" "$dep_cache" >"$work/dep-out.txt" 2>&1 \
    || fail 'validator failed on an undeclared dependency mirror'
[[ ! -e "$dep_cache/brokendep" ]] || fail 'an unreadable dependency mirror survived validation'
[[ -d "$dep_cache/healthydep" ]] || fail 'an undeclared but healthy dependency mirror was deleted'
[[ -d "$dep_cache/xclip" ]] || fail 'the declared bare mirror was removed by the sweep'
grep -Fq 'unreadable dependency source cache' "$work/dep-out.txt" \
    || fail 'the unreadable mirror was removed without naming why'

printf '%s\n' 'All build regression tests passed.'
