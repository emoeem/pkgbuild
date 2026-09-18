FROM docker.io/library/archlinux:base-devel

COPY scripts/setup-build-repositories.sh /usr/local/lib/pkgbuild/setup-build-repositories.sh

RUN /usr/local/lib/pkgbuild/setup-build-repositories.sh \
    && pacman -Syu --needed --noconfirm \
        curl git gnupg jq namcap sudo \
    && useradd --create-home --shell /bin/bash builder \
    && printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder \
    && install -d -o builder -g builder /build /out \
    && git clone --depth 1 https://aur.archlinux.org/yay-bin.git /build/yay-bin \
    && chown -R builder:builder /build/yay-bin \
    && runuser -u builder -- bash -c 'cd /build/yay-bin && makepkg --noconfirm --cleanbuild --clean' \
    && bsdtar -xf /build/yay-bin/yay-bin-*.pkg.tar.zst -C / \
    && rm -rf /build/yay-bin /var/cache/pacman/pkg/*

ENV PATH="/opt/cuda/bin:${PATH}"
ENV PKGBUILD_BUILDER_IMAGE=1
