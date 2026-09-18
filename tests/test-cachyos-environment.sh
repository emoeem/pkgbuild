#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-base}"
if [[ ! -f /etc/os-release ]] || ! grep -q "^ID=cachyos$" /etc/os-release; then
    echo "CachyOS environment required." >&2; exit 1
fi
pacman-conf --repo-list | grep -Fxq cachyos-v3
command -v pacman >/dev/null
command -v makepkg >/dev/null
command -v aria2c >/dev/null
command -v namcap >/dev/null
[[ "$(uname -m)" == x86_64 ]]
if [[ "$mode" == builder ]]; then
    command -v yay >/dev/null
    pacman-conf DisableSandboxNetwork | grep -Fxq DisableSandboxNetwork
    [[ "${PKGBUILD_BUILDER_IMAGE:-0}" == 1 ]]
fi
if [[ "$mode" == cuda ]]; then
    command -v nvcc >/dev/null
    [[ -x /opt/cuda/bin/nvcc || -x /usr/bin/nvcc ]]
    pacman -Q cuda >/dev/null
fi
printf "CachyOS %s environment checks passed (%s mode).\n" "$(uname -m)" "$mode"
