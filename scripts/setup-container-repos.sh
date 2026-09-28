#!/usr/bin/env bash
# Configure the third-party pacman repositories that the build container also
# uses, inside a throwaway container. Mirrors .github/builder/Dockerfile.
#
# Without this the maintenance and drift containers only know core/extra and
# the CachyOS repositories, so packages that come from chaotic-aur (openapv,
# for example) are invisible: the soname check then reports every library they
# provide as missing, and the version drift check silently skips them.
#
# Exits non-zero when chaotic-aur is not usable, so callers can decide whether
# to abort (a check whose provider set is incomplete produces false findings)
# or to continue with reduced coverage.

set -Eeuo pipefail
export LC_ALL=C

sed -i "/^\[options\]$/a DisableSandboxNetwork" /etc/pacman.conf

if ! grep -qx '\[chaotic-aur\]' /etc/pacman.conf; then
    pacman-key --init > /dev/null
    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com > /dev/null
    pacman-key --lsign-key F3B607488DB35A47 > /dev/null
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com > /dev/null
    pacman-key --lsign-key 3056513887B78AEB > /dev/null
    pacman -U --noconfirm \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' \
        > /dev/null
    printf '%s\n' '[chaotic-aur]' 'Include = /etc/pacman.d/chaotic-mirrorlist' \
        >> /etc/pacman.conf
fi

pacman -Sy --noconfirm > /dev/null

if [[ -z "$(pacman -Slq chaotic-aur 2>/dev/null | head -n 1)" ]]; then
    printf 'chaotic-aur is not usable\n' >&2
    exit 1
fi
