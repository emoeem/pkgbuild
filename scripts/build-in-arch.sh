#!/usr/bin/env bash

set -Eeuo pipefail

readonly package_name="${PACKAGE_NAME:-}"
readonly workspace_dir="${WORKSPACE_DIR:-/workspace}"
readonly output_dir="${OUTPUT_DIR:-/out}"
readonly build_root="${BUILD_ROOT:-/build}"
readonly builder_home="/home/builder"
readonly cache_dir="${CACHE_DIR:-/cache}"
readonly pacman_cache_dir="${cache_dir}/pacman"
readonly source_cache_dir="${cache_dir}/sources/${package_name}"
readonly cargo_cache_dir="${cache_dir}/cargo"
readonly prepared_image="${PKGBUILD_BUILDER_IMAGE:-0}"
readonly native_profile="${NATIVE_PROFILE:-${workspace_dir}/config/emo-native-flags.sh}"

if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'PACKAGE_NAME is missing or invalid: %s\n' "$package_name" >&2
    exit 2
fi

readonly source_dir="${workspace_dir}/packages/${package_name}"
readonly package_dir="${build_root}/${package_name}"
readonly package_remote="${build_root}/${package_name}-origin.git"

make_jobs="${MAKE_JOBS:-$(nproc)}"
if [[ ! "$make_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'MAKE_JOBS must be a positive integer, got: %s\n' "$make_jobs" >&2
    exit 2
fi

if [[ ! -f "${native_profile}" ]]; then
    printf 'Performance profile not found at %s\n' "$native_profile" >&2
    exit 2
fi

if [[ ! -f "${source_dir}/PKGBUILD" ]]; then
    printf 'PKGBUILD not found at %s\n' "$source_dir" >&2
    exit 2
fi

printf 'Building %s with %s parallel job(s).\n' "$package_name" "$make_jobs"
if [[ "$prepared_image" == "1" ]]; then
    mkdir -p "$pacman_cache_dir" "$source_cache_dir" \
        "$cargo_cache_dir/registry" "$cargo_cache_dir/git" "$cargo_cache_dir/bin" \
        "$cache_dir/yay/$package_name" "$cache_dir/ccache"
    # The GitHub Actions cache is restored from a host-owned volume. Make the
    # complete cache path traversable and writable by the unprivileged builder
    # before yay/Go tries to create per-package cache directories.
    chmod u+rwx,go+rx "$cache_dir"
    chmod -R a+rwX "$source_cache_dir" "$cargo_cache_dir" "$cache_dir/yay" "$cache_dir/ccache"
    sed -i "/^CacheDir = /d" /etc/pacman.conf
    sed -i "/^\[options\]$/a CacheDir = $pacman_cache_dir" /etc/pacman.conf
fi

if [[ "$prepared_image" == "1" ]]; then
    # Preserve the builder image's original pacman configuration before the
    # disposable outer container adds its downloaded-package repository.
    cp /etc/pacman.conf /tmp/pkgbuild-builder-pacman.conf
    export BUILDER_PACMAN_CONF=/tmp/pkgbuild-builder-pacman.conf
fi
bash "$workspace_dir/scripts/configure-build-repo.sh"

if [[ "$prepared_image" != "1" ]]; then
    if ! grep -q '^ID=cachyos$' /etc/os-release; then
        printf 'Local builds must run on CachyOS; use the CachyOS-v3 builder image for other hosts.\n' >&2
        exit 2
    fi
    if ! pacman-conf --repo-list | grep -Fxq cachyos-v3; then
        printf 'CachyOS v3 repository is not enabled on this host.\n' >&2
        exit 2
    fi
    printf 'Using native CachyOS build environment.\n'
    pacman -Syu --needed --noconfirm aria2 base-devel gcc-objc git gnupg sudo curl jq namcap
fi

if ! id builder >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash builder
    printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
fi

# The shared yay cache is restored by the GitHub runner and can be owned by
# root. yay consumes it as builder, so align ownership and configure Git for
# the exact HOME used by as_builder(). This avoids dubious-ownership failures
# without requiring a cache-key reset.
if [[ "$prepared_image" == "1" ]]; then
    chown -R builder:builder "$cache_dir/yay/$package_name"
    runuser -u builder -- env HOME="$builder_home" \
        git config --global --add safe.directory '*'
fi

install -d -o builder -g builder "$build_root" "$output_dir"

# shellcheck source=scripts/lib/timing.sh
source "${workspace_dir}/scripts/lib/timing.sh"
readonly phase_file="${output_dir}/timings.phases.jsonl"
readonly build_log="${output_dir}/build.log"
readonly stamper="${workspace_dir}/scripts/build-timing.py"
timing_init "$phase_file"

# Runs on every exit path (success, build failure, argument error) so a failed
# package still ships a timings record and the failure analyzer has a log.
emit_build_timings() {
    local exit_code=$?
    trap - EXIT
    timing_total

    local package_bytes=0 status="success"
    if [[ -f "${output_dir}/SHA256SUMS" ]]; then
        # || true: this runs from an EXIT trap, so a failing command must never
        # abort the handler before the timings record is written.
        package_bytes="$(du -sb --total "${output_dir}"/*.pkg.tar.zst 2>/dev/null |
            awk 'END { print $1 }' || true)"
    fi
    (( exit_code == 0 )) || status="failed"
    timing_resources "${output_dir}/resources.txt" "$package_dir" \
        "$source_cache_dir" "${package_bytes:-0}"

    if command -v python3 >/dev/null 2>&1; then
        python3 "$stamper" collect \
            --package "$package_name" \
            --pkgver "$(awk -F= '/^pkgver=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$package_dir/PKGBUILD" 2>/dev/null || true)" \
            --log "$build_log" \
            --phases "$phase_file" \
            --ccache "${output_dir}/ccache-stats.txt" \
            --resources "${output_dir}/resources.txt" \
            --status "$status" \
            --out "${output_dir}/timings.json" >/dev/null || true
    fi

    exit "$exit_code"
}
trap emit_build_timings EXIT

timing_begin prepare
rm -rf "$package_dir" "$package_remote"
cp -a "$source_dir" "$package_dir"
chown -R builder:builder "$package_dir"

sed -Ei \
    's/(^OPTIONS=.*[[:space:]])debug([[:space:]\)])/\1!debug\2/' \
    /etc/makepkg.conf
sed -Ei \
    "/'https?::/ s/--retry 3 --retry-delay 3/--retry 10 --retry-all-errors --retry-delay 5 --connect-timeout 30/" \
    /etc/makepkg.conf

as_builder() {
    local -a environment=(
        "HOME=${builder_home}"
        "MAKEFLAGS=-j${make_jobs}"
        "BUMP_PKGREL=${BUMP_PKGREL:-false}"
        "CFLAGS=${EMO_CFLAGS}"
        "CXXFLAGS=${EMO_CXXFLAGS}"
        "LDFLAGS=${EMO_LDFLAGS}"
        "RUSTFLAGS=${EMO_RUSTFLAGS}"
        "CMAKE_BUILD_PARALLEL_LEVEL=${make_jobs}"
        "NINJAFLAGS=-j${make_jobs}"
        "SRCDEST=${source_cache_dir}"
        "PATH=/usr/lib/ccache/bin:${PATH}"
        "CCACHE_DIR=${cache_dir}/ccache"
        "CCACHE_MAXSIZE=2G"
    )

    if [[ "$prepared_image" == "1" ]]; then
        environment+=("XDG_CACHE_HOME=${cache_dir}/yay/${package_name}" "CARGO_HOME=${cargo_cache_dir}")
    fi

    if [[ "$package_name" == "ffmpeg-full" ]]; then
        environment+=(
            "CUDA_PATH=/opt/cuda"
            "NVCC_CCBIN=/usr/bin/g++-15"
            "PATH=/usr/lib/ccache/bin:/opt/cuda/bin:${PATH}"
        )
    fi

    runuser -u builder -- \
        env "${environment[@]}" "$@"
}

# shellcheck disable=SC1090
source "$native_profile"

as_builder bash "$workspace_dir/scripts/prepare-build-source.sh" "$package_dir"

printf 'Creating an isolated package source snapshot...\n'
as_builder git init --bare --initial-branch=main "$package_remote"
as_builder git -C "$package_dir" init --initial-branch=main
as_builder git -C "$package_dir" add --all
as_builder git -C "$package_dir" \
    -c user.name='GitHub Actions' \
    -c user.email='actions@users.noreply.github.com' \
    commit --message='Build source snapshot'
as_builder git -C "$package_dir" remote add origin "$package_remote"
as_builder git -C "$package_dir" push --set-upstream origin main

printf 'Checking that .SRCINFO matches PKGBUILD...\n'
as_builder bash -c \
    "cd '$package_dir' && makepkg --printsrcinfo > /tmp/SRCINFO.generated"
diff -u "${package_dir}/.SRCINFO" /tmp/SRCINFO.generated
printf 'Running namcap on PKGBUILD...\n'
bash "${workspace_dir}/scripts/run-namcap.sh" "${package_dir}/PKGBUILD"

printf 'Validating Git source cache entries...\n'
bash "${workspace_dir}/scripts/validate-source-cache.sh" "${package_dir}" "${source_cache_dir}"

timing_end prepare
timing_begin sources

if [[ "$package_name" == "ffmpeg-full" ]]; then
    readonly ffmpeg_signing_key="FCF986EA15E6E293A5644F10B4322F04D67658D8"
    curl --fail --silent --show-error --location \
        --connect-timeout 30 \
        --max-time 300 \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 5 \
        https://ffmpeg.org/ffmpeg-devel.asc \
        --output /tmp/ffmpeg-devel.asc

    if ! gpg --batch --with-colons --import-options show-only \
        --import /tmp/ffmpeg-devel.asc |
        awk -F: '$1 == "fpr" { print $10 }' |
        grep -Fxq "$ffmpeg_signing_key"; then
        printf 'The downloaded FFmpeg key has an unexpected fingerprint.\n' >&2
        exit 1
    fi
    as_builder gpg --batch --import /tmp/ffmpeg-devel.asc

    printf 'Downloading and verifying FFmpeg sources...\n'
    as_builder env SRCDEST="$source_cache_dir" bash -c \
        "cd '$package_dir' && makepkg --verifysource --noconfirm"
fi

timing_end sources

if [[ "$prepared_image" != "1" ]]; then
    printf 'Bootstrapping yay-bin...\n'
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git \
        "${build_root}/yay-bin"
    chown -R builder:builder "${build_root}/yay-bin"
    as_builder bash -c \
        "cd '${build_root}/yay-bin' && makepkg --noconfirm --cleanbuild --clean"
    bsdtar -xf "${build_root}"/yay-bin/yay-bin-*.pkg.tar.zst -C /
fi

yay --version
printf "Refreshing package databases and pruning stale binary caches...\n"
pacman -Syu --noconfirm
bash "$workspace_dir/scripts/validate-build-policy.sh"
pacman -Sc --noconfirm

if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    printf 'Container bootstrap validation completed.\n'
    exit 0
fi

printf 'Resolving dependencies, building and installing %s...\n' "$package_name"
# 给安装类 pacman 调用注入 --ask=4:yay 的依赖事务可能把与本包冲突的仓库包
# 一并装进来(scx-scheds-git 的依赖树里带着 extra/scx-scheds,125 MiB,实测
# 2026-10-11),makepkg --install 收尾的 pacman -U 撞冲突时 --noconfirm 对
# "Remove ...?" 的默认答案是 N,整次安装中止。devtools 在 chroot 里同样用
# --ask=4 处理 install_pkgs;一次性容器里自动移除是安全语义。
pacman_shim_dir="$(mktemp -d /tmp/pkgbuild-pacman-shim.XXXXXX)"
cat > "$pacman_shim_dir/pacman" <<'__PACMAN_SHIM__'
#!/usr/bin/env bash
case "${1:-}" in
    -S*|-U*|-R*) exec /usr/bin/pacman --ask=4 "$@" ;;
    *)           exec /usr/bin/pacman "$@" ;;
esac
__PACMAN_SHIM__
chmod 0755 "$pacman_shim_dir/pacman"
PATH="$pacman_shim_dir:$PATH"
if [[ "$package_name" == "ffmpeg-full" ]]; then
    # Resolve virtual/provider dependencies non-interactively and pin them to
    # the same concrete packages selected by this local CachyOS-v3 profile.
    pacman -S --needed --noconfirm \
        sdl2-compat libglvnd l-smash onetbb tevent \
        tesseract-data-eng tesseract-data-osd
fi
# PKGBUILD 声明的 conflicts 若已被镜像提供(基础镜像随上游滚动更新,例如
# ffmpeg 2:9.0.2 进入基础包集),yay -Bi 收尾的 pacman -U 会撞冲突事务:
# --noconfirm 对 "Remove ...? [y/N]" 的默认答案是 N,整次安装中止、
# 包构建成功却发布不出去。声明冲突即宣告替代,提前移除(一次性容器,
# -Rdd 不必顾及其依赖方)。
mapfile -t declared_conflicts < <(
    awk -F ' = ' '{sub(/^[ \t]+/, "", $1)} $1 == "conflicts" {print $2}' \
        "$package_dir/.SRCINFO" 2>/dev/null |
        sed 's/[<>=].*//'
)
for conflict in "${declared_conflicts[@]}"; do
    if pacman -Qi -- "$conflict" >/dev/null 2>&1; then
        printf 'Removing %s: declared in conflicts=, provided by the base image.\n' "$conflict"
        pacman -Rdd --noconfirm -- "$conflict"
    fi
done
run_build() {
    if [[ "$prepared_image" == "1" && "${CLEAN_CHROOT_BUILD:-1}" == "1" ]]; then
        bash "$workspace_dir/scripts/build-in-clean-chroot.sh" "$package_dir" "$output_dir"
        return $?
    fi
    as_builder yay -Bi "$package_dir" \
        --noconfirm \
        --needed \
        --pgpfetch \
        --noremovemake \
        --sudoloop \
        --answerclean None \
        --answerdiff None \
        --answeredit None \
        --answerupgrade None \
        --mflags "--cleanbuild --clean --noconfirm"
}

# ccache counters are zeroed so the recorded hit rate describes this build
# only. Every CI build job owns its restored cache volume, so this does not
# disturb other packages.
# README 的依赖优先级把仓库源都满足不了的依赖交给 yay 从 AUR 构建安装。这条
# 规则必须对依赖的依赖同样成立（见 find-uninstallable-dependencies.sh 的说明）：
# 仓库里有同名包、但依赖闭包装不上的依赖，要先把真正缺的那个名字从 AUR 装好，
# 否则 pacman 会直接 "could not satisfy dependencies"，目标包连编译都不会开始
# （run 38025497233：yay -S --aur 仍会把仓库里的同名副本当成满足条件，只有把缺件
# 本体装进容器才能让仓库副本变得可安装；触发那个 run 的桩包此后已退役，但规则对
# 任何此类依赖仍然成立）。
# 装好一轮后重新探测，覆盖"缺件本身也依赖缺件"的链条；最多三轮。这段必须在
# timing_begin build 之前跑完：从 AUR 补装依赖属于准备阶段，不是这个包的编译。
for _ in 1 2 3; do
    mapfile -t aur_dependencies < <(
        bash "$workspace_dir/scripts/find-uninstallable-dependencies.sh" \
            "$package_dir/.SRCINFO"
    )
    if (( ${#aur_dependencies[@]} == 0 )); then
        break
    fi
    printf 'Installing %s from the AUR because the repositories cannot satisfy the dependency closure.\n' \
        "${aur_dependencies[*]}"
    if ! as_builder yay -S --needed --asdeps --noconfirm \
        "${aur_dependencies[@]}"; then
        printf \
            'WARNING: could not install %s from the AUR; the build will report the original dependency error.\n' \
            "${aur_dependencies[*]}" >&2
        break
    fi
done

if command -v ccache >/dev/null 2>&1; then
    ccache --zero-stats >/dev/null 2>&1 || true
fi

timing_begin build
yay_status=0
if command -v python3 >/dev/null 2>&1; then
    # Stamp every line with a wall clock timestamp so makepkg's phase banners
    # ("==> Starting build()...") become a measured download/compile/package
    # breakdown instead of a guess.
    run_build 2>&1 | python3 "$stamper" stamp --log "$build_log" ||
        yay_status="${PIPESTATUS[0]}"
else
    run_build || yay_status=$?
fi
timing_end build "$([[ "$yay_status" == "0" ]] && echo ok || echo failed)"

if command -v ccache >/dev/null 2>&1; then
    ccache -s >"${output_dir}/ccache-stats.txt" 2>&1 || true
fi

mapfile -d '' package_files < <(
    find "$package_dir" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' \
        -print0 |
        sort -z
)

if (( ${#package_files[@]} == 0 )); then
    while IFS= read -r log_file; do
        printf '\nFailure details from %s:\n' "$log_file" >&2
        tail -n 200 "$log_file" >&2 || true
    done < <(
        find "$package_dir" -type f -path '*/ffbuild/config.log' | sort
    )
    printf 'No package files were produced for %s.\n' "$package_name" >&2
    if (( yay_status == 0 )); then
        yay_status=1
    fi
    exit "$yay_status"
fi

if (( yay_status != 0 )); then
    printf 'yay exited with status %d after producing package files; verification continues on the produced artifacts.\n' "$yay_status" >&2
fi

timing_begin verify
for package_file in "${package_files[@]}"; do
    filename="$(basename "$package_file")"
    printf 'Running namcap on %s...\n' "$filename"
    bash "${workspace_dir}/scripts/run-namcap.sh" "$package_file" 2>&1 | tee -a "${output_dir}/namcap.txt"
    cp "$package_file" "$output_dir/"
    bsdtar -xOf "$package_file" .PKGINFO > "${output_dir}/${filename}.PKGINFO"
    bsdtar -xOf "$package_file" .BUILDINFO > "${output_dir}/${filename}.BUILDINFO"
    bash "${workspace_dir}/scripts/verify-build-dependencies.sh" "${output_dir}/${filename}.BUILDINFO"
done

timing_end verify
timing_begin smoke
printf 'Running installed-package runtime verification...\n'
while IFS= read -r package_name_from_info; do
    [[ -n "$package_name_from_info" ]] || continue
    # Resolves shared libraries, checks SONAMEs/symlinks/permissions against
    # pacman's own file database, and runs the declared smoke commands.
    bash "${workspace_dir}/scripts/runtime-verify.sh" \
        --package "$package_name_from_info" \
        --json-out "${output_dir}/${package_name_from_info}.runtime.json"
done < <(
    for package_file in "${package_files[@]}"; do
        bsdtar -xOf "$package_file" .PKGINFO | awk -F" = " '$1 == "pkgname" {print $2; exit}'
    done | sort -u
)

timing_end smoke
cp "${source_dir}/PKGBUILD" "$output_dir/PKGBUILD.used"
cp "${source_dir}/.SRCINFO" "$output_dir/SRCINFO.used"
cp "${workspace_dir}/scripts/install-built-package.sh" "$output_dir/"

(
    cd "$output_dir"
    sha256sum ./*.pkg.tar.zst > SHA256SUMS
)

printf 'Built package files:\n'
ls -lh "$output_dir"/*.pkg.tar.zst
