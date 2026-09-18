#!/usr/bin/env bash
set -Eeuo pipefail

backup="$(mktemp)"
trap 'cp "$backup" /etc/pacman.conf; rm -f "$backup"' EXIT
cp /etc/pacman.conf "$backup"

# CachyOS pacman supports this container-only option, while the current
# pycman parser used by namcap does not. Keep it enabled for pacman and
# hide it only for namcap's read of pacman.conf.
sed -i '/^DisableSandboxNetwork$/d' /etc/pacman.conf

runuser -u builder -- env HOME=/home/builder namcap "$@"
