#!/usr/bin/env bash

set -Eeuo pipefail

readonly pacman_config="/etc/pacman.conf"
# Chaotic-AUR 的 CDN 会整体返回 503（2026-09-14 的维护任务就因此失败），
# 所以这里保留多个镜像地址，逐个回退。
readonly chaotic_mirrorlist_urls=(
    "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"
    "https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"
)

if (( EUID != 0 )); then
    printf 'setup-build-repositories.sh must run as root.\n' >&2
    exit 1
fi

append_repository() {
    local repository_name="$1"
    local repository_body="$2"

    if grep -Fqx "[${repository_name}]" "$pacman_config"; then
        return
    fi

    printf '\n[%s]\n%s\n' "$repository_name" "$repository_body" \
        >> "$pacman_config"
}

insert_repository_before_section() {
    local anchor_section="$1"
    local repository_name="$2"
    local repository_body="$3"

    if grep -Fqx "[${repository_name}]" "$pacman_config"; then
        return
    fi

    if ! grep -Fqx "[${anchor_section}]" "$pacman_config"; then
        printf 'Anchor section [%s] not found in %s.\n' \
            "$anchor_section" "$pacman_config" >&2
        exit 1
    fi

    local block_file temporary_config
    block_file="$(mktemp)"
    temporary_config="$(mktemp)"

    printf '[%s]\n%s\n' "$repository_name" "$repository_body" \
        > "$block_file"

    awk -v anchor="[${anchor_section}]" \
        -v block_file="$block_file" '
        !inserted && $0 == anchor {
            while ((getline line < block_file) > 0) {
                print line
            }
            close(block_file)
            inserted = 1
        }
        { print }
    ' "$pacman_config" > "$temporary_config"

    rm -f "$block_file"

    install -m 0644 "$temporary_config" "$pacman_config"
    rm -f "$temporary_config"
}

set_pacman_setting() {
    local setting="$1"
    local value="$2"

    if grep -Eq "^#?${setting}[[:space:]]*=" "$pacman_config"; then
        sed -Ei \
            "s|^#?${setting}[[:space:]]*=.*|${setting} = ${value}|" \
            "$pacman_config"
    else
        printf '%s = %s\n' "$setting" "$value" >> "$pacman_config"
    fi
}

# 依次尝试给定的镜像地址，每个地址内部还会自行重试。上游 CDN 偶尔会
# 整体不可用，只试一个地址时重试到超时就会让整个 workflow 失败。
download_first_available() {
    local output="$1"
    shift

    local url
    for url in "$@"; do
        if curl -fsSL --retry 10 --retry-all-errors --retry-delay 6 \
            --connect-timeout 30 --max-time 900 -o "$output" "$url"; then
            return 0
        fi
        printf 'Download failed for %s; trying the next mirror.\n' \
            "$url" >&2
    done

    printf 'Unable to download %s from any mirror.\n' "$output" >&2
    return 1
}

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$pacman_config"
# Keep Arch Linux repository package and database signature checks enabled.
# The third-party repositories below are explicitly unsigned and scoped
# locally.
set_pacman_setting "SigLevel" "Required DatabaseOptional"
# Local-file installs stay unverified: the chaotic mirrorlist package is
# fetched over HTTPS, is unsigned for us, and would otherwise require
# importing the chaotic key into every build container.
set_pacman_setting "LocalFileSigLevel" "Never"
set_pacman_setting "RemoteFileSigLevel" "Required DatabaseOptional"

pacman-key --init
pacman-key --populate archlinux

printf 'Enabling CachyOS binary repositories ahead of the Arch Linux ones...\n'
# Mirror the target system's repository priority: CachyOS machines resolve
# identically named packages from the cachyos-* repositories before core and
# extra, so inserting them ahead of [core] makes builds link against the
# same library builds that the installed CachyOS system runs. Appending them
# at the end let Arch win every conflict and produced binaries linked against
# library versions CachyOS had already replaced.
#
# Use the official mirrorlists instead of hardcoding a single cdn.cachyos.org
# server: the x86_64-v3 path on that CDN serves an HTML error page (the real
# repositories live under x86_64_v3), and the mirrorlist files resolve both
# problems by using the pacman $arch / $arch_v3 variables against a list of
# mirrors, exactly like the packaged cachyos-mirrorlist and
# cachyos-v3-mirrorlist on CachyOS machines. The v3 list is the base list
# with $arch rewritten inside Server lines.
#
# The v3 repositories ship the x86_64_v3 architecture; the container default
# (Architecture = auto) only allows x86_64 and would silently ignore every
# v3 package even with correct repository order.
set_pacman_setting "Architecture" "x86_64 x86_64_v3"
readonly cachyos_mirrorlist_urls=(
    "https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist"
    "https://cdn.jsdelivr.net/gh/CachyOS/CachyOS-PKGBUILDS@master/cachyos-mirrorlist/cachyos-mirrorlist"
)
download_first_available \
    /etc/pacman.d/cachyos-mirrorlist \
    "${cachyos_mirrorlist_urls[@]}"
sed '/^Server = /s/\$arch/\$arch_v3/' /etc/pacman.d/cachyos-mirrorlist \
    > /etc/pacman.d/cachyos-v3-mirrorlist

insert_repository_before_section \
    "core" \
    "cachyos-v3" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist'
insert_repository_before_section \
    "core" \
    "cachyos-extra-v3" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist'
insert_repository_before_section \
    "core" \
    "cachyos-core-v3" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist'
insert_repository_before_section \
    "core" \
    "cachyos" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/cachyos-mirrorlist'

printf 'Enabling trusted third-party binary repositories...\n'
append_repository \
    "archlinuxcn" \
    $'SigLevel = Never\nServer = https://repo.archlinuxcn.org/$arch'
append_repository \
    "coderkun-aur" \
    $'SigLevel = Never\nServer = https://arch.suruatoel.xyz/$repo/$arch/'

# Download to the cache first: pacman -U from a URL verifies the file with
# RemoteFileSigLevel, and the chaotic signing key is not present in build
# containers. A local-file install skips that check (LocalFileSigLevel).
download_first_available \
    /var/cache/pacman/pkg/chaotic-mirrorlist.pkg.tar.zst \
    "${chaotic_mirrorlist_urls[@]}"
pacman -U --noconfirm \
    /var/cache/pacman/pkg/chaotic-mirrorlist.pkg.tar.zst
append_repository \
    "chaotic-aur" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/chaotic-mirrorlist'
