#!/usr/bin/env bash

set -Eeuo pipefail

readonly package_name="${PACKAGE_NAME:-}"
readonly workspace_dir="${WORKSPACE_DIR:-/workspace}"
readonly output_dir="${OUTPUT_DIR:-/out}"
readonly build_root="${BUILD_ROOT:-/build}"
readonly builder_home="/home/builder"

if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'PACKAGE_NAME is missing or invalid: %s\n' "$package_name" >&2
    exit 2
fi

readonly source_dir="${workspace_dir}/packages/${package_name}"
readonly package_dir="${build_root}/${package_name}"
readonly package_remote="${build_root}/${package_name}-origin.git"

make_jobs="${MAKE_JOBS:-2}"
if [[ ! "$make_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'MAKE_JOBS must be a positive integer, got: %s\n' "$make_jobs" >&2
    exit 2
fi

if [[ ! -f "${source_dir}/PKGBUILD" ]]; then
    printf 'PKGBUILD not found at %s\n' "$source_dir" >&2
    exit 2
fi

printf 'Building %s with %s parallel job(s).\n' "$package_name" "$make_jobs"

"${workspace_dir}/scripts/setup-build-repositories.sh"
pacman -Syu --needed --noconfirm git gnupg sudo curl

useradd --create-home --shell /bin/bash builder
printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

install -d -o builder -g builder "$build_root" "$output_dir"
cp -a "$source_dir" "$package_dir"
chown -R builder:builder "$package_dir"

# Debug subpackages substantially increase build time and repository storage.
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
    )

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
    as_builder bash -c \
        "cd '$package_dir' && makepkg --verifysource --noconfirm"
fi

printf 'Bootstrapping yay-bin...\n'
git clone --depth 1 https://aur.archlinux.org/yay-bin.git \
    "${build_root}/yay-bin"
chown -R builder:builder "${build_root}/yay-bin"
as_builder bash -c \
    "cd '${build_root}/yay-bin' && makepkg --noconfirm --cleanbuild --clean"
pacman -U --noconfirm "${build_root}"/yay-bin/yay-bin-*.pkg.tar.zst

if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    yay --version
    printf 'Container bootstrap validation completed.\n'
    exit 0
fi

printf 'Resolving dependencies, building and installing %s...\n' "$package_name"
if ! as_builder yay -Bi "$package_dir" \
    --noconfirm \
    --needed \
    --pgpfetch \
    --noremovemake \
    --sudoloop \
    --answerclean None \
    --answerdiff None \
    --answeredit None \
    --answerupgrade None \
    --mflags "--cleanbuild --clean --noconfirm"; then
    while IFS= read -r log_file; do
        printf '\nFailure details from %s:\n' "$log_file" >&2
        tail -n 200 "$log_file" >&2 || true
    done < <(
        find "$package_dir" -type f -path '*/ffbuild/config.log' | sort
    )
    exit 1
fi

mapfile -d '' package_files < <(
    find "$package_dir" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' \
        -print0 |
        sort -z
)

if (( ${#package_files[@]} == 0 )); then
    printf 'No package files were produced for %s.\n' "$package_name" >&2
    exit 1
fi

for package_file in "${package_files[@]}"; do
    filename="$(basename "$package_file")"
    cp "$package_file" "$output_dir/"
    bsdtar -xOf "$package_file" .PKGINFO > "${output_dir}/${filename}.PKGINFO"
    bsdtar -xOf "$package_file" .BUILDINFO > "${output_dir}/${filename}.BUILDINFO"
done

cp "${source_dir}/PKGBUILD" "$output_dir/PKGBUILD.used"
cp "${source_dir}/.SRCINFO" "$output_dir/SRCINFO.used"
cp "${workspace_dir}/scripts/install-built-package.sh" "$output_dir/"

(
    cd "$output_dir"
    sha256sum ./*.pkg.tar.zst > SHA256SUMS
)

printf 'Built package files:\n'
ls -lh "$output_dir"/*.pkg.tar.zst
