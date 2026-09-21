FROM docker.io/cachyos/cachyos-v3:latest

ARG CUDA_BUILDER=0

RUN sed -i '/^\[options\]$/a DisableSandboxNetwork' /etc/pacman.conf \
    && pacman-key --init \
    && pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com \
    && pacman-key --lsign-key F3B607488DB35A47 \
    && pacman-key --updatedb \
    && pacman-key --list-keys F3B607488DB35A47 | grep -q 'CachyOS' \
    && pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com \
    && pacman-key --lsign-key 3056513887B78AEB \
    && pacman -U --noconfirm \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
    && printf '%s\n' '[chaotic-aur]' 'Include = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf \
    && packages='aria2 base-devel curl gcc-objc git gnupg jq namcap shellcheck sudo' \
    && if [ "$CUDA_BUILDER" = 1 ]; then packages="$packages cuda gcc15"; fi \
    && pacman -Syu --needed --noconfirm $packages \
    && install -d /etc/makepkg.conf.d \
    && printf '%s\n' \
        "DLAGENTS=('file::/usr/bin/cp --no-preserve=mode,timestamps -f %u %o'" \
        "          'ftp::/usr/bin/aria2c -UWget -s16 -x16 %u -o %o --follow-metalink=mem'" \
        "          'http::/usr/bin/aria2c -UWget -s16 -x16 %u -o %o --follow-metalink=mem'" \
        "          'https::/usr/bin/aria2c -UWget -s16 -x16 %u -o %o --follow-metalink=mem'" \
        "          'rsync::/usr/bin/rsync --no-motd -z %u %o'" \
        "          'scp::/usr/bin/scp -C %u %o')" \
        > /etc/makepkg.conf.d/pkgbuild-aria2.conf \
    && useradd --create-home --shell /bin/bash builder \
    && printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder \
    && install -d -o builder -g builder /build /out /cache/sources \
    && git clone --depth 1 https://aur.archlinux.org/yay-bin.git /build/yay-bin \
    && chown -R builder:builder /build/yay-bin \
    && runuser -u builder -- bash -c 'cd /build/yay-bin && makepkg --noconfirm --cleanbuild --clean' \
    && pacman -U --noconfirm /build/yay-bin/yay-bin-*.pkg.tar.zst \
    && rm -rf /build/yay-bin

ENV PATH="/opt/cuda/bin:${PATH}"
ENV PKGBUILD_BUILDER_IMAGE=1
ENV PKGBUILD_CUDA_BUILDER=${CUDA_BUILDER}
