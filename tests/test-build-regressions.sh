#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

printf '%s\n' '1/3: verify Linux mpv builds explicitly disable Win32 threads'
for package in mpv-emo mpv-emo-git; do
    grep -Fq -- '-Dwin32-threads=disabled' "$root/packages/$package/PKGBUILD" \
        || fail "$package does not explicitly disable win32-threads"
    grep -Fq -- '--auto-features=auto' "$root/packages/$package/PKGBUILD" \
        || fail "$package does not preserve platform-aware Meson auto feature detection"
done

printf '%s\n' '2/3: verify the development patch series applies to its pinned upstream commit'
commit="$(sed -n "s/.*#commit=\([0-9a-f]\{40\}\)'.*/\1/p" "$root/packages/mpv-emo-git/PKGBUILD")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail 'unable to read mpv-emo-git commit pin'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone -q --filter=blob:none --no-checkout https://github.com/mpv-player/mpv.git "$work/mpv"
git -C "$work/mpv" fetch -q origin "$commit"
git -C "$work/mpv" checkout -q --detach "$commit"
cd "$work/mpv"
for patch_file in "$root"/packages/mpv-emo-git/patches/*.patch; do
    patch -Np1 < "$patch_file" >/dev/null \
        || fail "development patch does not apply: $(basename "$patch_file")"
done

git clone -q --filter=blob:none --branch v0.41.0 https://github.com/mpv-player/mpv.git "$work/mpv-stable"
cd "$work/mpv-stable"
for patch_file in "$root"/packages/mpv-emo/patches/*.patch; do
    patch -Np1 < "$patch_file" >/dev/null \
        || fail "stable patch does not apply: $(basename "$patch_file")"
done

printf '%s\n' '3/4: verify Git source-cache collision is removed while matching cache survives'
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

printf '%s\n' '4/4: verify CUDA builder supplies the nvcc host compiler required by ffmpeg-full'
grep -Fq -- 'packages="$packages cuda gcc15"' "$root/.github/builder/Dockerfile" \
    || fail 'CUDA builder does not install gcc15 for nvcc'
grep -Fq -- "'cuda'" "$root/packages/ffmpeg-full/PKGBUILD" \
    || fail 'ffmpeg-full does not declare CUDA build dependency'
grep -Fq -- 'NVCC_CCBIN=/usr/bin/g++-15' "$root/scripts/build-in-arch.sh" \
    || fail 'ffmpeg-full builder path does not pin nvcc to GCC 15'

printf '%s\n' 'All build regression tests passed.'
