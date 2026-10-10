#!/usr/bin/env bash
# Configure the third-party pacman repositories that the build container also
# uses, inside a throwaway container. Mirrors .github/builder/Dockerfile, and
# works both from the CachyOS base image (nothing configured yet) and from the
# builder image itself (chaotic-aur is already configured there; that section is
# kept rather than appended a second time).
#
# Without this the maintenance and drift containers only know core/extra and
# the CachyOS repositories, so packages that come from chaotic-aur (openapv,
# for example) are invisible: the soname check then reports every library they
# provide as missing, and the version drift check silently skips them.
#
# Two routes, in order of preference:
#
#   1. the keyring route from the builder image (chaotic-keyring +
#      chaotic-mirrorlist, signature checking intact);
#   2. direct mirrors with `SigLevel = Never` and `Usage = Sync Search`, which
#      still allows the database and file-database syncs these checks need but
#      forbids installing anything from the repository.
#
# Both routes are attempted, and the second one is also used when the first
# route installs but its mirrors cannot be synced, because cdn-mirror.chaotic.cx
# regularly answers 503 for the keyring packages.
#
# Exits non-zero when chaotic-aur is not usable, so callers can decide whether
# to abort (a check whose provider set is incomplete produces false findings)
# or to continue with reduced coverage.

set -Eeuo pipefail
export LC_ALL=C

# Canonical chaotic-aur mirrors. The installed mirrorlist carries a longer,
# per-region list; these answered reliably and are enough for the keyring
# download as well as for the fallback.
chaotic_mirrors=(
    'https://geo-mirror.chaotic.cx/chaotic-aur'
    'https://cdn-mirror.chaotic.cx/chaotic-aur'
    'https://de-mirror.chaotic.cx/chaotic-aur'
    'https://br-mirror.chaotic.cx/chaotic-aur'
)

route=''

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

# Import the signing keys and install chaotic-keyring + chaotic-mirrorlist from
# the first mirror that serves them. Nothing is written to pacman.conf unless
# both packages are installed and the mirrorlist really exists: a partial
# download used to leave an unreadable `Include` behind, which made every later
# pacman call fail.
configure_keyring_repo() {
    if ! pacman-key --init > /dev/null ||
        ! pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com > /dev/null ||
        ! pacman-key --lsign-key F3B607488DB35A47 > /dev/null ||
        ! pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com > /dev/null ||
        ! pacman-key --lsign-key 3056513887B78AEB > /dev/null; then
        printf 'could not import the chaotic-aur signing keys\n' >&2
        return 1
    fi

    local mirror
    for mirror in "${chaotic_mirrors[@]}"; do
        if pacman -U --noconfirm \
                "${mirror}/chaotic-keyring.pkg.tar.zst" \
                "${mirror}/chaotic-mirrorlist.pkg.tar.zst" > /dev/null &&
            [[ -f /etc/pacman.d/chaotic-mirrorlist ]]; then
            # Only a container that starts without chaotic-aur needs the include
            # appended; the builder image already carries the section.
            if ! chaotic_section_configured; then
                printf '%s\n' '[chaotic-aur]' \
                    'Include = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
            fi
            return 0
        fi
        printf 'chaotic-keyring/chaotic-mirrorlist unavailable from %s\n' "$mirror" >&2
    done
    return 1
}

configure_unsigned_repo() {
    if chaotic_section_configured; then
        printf '%s\n' 'chaotic-aur is already configured; keeping that section' >&2
        return 0
    fi
    {
        printf '%s\n' '[chaotic-aur]' 'SigLevel = Never' 'Usage = Sync Search'
        local mirror
        for mirror in "${chaotic_mirrors[@]}"; do
            printf 'Server = %s/$arch\n' "$mirror"
        done
    } >> /etc/pacman.conf
}

# True when pacman.conf already declares chaotic-aur. The builder image ships
# such a section, and appending a second one is worse than useless: pacman
# reports `could not register 'chaotic-aur' database (database already
# registered)` on every later call (exit code stays 0, but the log is noise) and
# it registers the *first* section, so an appended fallback would never be used.
# Keep what the image configured instead of duplicating it.
chaotic_section_configured() {
    grep -qx '\[chaotic-aur\]' /etc/pacman.conf
}

# Drop the section this script appended so the other route can replace it. Safe
# because it is always the last section in the file.
remove_chaotic_section() {
    sed -i '/^\[chaotic-aur\]$/,$d' /etc/pacman.conf
}

sed -i "/^\[options\]$/a DisableSandboxNetwork" /etc/pacman.conf

if configure_keyring_repo; then
    route='keyring'
else
    printf '%s\n' \
        'keyring route unavailable; using direct chaotic mirrors without signature checks' >&2
    configure_unsigned_repo
    route='direct'
fi

if ! retry pacman -Sy --noconfirm > /dev/null; then
    if [[ "$route" == 'keyring' ]]; then
        printf '%s\n' 'keyring mirrorlist could not be synced; switching to direct mirrors' >&2
        remove_chaotic_section
        configure_unsigned_repo
        retry pacman -Sy --noconfirm > /dev/null || true
    fi
fi

if [[ -z "$(pacman -Slq chaotic-aur 2>/dev/null | head -n 1)" ]]; then
    printf 'chaotic-aur is not usable\n' >&2
    exit 1
fi

printf 'chaotic-aur configured via %s route\n' "$route"
