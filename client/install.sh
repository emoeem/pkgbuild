#!/usr/bin/env bash
# 把 emoeem GitHub Release 仓库注册为本机 pacman 软件仓库。
#
# 用法：
#   sudo ./install.sh
#
# 可用环境变量（通过 sudo env 传递或直接以 root 运行）：
#   PKGBUILD_GITHUB_REPOSITORY  GitHub owner/name，默认 emoeem/pkgbuild
#   PACMAN_REPOSITORY           pacman 仓库名，默认 emoeem
#   RELEASE_TAG                 滚动发布 tag，默认 repo
#   GITHUB_PROXY                GitHub 加速通道前缀，默认 https://gh-proxy.com；
#                               设为空字符串可跳过加速通道（直连 GitHub）

set -Eeuo pipefail

if (( EUID != 0 )); then
    printf '请使用 sudo 运行：%s\n' "sudo $0" >&2
    exit 1
fi

pacman_repository="${PACMAN_REPOSITORY:-emoeem}"
github_repository="${PKGBUILD_GITHUB_REPOSITORY:-emoeem/pkgbuild}"
release_tag="${RELEASE_TAG:-repo}"

if [[ ! "$pacman_repository" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'pacman 仓库名无效：%s\n' "$pacman_repository" >&2
    exit 2
fi
if [[ ! "$github_repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    printf 'GitHub 仓库无效：%s\n' "$github_repository" >&2
    exit 2
fi

github_proxy="${GITHUB_PROXY:-https://gh-proxy.com}"
github_proxy="${github_proxy%/}"
server_url="https://github.com/${github_repository}/releases/download/${release_tag}"
server_url_proxy=""
if [[ -n "$github_proxy" ]]; then
    server_url_proxy="${github_proxy}/${server_url}"
fi
readonly github_proxy server_url server_url_proxy
readonly pacman_conf="/etc/pacman.conf"
readonly begin_marker="# BEGIN ${pacman_repository} pacman repository"
readonly end_marker="# END ${pacman_repository} pacman repository"

servers=("$server_url")
if [[ -n "$server_url_proxy" ]]; then
    servers=("$server_url_proxy" "$server_url")
fi

for command in curl pacman-key gpg awk; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf '缺少必需命令：%s\n' "$command" >&2
        exit 1
    fi
done

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# 私有仓库或网络故障时这里会直接失败，避免写入一个用不了的仓库段。
# 先试加速通道，失败再试直连。
preflight_ok=0
for server in "${servers[@]}"; do
    if curl -fsIL --max-time 20 -o /dev/null \
        "${server}/${pacman_repository}.db"; then
        preflight_ok=1
        break
    fi
done
if (( preflight_ok != 1 )); then
    printf '无法匿名访问 %s/%s。\n' "$server_url" "${pacman_repository}.db" >&2
    printf '请确认 GitHub 仓库是公开的，且 %s Release 已完成首次发布。\n' "$release_tag" >&2
    exit 1
fi

siglevel="Never"
key_file="${temp_dir}/${pacman_repository}-key.asc"
if curl -fsSL --retry 3 "${server_url}/${pacman_repository}-key.asc" -o "$key_file"; then
    pacman-key --init
    pacman-key --add "$key_file"
    fingerprint="$(
        gpg --homedir /etc/pacman.d/gnupg --batch --with-colons \
            --show-keys "$key_file" |
            awk -F: '$1 == "fpr" { print $10; exit }'
    )"
    pacman-key --lsign-key "$fingerprint"
    siglevel="Required DatabaseRequired"
    printf '已导入并本地信任仓库签名密钥 %s。\n' "$fingerprint"
else
    printf '仓库未启用签名，使用 SigLevel = Never。\n'
fi

cp -- "$pacman_conf" "${pacman_conf}.emoeem-backup"

# 删除旧的管理段（标记块）以及手写过的 [emoeem] 段，避免重复仓库段。
awk -v repo_header="[${pacman_repository}]" \
    -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    $0 == repo_header { skip = 2; next }
    skip == 2 && /^\[/ { skip = 0 }
    skip { next }
    { print }
' "$pacman_conf" > "${temp_dir}/pacman.conf"

{
    printf '\n%s（由 client/install.sh 管理，重复运行会更新此段）\n' \
        "$begin_marker"
    printf '[%s]\n' "$pacman_repository"
    printf 'SigLevel = %s\n' "$siglevel"
    for server in "${servers[@]}"; do
        printf 'Server = %s\n' "$server"
    done
    printf '%s\n' "$end_marker"
} >> "${temp_dir}/pacman.conf"

install -m0644 "${temp_dir}/pacman.conf" "$pacman_conf"

pacman -Sy

printf '\n%s 仓库已配置完成：\n' "$pacman_repository"
for server in "${servers[@]}"; do
    printf '  Server = %s\n' "$server"
done
printf '  SigLevel = %s\n' "$siglevel"
printf '原 pacman.conf 已备份为 %s。\n' "${pacman_conf}.emoeem-backup"
printf '现在可以像使用官方仓库一样安装软件包，例如：\n'
printf '  sudo pacman -S %s/<package-name>\n' "$pacman_repository"
