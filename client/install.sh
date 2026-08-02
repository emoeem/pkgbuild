#!/usr/bin/env bash

set -Eeuo pipefail

client_dir="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"
readonly client_dir

readonly repository_path="${1:-/var/lib/emoeem-repo}"

if [[ ! -d "${repository_path}/.git" ]]; then
    printf 'Repository checkout not found: %s\n' "$repository_path" >&2
    printf 'Clone the private repo branch before running this installer.\n' >&2
    exit 1
fi

repository_owner="$(stat -c '%U' "$repository_path")"
if [[ "$repository_owner" == "root" ]]; then
    printf '%s must be owned by the user whose GitHub credentials clone it.\n' \
        "$repository_path" >&2
    exit 1
fi
readonly repository_owner

if ! command -v sudo >/dev/null 2>&1; then
    printf 'sudo is required to install the updater.\n' >&2
    exit 1
fi

config_temp="$(mktemp)"
trap 'rm -f "$config_temp"' EXIT
{
    printf 'REPOSITORY_PATH=%q\n' "$repository_path"
    printf 'REPOSITORY_OWNER=%q\n' "$repository_owner"
    printf 'PACMAN_SYNC_DIR=%q\n' '/var/lib/pacman/sync'
    printf 'PACMAN_LOCK_FILE=%q\n' '/var/lib/pacman/db.lck'
} > "$config_temp"

sudo install -m0755 \
    "${client_dir}/emoeem-update" \
    /usr/local/bin/emoeem-update
sudo install -m0600 "$config_temp" /etc/emoeem-repo.conf
sudo install -m0644 \
    "${client_dir}/emoeem-repo-update.service" \
    /etc/systemd/system/emoeem-repo-update.service
sudo install -m0644 \
    "${client_dir}/emoeem-repo-update.timer" \
    /etc/systemd/system/emoeem-repo-update.timer

sudo systemctl daemon-reload
sudo systemctl enable --now emoeem-repo-update.timer
sudo /usr/local/bin/emoeem-update

printf '\nAutomatic repository updates are enabled for %s.\n' \
    "$repository_path"
printf 'Run emoeem-update manually at any time.\n'
