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

if [[ ! -f "${source_dir}/PKGBUILD" ]]; then
    printf 'PKGBUILD not found at %s\n' "$source_dir" >&2
    exit 2
fi

printf 'Building %s with %s parallel job(s).\n' "$package_name" "$make_jobs"
if [[ "$prepared_image" == "1" ]]; then
    mkdir -p "$pacman_cache_dir" "$source_cache_dir" \
        "$cargo_cache_dir/registry" "$cargo_cache_dir/git" "$cargo_cache_dir/bin" \
        "$cache_dir/yay/$package_name"
    # The GitHub Actions cache is restored from a host-owned volume. Make the
    # complete cache path traversable and writable by the unprivileged builder
    # before yay/Go tries to create per-package cache directories.
    chmod u+rwx,go+rx "$cache_dir"
    chown -R builder:builder "$source_cache_dir" "$cargo_cache_dir" "$cache_dir/yay"
    sed -i "/^CacheDir = /d" /etc/pacman.conf
    sed -i "/^\[options\]$/a CacheDir = $pacman_cache_dir" /etc/pacman.conf
fi

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
    pacman -Syu --needed --noconfirm aria2 base-devel git gnupg sudo curl jq namcap
fi

if ! id builder >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash builder
    printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
fi

install -d -o builder -g builder "$build_root" "$output_dir"
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
    )

    if [[ "$prepared_image" == "1" ]]; then
        environment+=("XDG_CACHE_HOME=${cache_dir}/yay/${package_name}" "CARGO_HOME=${cargo_cache_dir}")
    fi

    if [[ "$package_name" == "ffmpeg-full" ]]; then
        environment+=(
            "CUDA_PATH=/opt/cuda"
            "NVCC_CCBIN=/usr/bin/g++-15"
            "PATH=/opt/cuda/bin:${PATH}"
        )
    fi

    runuser -u builder -- \
        env "${environment[@]}" "$@"
}

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

if [[ "$package_name" == "ffmpeg-full" ]]; then
    readonly ffmpeg_signing_key="FCF986EA15E6E293A5644F10B4322F04D67658D8"
    curl --fail --silent --show-error --location \
        --connect-timeout 30 \
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
pacman -Sy --noconfirm
pacman -Sc --noconfirm

if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    printf 'Container bootstrap validation completed.\n'
    exit 0
fi

printf 'Resolving dependencies, building and installing %s...\n' "$package_name"
yay_status=0
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
    --mflags "--cleanbuild --clean --noconfirm" ||
    yay_status=$?

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
    printf \
        'yay exited with status %d after producing the target package; continuing without installing it.\n' \
        "$yay_status"
fi

for package_file in "${package_files[@]}"; do
    filename="$(basename "$package_file")"
    printf 'Running namcap on %s...\n' "$filename"
    bash "${workspace_dir}/scripts/run-namcap.sh" "$package_file"
    cp "$package_file" "$output_dir/"
    bsdtar -xOf "$package_file" .PKGINFO > "${output_dir}/${filename}.PKGINFO"
    bsdtar -xOf "$package_file" .BUILDINFO > "${output_dir}/${filename}.BUILDINFO"
done

printf "Running installed-package runtime smoke test...
"
while IFS= read -r package_name_from_info; do
    [[ -n "$package_name_from_info" ]] || continue
    bash "${workspace_dir}/scripts/runtime-smoke-test.sh" "$package_name_from_info"
done < <(
    for package_file in "${package_files[@]}"; do
        bsdtar -xOf "$package_file" .PKGINFO | awk -F" = " '$1 == "pkgname" {print $2; exit}'
    done | sort -u
)

cp "${source_dir}/PKGBUILD" "$output_dir/PKGBUILD.used"
cp "${source_dir}/.SRCINFO" "$output_dir/SRCINFO.used"
cp "${workspace_dir}/scripts/install-built-package.sh" "$output_dir/"

(
    cd "$output_dir"
    sha256sum ./*.pkg.tar.zst > SHA256SUMS
)

printf 'Built package files:\n'
ls -lh "$output_dir"/*.pkg.tar.zst
