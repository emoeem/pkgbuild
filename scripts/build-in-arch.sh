#!/usr/bin/env bash

set -Eeuo pipefail

readonly package_name="ffmpeg-full"
readonly workspace_dir="${WORKSPACE_DIR:-/workspace}"
readonly source_dir="${workspace_dir}/packages/${package_name}"
readonly output_dir="${OUTPUT_DIR:-/out}"
readonly build_root="${BUILD_ROOT:-/build}"
readonly package_dir="${build_root}/${package_name}"
readonly package_remote="${build_root}/${package_name}-origin.git"
readonly builder_home="/home/builder"
readonly ffmpeg_signing_key="FCF986EA15E6E293A5644F10B4322F04D67658D8"
readonly chaotic_key_fingerprint="EF925EA60F33D0CB85C44AD13056513887B78AEB"
readonly chaotic_keyserver="hkps://keyserver.ubuntu.com"
readonly chaotic_base_url="https://cdn-mirror.chaotic.cx/chaotic-aur"

make_jobs="${MAKE_JOBS:-2}"
if [[ ! "$make_jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'MAKE_JOBS must be a positive integer, got: %s\n' "$make_jobs" >&2
    exit 2
fi

if [[ ! -f "${source_dir}/PKGBUILD" ]]; then
    printf 'PKGBUILD not found at %s\n' "$source_dir" >&2
    exit 2
fi

printf 'Using %s parallel build job(s).\n' "$make_jobs"

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinux

printf 'Enabling Chaotic-AUR for prebuilt AUR dependencies...\n'
chaotic_key_received=0
for attempt in 1 2 3 4 5; do
    if pacman-key --recv-key "$chaotic_key_fingerprint" \
        --keyserver "$chaotic_keyserver"; then
        chaotic_key_received=1
        break
    fi
    printf 'Chaotic-AUR key download failed (attempt %d/5); retrying...\n' \
        "$attempt" >&2
    sleep $((attempt * 5))
done

if (( chaotic_key_received == 0 )); then
    printf 'Unable to retrieve the Chaotic-AUR signing key.\n' >&2
    exit 1
fi

pacman-key --lsign-key "$chaotic_key_fingerprint"
pacman -U --noconfirm \
    "${chaotic_base_url}/chaotic-keyring.pkg.tar.zst" \
    "${chaotic_base_url}/chaotic-mirrorlist.pkg.tar.zst"
cat >> /etc/pacman.conf <<'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF

pacman -Syu --needed --noconfirm git gnupg sudo curl

useradd --create-home --shell /bin/bash builder
printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

install -d -o builder -g builder "$build_root" "$output_dir"
cp -a "$source_dir" "$package_dir"
chown -R builder:builder "$package_dir"

# Arch enables debug packages by default. They are not needed for this personal
# binary artifact and substantially increase build time and artifact storage.
sed -Ei \
    's/(^OPTIONS=.*[[:space:]])debug([[:space:]\)])/\1!debug\2/' \
    /etc/makepkg.conf

as_builder() {
    runuser -u builder -- \
        env HOME="$builder_home" MAKEFLAGS="-j${make_jobs}" "$@"
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

printf 'Importing the official FFmpeg release signing key...\n'
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
    printf 'The downloaded FFmpeg key did not contain fingerprint %s\n' \
        "$ffmpeg_signing_key" >&2
    exit 1
fi
as_builder gpg --batch --import /tmp/ffmpeg-devel.asc

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

printf 'Resolving repository and AUR dependencies, then building %s...\n' \
    "$package_name"
as_builder yay -B "$package_dir" \
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

mapfile -d '' package_files < <(
    find "$package_dir" -maxdepth 1 -type f \
        -name "${package_name}-[0-9]*-x86_64.pkg.tar.zst" \
        -print0
)

if (( ${#package_files[@]} != 1 )); then
    printf 'Expected exactly one %s package, found %d.\n' \
        "$package_name" "${#package_files[@]}" >&2
    find "$package_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print >&2
    exit 1
fi

package_file="${package_files[0]}"
cp "$package_file" "$output_dir/"
cp "${source_dir}/PKGBUILD" "$output_dir/PKGBUILD.used"
cp "${source_dir}/.SRCINFO" "$output_dir/SRCINFO.used"
cp "${workspace_dir}/scripts/install-built-package.sh" "$output_dir/"

output_package="${output_dir}/$(basename "$package_file")"
bsdtar -xOf "$output_package" .PKGINFO > "${output_dir}/PKGINFO"
bsdtar -xOf "$output_package" .BUILDINFO > "${output_dir}/BUILDINFO"

(
    cd "$output_dir"
    sha256sum "$(basename "$output_package")" > SHA256SUMS
)

printf 'Built package:\n'
ls -lh "$output_package"
