#!/usr/bin/env bash
# Configure the third-party pacman repositories that the build container also
# uses, inside a throwaway container. Mirrors .github/builder/Dockerfile.
#
# Without this the maintenance and drift containers only know core/extra and
# the CachyOS repositories, so packages that come from chaotic-aur (openapv,
# for example) are invisible: the soname check then reports every library they
# provide as missing, and the version drift check silently skips them.
#
# The chaotic CDN occasionally answers 503, so both the keyring installation and
# the database sync are retried. When the keyring route keeps failing the
# repository is added unsigned but restricted to metadata queries
# (`Usage = Sync Search`), which is all these checks need: they never install a
# package from it.
#
# Exits non-zero when chaotic-aur is not usable, so callers can decide whether
# to abort (a check whose provider set is incomplete produces false findings)
# or to continue with reduced coverage.

set -Eeuo pipefail
export LC_ALL=C

chaotic_mirror='https://cdn-mirror.chaotic.cx/chaotic-aur'

retry() {
    local attempt
    for attempt in 1 2 3 4; do
        if "$@"; then
            return 0
        fi
        printf 'attempt %s failed: %s\n' "$attempt" "$*" >&2
        sleep $((attempt * 5))
    done
    return 1
}

configure_keyring_repo() {
    pacman-key --init > /dev/null
    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com > /dev/null
    pacman-key --lsign-key F3B607488DB35A47 > /dev/null
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com > /dev/null
    pacman-key --lsign-key 3056513887B78AEB > /dev/null
    pacman -U --noconfirm \
        "${chaotic_mirror}/chaotic-keyring.pkg.tar.zst" \
        "${chaotic_mirror}/chaotic-mirrorlist.pkg.tar.zst" > /dev/null
    printf '%s\n' '[chaotic-aur]' 'Include = /etc/pacman.d/chaotic-mirrorlist' \
        >> /etc/pacman.conf
}

configure_unsigned_repo() {
    printf '%s\n' '[chaotic-aur]' 'SigLevel = Never' 'Usage = Sync Search' \
        "Server = ${chaotic_mirror}" >> /etc/pacman.conf
}

sed -i "/^\[options\]$/a DisableSandboxNetwork" /etc/pacman.conf

if ! grep -qx '\[chaotic-aur\]' /etc/pacman.conf; then
    if ! retry configure_keyring_repo; then
        printf '%s\n' \
            'keyring setup failed; falling back to an unsigned metadata-only chaotic-aur' >&2
        configure_unsigned_repo
    fi
fi

retry pacman -Sy --noconfirm > /dev/null || true

if [[ -z "$(pacman -Slq chaotic-aur 2>/dev/null | head -n 1)" ]]; then
    printf 'chaotic-aur is not usable\n' >&2
    exit 1
fi
