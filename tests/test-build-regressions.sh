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
git -C "$cache_dir/xclip" remote add origin https://example.invalid/wrong-repository
bash "$root/scripts/validate-source-cache.sh" "$package_dir" "$cache_dir"
[[ ! -e "$cache_dir/xclip" ]] || fail 'stale Git cache collision was not removed'

git init -q "$cache_dir/xclip"
git -C "$cache_dir/xclip" remote add origin https://github.com/astrand/xclip.git
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

printf '%s\n' '14: verify the ffmpeg-full overlay restores the vendored openapv patch after an AUR sync'
# Reproduce the 2026-10-27 sync: AUR declares 080 as a URL with its own
# checksum while the repository keeps the vendored bytes. The overlay must
# reconcile the declaration to the committed file on every run.
overlay_fixture="$work/ffmpeg-full"
mkdir -p "$overlay_fixture"
cp "$root/packages/ffmpeg-full/PKGBUILD" "$root/packages/ffmpeg-full/.SRCINFO" \
    "$root/packages/ffmpeg-full"/0*.patch "$overlay_fixture/"
vendored_sum="$(sha256sum "$overlay_fixture/080-ffmpeg-openapv1.1-fix.patch" | cut -d' ' -f1)"
python3 - "$overlay_fixture/PKGBUILD" "$overlay_fixture/.SRCINFO" "$vendored_sum" <<'PY'
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
grep -qF "	sha256sums = $vendored_sum" "$overlay_fixture/.SRCINFO" \
    || fail 'overlay did not restore the openapv checksum in .SRCINFO'
first_sum="$(sha256sum "$overlay_fixture/PKGBUILD" | cut -d' ' -f1)"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay is not idempotent'
[[ "$(sha256sum "$overlay_fixture/PKGBUILD" | cut -d' ' -f1)" == "$first_sum" ]] \
    || fail 're-running the ffmpeg-full overlay rewrote the PKGBUILD'
# And if AUR drops the patch entirely, the overlay must add the committed copy
# back instead of building without the openapv 1.1 fix.
python3 - "$overlay_fixture/PKGBUILD" "$overlay_fixture/.SRCINFO" "$vendored_sum" <<'PY'
from pathlib import Path
import sys

pkgbuild, srcinfo, vendored_sum = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = pkgbuild.read_text()
text = text.replace("        '080-ffmpeg-openapv1.1-fix.patch'\n", '', 1)
text = text.replace(f"            '{vendored_sum}'\n", '', 1)
text = '\n'.join(line for line in text.splitlines()
                 if not (line.lstrip().startswith('patch') and 'openapv' in line)) + '\n'
pkgbuild.write_text(text)

text = srcinfo.read_text()
text = text.replace('\tsource = 080-ffmpeg-openapv1.1-fix.patch\n', '', 1)
text = text.replace(f'\tsha256sums = {vendored_sum}\n', '', 1)
srcinfo.write_text(text)
PY
bash "$root/scripts/overlays/ffmpeg-full.sh" "$overlay_fixture" >/dev/null \
    || fail 'ffmpeg-full overlay failed to re-inject a missing openapv patch'
grep -qF "        '080-ffmpeg-openapv1.1-fix.patch'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not re-inject the vendored openapv source entry'
grep -qF "            '$vendored_sum'" "$overlay_fixture/PKGBUILD" \
    || fail 'overlay did not re-inject the vendored openapv checksum'
[[ "$(grep -cE '^    patch .*openapv.*[.]patch' "$overlay_fixture/PKGBUILD")" == 1 ]] \
    || fail 'overlay did not re-inject the openapv prepare line exactly once'

printf '%s\n' '15: verify package checks hash declared sources before a sync commits'
grep -Fq 'validate-source-cache.sh' "$root/scripts/check-package.sh" \
    || fail 'check-package.sh does not validate source checksums at sync time'

printf '%s\n' 'All build regression tests passed.'
