#!/usr/bin/env bash
set -Eeuo pipefail

repo_name="${LOCAL_REPO_NAME:-emoeem}"
repo_dir="${LOCAL_REPO_DIR:-}"

if [[ -n "$repo_dir" ]]; then
    mkdir -p "$repo_dir"
    shopt -s nullglob
    packages=("$repo_dir"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#packages[@]} > 0 )); then
        rm -f "$repo_dir/${repo_name}.db"* "$repo_dir/${repo_name}.files"*
        repo-add --remove "$repo_dir/${repo_name}.db.tar.gz" "${packages[@]}" >/dev/null
        cat > /tmp/emo-repo.conf <<EOF
[${repo_name}]
SigLevel = Never
Server = file://${repo_dir}
EOF
        awk -v name="$repo_name" '
            $0 == "[" name "]" {skip=1; next}
            skip && /^\[/ {skip=0}
            !skip {print}
        ' /etc/pacman.conf >> /tmp/emo-repo.conf
        cat /tmp/emo-repo.conf > /etc/pacman.conf
    fi
fi

if pacman-conf --repo-list | head -n1 | grep -Fxq "$repo_name"; then
    printf 'Repository policy: %s is authoritative.\n' "$repo_name"
elif [[ -z "$repo_dir" ]]; then
    printf 'Local repository %s is not first in pacman.conf; refusing unsafe build.\n' "$repo_name" >&2
    exit 2
fi
