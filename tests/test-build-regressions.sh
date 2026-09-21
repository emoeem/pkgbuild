#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s\n' '1/3: verify Git source-cache collision is removed while matching cache survives'
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

printf '%s\n' '2/3: verify CUDA builder supplies the nvcc host compiler required by ffmpeg-full'
grep -Fq -- 'packages="$packages cuda gcc15"' "$root/.github/builder/Dockerfile" \
    || fail 'CUDA builder does not install gcc15 for nvcc'
grep -Fq -- "'cuda'" "$root/packages/ffmpeg-full/PKGBUILD" \
    || fail 'ffmpeg-full does not declare CUDA build dependency'
grep -Fq -- 'NVCC_CCBIN=/usr/bin/g++-15' "$root/scripts/build-in-arch.sh" \
    || fail 'ffmpeg-full builder path does not pin nvcc to GCC 15'
printf '%s\n' '3/3: verify local Zen 3 performance profile and RTX 4050 CUDA target'
grep -Fq -- '-march=znver3 -mtune=znver3 -O3' "$root/config/emo-native-flags.conf" || fail 'local Zen 3 profile missing'
grep -Fq -- '-march=znver3 -mtune=znver3 -O3' "$root/packages/ffmpeg-full/PKGBUILD" || fail 'ffmpeg-full does not use Zen 3 profile'
grep -Fq -- '--enable-lto=full' "$root/packages/ffmpeg-full/PKGBUILD" || fail 'ffmpeg-full LTO missing'
grep -Fq -- '-DCMAKE_CUDA_ARCHITECTURES=89' "$root/packages/ggml-cuda-git/PKGBUILD" || fail 'CUDA 89 target missing'
grep -Fq -- 'objective-c -c' "$root/tests/test-cachyos-environment.sh" || fail 'Objective-C preflight missing'
printf '%s\n' 'All build regression tests passed.'
