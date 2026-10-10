FROM docker.io/cachyos/cachyos-v3:latest

ARG CUDA_BUILDER=0
# Bumped by .github/builder/generation so every cache derived from the builder
# contents (pacman, sources, cargo, ccache) can be invalidated deliberately
# instead of relying on a hash of this file alone.
ARG BUILDER_GENERATION=dev
LABEL org.emoeem.builder.generation="${BUILDER_GENERATION}"
COPY config/emo-native-flags.conf /etc/makepkg.conf.d/90-emo-native.conf

RUN sed -i '/^\[options\]$/a DisableSandboxNetwork' /etc/pacman.conf \
    && sed -i '/^\[options\]$/a ParallelDownloads = 8' /etc/pacman.conf \
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
    # actionlint is here so tests/run-all.sh can lint the workflows inside the
    # same container that runs the rest of the suite.
    && packages='actionlint aria2 base-devel ccache curl core/gcc-objc devtools git gnupg jq namcap nvchecker shellcheck sudo' \
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
    # yay 固定到检过的提交；升级要在这里有意改 sha，而不是每次镜像构建
    # 随上游浮动。chaotic 的 keyring/mirrorlist 包同样在下载后先做 sha256
    # 校验（chaotic 发新 keyring 时 CI 会在这里失败提醒更新哈希）。
    && pacman -Sy --noconfirm curl \
    && curl -fsSL --retry 5 --retry-all-errors --max-time 300 \
        -o /tmp/chaotic-keyring.pkg.tar.zst \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    && curl -fsSL --retry 5 --retry-all-errors --max-time 300 \
        -o /tmp/chaotic-mirrorlist.pkg.tar.zst \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
    && printf '%s  /tmp/chaotic-keyring.pkg.tar.zst\n%s  /tmp/chaotic-mirrorlist.pkg.tar.zst\n' \
        1496d7505f192bd98691135f364ffe3b4d4541b27c1391ac41e8694f83dda20d \
        d05c0faa78ff99be4c001d4c65fbb02a68cc3198347857dc220b799b707ccebf \
        | sha256sum -c - \
    && pacman -U --noconfirm /tmp/chaotic-keyring.pkg.tar.zst /tmp/chaotic-mirrorlist.pkg.tar.zst \
    && git clone https://aur.archlinux.org/yay-bin.git /build/yay-bin \
    && git -C /build/yay-bin checkout --detach 13e0a4754d106a9252b7479bf1b370fbe454fc48 \
    && chown -R builder:builder /build/yay-bin \
    && runuser -u builder -- bash -c 'cd /build/yay-bin && makepkg --noconfirm --cleanbuild --clean' \
    && pacman -U --noconfirm /build/yay-bin/yay-bin-*.pkg.tar.zst \
    && rm -rf /build/yay-bin

ENV PATH="/opt/cuda/bin:${PATH}"
ENV PKGBUILD_BUILDER_IMAGE=1
ENV PKGBUILD_CUDA_BUILDER=${CUDA_BUILDER}
ENV BUILDER_GENERATION=${BUILDER_GENERATION}

# Preserve the image-owned repository configuration before build scripts
# add the per-job local repository to /etc/pacman.conf. Clean chroots always
# derive their baseline from this immutable image copy.
RUN install -m0644 /etc/pacman.conf /etc/pacman.conf.pkgbuild-base
