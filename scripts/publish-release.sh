#!/usr/bin/env bash
# 把本地 pacman 仓库目录发布为固定 tag 的滚动 GitHub Release。
#
# pacman 直接从 release 资产下载数据库和软件包，因此资产使用
# <repo>.db / <repo>.files 这样的常规名称，并始终保持整个 release
# 与数据库一致：上传有变化的资产，删除数据库不再引用的旧资产。
#
# 必需环境变量：
#   REPOSITORY_DIR       包含 <repo>.db 等产物的仓库目录
#   RELEASE_REPOSITORY   GitHub owner/name
#   RELEASE_TAG          滚动发布使用的固定 tag
#   REPOSITORY_NAME      pacman 仓库名
# 通过 GH_TOKEN 鉴权，调用 gh CLI。

set -Eeuo pipefail

for variable in REPOSITORY_DIR RELEASE_REPOSITORY RELEASE_TAG REPOSITORY_NAME; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'Missing required environment variable: %s\n' "$variable" >&2
        exit 2
    fi
done

readonly repository_dir="${REPOSITORY_DIR}"
readonly release_repository="${RELEASE_REPOSITORY}"
readonly release_tag="${RELEASE_TAG}"
readonly repository_name="${REPOSITORY_NAME}"

if ! command -v gh >/dev/null 2>&1; then
    printf 'gh is required to publish the repository release.\n' >&2
    exit 1
fi

if [[ ! -f "${repository_dir}/${repository_name}.db" ||
    ! -f "${repository_dir}/${repository_name}.files" ]]; then
    printf 'Repository database is missing in %s\n' "$repository_dir" >&2
    exit 1
fi

notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT

cd "$repository_dir"

# 只有脚本管理的资产允许上传或删除，手工上传到该 release 的其他
# 文件不受影响。
is_managed_asset() {
    local asset="$1"
    local -a metadata_names=(
        "${repository_name}.db"
        "${repository_name}.files"
        "${repository_name}.db.sig"
        "${repository_name}.files.sig"
        "${repository_name}.conf"
        "${repository_name}-key.asc"
        "SHA256SUMS"
    )
    local name
    for name in "${metadata_names[@]}"; do
        [[ "$asset" == "$name" ]] && return 0
    done
    [[ "$asset" == *.pkg.tar.zst ]]
}

mapfile -d '' managed_files < <(
    find . -maxdepth 1 -type f -print0 |
        sort -z |
        while IFS= read -r -d '' file; do
            if is_managed_asset "$(basename "$file")"; then
                printf '%s\0' "$file"
            fi
        done
)

declare -A existing_digest=()
while IFS=$'\t' read -r asset_name asset_digest; do
    [[ -n "$asset_name" ]] || continue
    existing_digest["$asset_name"]="$asset_digest"
done < <(
    gh release view "$release_tag" --repo "$release_repository" \
        --json assets --jq '.assets[] | [.name, (.digest // "")] | @tsv' \
        2>/dev/null ||
        true
)

if gh release view "$release_tag" --repo "$release_repository" >/dev/null 2>&1; then
    printf 'Updating existing release %s.\n' "$release_tag"
else
    printf 'Release %s does not exist yet; creating it.\n' "$release_tag"
    gh release create "$release_tag" \
        --repo "$release_repository" \
        --latest \
        --title "${repository_name} pacman repository (rolling)" \
        --notes "Initial publish of the ${repository_name} pacman repository."
fi

# 先上传软件包，最后上传数据库，避免客户端在两次上传之间看到引用了
# 尚不存在软件包的新数据库。
upload_files=()
for file in "${managed_files[@]}"; do
    case "$(basename "$file")" in
        *.pkg.tar.zst) upload_files+=("$file") ;;
    esac
done
for file in "${managed_files[@]}"; do
    case "$(basename "$file")" in
        *.pkg.tar.zst) ;;
        *) upload_files+=("$file") ;;
    esac
done

pending_files=()
for file in "${upload_files[@]}"; do
    name="$(basename "$file")"
    local_digest="sha256:$(sha256sum -- "$file" | awk '{ print $1 }')"
    if [[ "${existing_digest[$name]:-}" == "$local_digest" ]]; then
        printf 'Asset unchanged, skipping upload: %s\n' "$name"
    else
        pending_files+=("$file")
    fi
done

if (( ${#pending_files[@]} > 0 )); then
    gh release upload "$release_tag" \
        --repo "$release_repository" \
        --clobber \
        "${pending_files[@]}"
fi

deleted_count=0
for asset_name in "${!existing_digest[@]}"; do
    if is_managed_asset "$asset_name" && [[ ! -f "$asset_name" ]]; then
        printf 'Deleting stale asset: %s\n' "$asset_name"
        gh release delete-asset "$release_tag" "$asset_name" \
            --repo "$release_repository" \
            --yes
        deleted_count=$((deleted_count + 1))
    fi
done

package_count="$(find . -maxdepth 1 -type f -name '*.pkg.tar.zst' | wc -l)"
updated_at="$(date -u '+%Y-%m-%d %H:%M UTC')"
server_url="https://github.com/${release_repository}/releases/download/${release_tag}"

cat > "$notes_file" <<EOF
\`${repository_name}\` pacman 仓库的滚动发布，内容随每次构建自动更新。

把下面的内容加入 \`/etc/pacman.conf\`：

\`\`\`ini
[${repository_name}]
SigLevel = Never
Server = ${server_url}
\`\`\`

启用仓库签名时，先导入并本地信任 \`${repository_name}-key.asc\`，
再把 \`SigLevel\` 改为 \`Required DatabaseRequired\`。

- 软件包数量：${package_count}
- 最后更新：${updated_at}
EOF

gh release edit "$release_tag" \
    --repo "$release_repository" \
    --latest \
    --title "${repository_name} pacman repository (rolling)" \
    --notes-file "$notes_file"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '## Pacman repository release\n\n'
        printf -- '- Release tag: `%s`\n' "$release_tag"
        printf -- '- Packages: %d\n' "$package_count"
        printf -- '- Uploaded assets: %d\n' "${#pending_files[@]}"
        printf -- '- Deleted stale assets: %d\n' "$deleted_count"
    } >> "$GITHUB_STEP_SUMMARY"
fi

printf 'Release %s now serves %d packages (%d uploads, %d deletions).\n' \
    "$release_tag" "$package_count" "${#pending_files[@]}" "$deleted_count"
