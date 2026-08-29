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
# Keep Arch Linux repository package and database signature checks enabled.
# The third-party repositories below are explicitly unsigned and scoped
# locally.
set_signature_level "SigLevel" "Required DatabaseOptional"
# Local-file installs stay unverified: the chaotic mirrorlist package is
# fetched over HTTPS, is unsigned for us, and would otherwise require
# importing the chaotic key into every build container.
set_signature_level "LocalFileSigLevel" "Never"
set_signature_level "RemoteFileSigLevel" "Required DatabaseOptional"

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

printf 'Enabling CachyOS binary repositories...\n'
# Mirror the target system repository set so built packages link against the
# same library builds that CachyOS machines run.
append_repository \
    "cachyos-v3" \
    $'SigLevel = Never\nServer = https://cdn.cachyos.org/repo/x86_64-v3/$repo'
append_repository \
    "cachyos-core-v3" \
    $'SigLevel = Never\nServer = https://cdn.cachyos.org/repo/x86_64-v3/$repo'
append_repository \
    "cachyos-extra-v3" \
    $'SigLevel = Never\nServer = https://cdn.cachyos.org/repo/x86_64-v3/$repo'
append_repository \
    "cachyos" \
    $'SigLevel = Never\nServer = https://cdn.cachyos.org/repo/x86_64/$repo'
