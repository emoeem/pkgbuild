#!/usr/bin/env bash

set -Eeuo pipefail

readonly pacman_config="/etc/pacman.conf"
readonly chaotic_mirrorlist_url="https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"

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

set_signature_level() {
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

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$pacman_config"
set_signature_level "SigLevel" "Never"
set_signature_level "LocalFileSigLevel" "Never"
set_signature_level "RemoteFileSigLevel" "Never"

pacman-key --init
pacman-key --populate archlinux

printf 'Enabling trusted third-party binary repositories...\n'
append_repository \
    "archlinuxcn" \
    $'SigLevel = Never\nServer = https://repo.archlinuxcn.org/$arch'
append_repository \
    "coderkun-aur" \
    $'SigLevel = Never\nServer = https://arch.suruatoel.xyz/$repo/$arch/'

pacman -U --noconfirm "$chaotic_mirrorlist_url"
append_repository \
    "chaotic-aur" \
    $'SigLevel = Never\nInclude = /etc/pacman.d/chaotic-mirrorlist'
