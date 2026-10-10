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
grep -Fq -- 'systemd-nspawn --link-journal=no --keep-unit "$@"' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot does not disable systemd-nspawn host journal linking'
grep -Fq -- 'PATH="$nspawn_wrapper_dir:/usr/lib/ccache/bin:$PATH"' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot nspawn wrapper is not ahead of the system PATH'
grep -Fq -- 'cleanup() { rm -rf -- "${cleanup_paths[@]}"; }' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot does not clean up the temporary nspawn wrapper'
grep -Fq -- 'cleanup_paths+=("$work_root")' "$root/scripts/build-in-clean-chroot.sh" \
    || fail 'clean-chroot work root is not registered for cleanup'
grep -Fq -- '--cgroup-parent="$runner_cgroup" --cgroupns=host' "$root/.github/workflows/build.yml" \
    || fail 'clean-chroot container is not nested under the delegated job cgroup'
grep -Fq -- '--cgroupns=host --volume "$runner_cgroup_dir:$runner_cgroup_dir:rw"' "$root/.github/workflows/build.yml" \
    || fail 'clean-chroot does not scope writable cgroup access to the current job'
grep -Fq -- '[[ -z "$runner_cgroup" || "$runner_cgroup" == / ]]' "$root/.github/workflows/build.yml" \
    || fail 'clean-chroot does not reject an unsafe unscoped cgroup mount'
printf '%s\n' 'All build regression tests passed.'
