#!/usr/bin/env bash

set -Euo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 &&
        pwd
)"
readonly repo_root

github_repository="${PKGBUILD_GITHUB_REPOSITORY:-emoeem/pkgbuild}"
pacman_repository="${PKGBUILD_PACMAN_REPOSITORY:-emoeem}"
default_make_jobs="${PKGBUILD_DEFAULT_MAKE_JOBS:-2}"

if [[ ! "$github_repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    printf 'GitHub 仓库配置无效：%s\n' "$github_repository" >&2
    exit 2
fi
if [[ ! "$pacman_repository" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'pacman 仓库配置无效：%s\n' "$pacman_repository" >&2
    exit 2
fi
if [[ ! "$default_make_jobs" =~ ^[1-4]$ ]]; then
    printf '默认编译线程数无效：%s\n' \
        "$default_make_jobs" >&2
    exit 2
fi

readonly github_repository
readonly pacman_repository
readonly default_make_jobs

usage() {
    cat <<EOF
用法：$(basename "$0") [--no-push]

打开基于 fzf 的私人软件仓库管理界面。

  --no-push  启动时关闭自动 Git 推送。
EOF
}

push_changes=1
if [[ "${1:-}" == "--no-push" ]]; then
    push_changes=0
    shift
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if (( $# != 0 )); then
    usage >&2
    exit 2
fi

for command_name in git fzf; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '缺少必需命令：%s\n' "$command_name" >&2
        if [[ "$command_name" == "fzf" ]]; then
            printf '安装命令：sudo pacman -S fzf\n' >&2
        fi
        exit 1
    fi
done

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s 不是 Git 工作目录。\n' "$repo_root" >&2
    exit 1
fi

readonly -a fzf_options=(
    --height=85%
    --layout=reverse
    --border
    --cycle
    --info=inline
    --pointer='▶'
    --marker='✓'
    --color='border:bright-black,prompt:cyan,pointer:yellow,marker:green,header:blue'
)

readonly -a fzf_package_options=(
    "${fzf_options[@]}"
    --delimiter=$'\t'
    --with-nth=2..
    --preview="sed -n '1,220p' '${repo_root}/packages/{1}/PKGBUILD'"
    --preview-window='right:55%:wrap'
    --bind='ctrl-/:toggle-preview'
)

pause_after_action() {
    printf '\n'
    read -r -p '按 Enter 返回主菜单...' _ || true
}

prompt_value() {
    local label="$1"
    local value

    read -r -p "${label}: " value || return 1
    printf '%s\n' "$value"
}

managed_packages() {
    find "${repo_root}/packages" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name PKGBUILD \
        -printf '%h\n' |
        xargs -r -n1 basename |
        sort -u
}

package_records() {
    local package_dir package_name pkgdesc pkgrel pkgver arch

    while IFS= read -r package_dir; do
        package_name="$(basename "$package_dir")"
        pkgver="$(awk -F ' = ' '$1 == "\tpkgver" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        pkgrel="$(awk -F ' = ' '$1 == "\tpkgrel" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        pkgdesc="$(awk -F ' = ' '$1 == "\tpkgdesc" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        arch="$(awk -F ' = ' '$1 == "\tarch" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        printf '%s\t%s-%s\t%s\t%s\n' \
            "$package_name" "$pkgver" "$pkgrel" "$arch" "$pkgdesc"
    done < <(
        find "${repo_root}/packages" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name PKGBUILD \
            -printf '%h\n' |
            sort -u
    )
}

aur_package_records() {
    local package_dir package_name pkgdesc pkgrel pkgver

    while IFS= read -r package_dir; do
        package_name="$(basename "$package_dir")"
        pkgver="$(awk -F ' = ' '$1 == "\tpkgver" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        pkgrel="$(awk -F ' = ' '$1 == "\tpkgrel" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        pkgdesc="$(awk -F ' = ' '$1 == "\tpkgdesc" { print $2; exit }' \
            "${package_dir}/.SRCINFO")"
        printf '%s\t%s-%s\t%s\n' \
            "$package_name" "$pkgver" "$pkgrel" "$pkgdesc"
    done < <(
        find "${repo_root}/packages" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name .aur-url \
            -printf '%h\n' |
            sort -u
    )
}

select_one() {
    local prompt="$1"
    shift

    printf '%s\n' "$@" |
        fzf "${fzf_options[@]}" --prompt="${prompt}> "
}

select_managed_package() {
    local selected

    selected="$(
        package_records |
            fzf "${fzf_package_options[@]}" --prompt='软件包> ' \
                --header='版本 | 架构 | 描述（预览 PKGBUILD）'
    )" || return
    printf '%s\n' "${selected%%$'\t'*}"
}

select_managed_packages() {
    local selected

    selected="$(
        package_records |
        fzf \
            "${fzf_package_options[@]}" \
            --multi \
            --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
            --header='版本 | 架构 | 描述；Tab：选择  Ctrl-A：全选  Ctrl-D：取消全选' \
            --prompt='软件包> '
    )" || return
    while IFS=$'\t' read -r package_name _; do
        [[ -n "$package_name" ]] && printf '%s\n' "$package_name"
    done <<< "$selected"
}

select_aur_packages() {
    local selected

    selected="$(
        {
            printf '%s\t%s\n' '全部 AUR 软件包' '同步所有 AUR 管理的软件包'
            aur_package_records
        } |
        fzf \
            "${fzf_package_options[@]}" \
            --multi \
            --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
            --header='选择“全部 AUR 软件包”，或使用 Tab 多选' \
            --prompt='同步 AUR> '
    )" || return
    while IFS=$'\t' read -r package_name _; do
        [[ -n "$package_name" ]] && printf '%s\n' "$package_name"
    done <<< "$selected"
}

select_build_packages() {
    local selected

    selected="$(
        {
            printf '%s\t%s\n' '全部软件包' '构建所有托管软件包'
            package_records
        } |
        fzf \
            "${fzf_package_options[@]}" \
            --multi \
            --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
            --header='选择“全部软件包”，或使用 Tab 多选' \
            --prompt='构建软件包> '
    )" || return
    while IFS=$'\t' read -r package_name _; do
        [[ -n "$package_name" ]] && printf '%s\n' "$package_name"
    done <<< "$selected"
}

require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        printf '缺少 GitHub CLI。安装命令：sudo pacman -S github-cli\n' \
            >&2
        return 1
    fi
    if ! gh auth token >/dev/null 2>&1; then
        printf 'GitHub CLI 未登录。运行：gh auth login\n' >&2
        return 1
    fi
}

pull_main() {
    if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
        printf '工作区存在未提交修改，已取消拉取以避免覆盖本地工作。\n' >&2
        return 1
    fi
    git -C "$repo_root" pull --ff-only origin main
}

add_aur_package() {
    local package_name
    local -a arguments=()

    package_name="$(prompt_value 'AUR package base 名称')" || return
    [[ -n "$package_name" ]] || return
    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/add-aur-package.sh" \
        "${arguments[@]}" \
        "$package_name"
}

add_custom_package() {
    local package_name git_url
    local -a arguments=()

    package_name="$(prompt_value 'Package base 名称')" || return
    [[ -n "$package_name" ]] || return
    git_url="$(prompt_value 'PKGBUILD Git 地址')" || return
    [[ -n "$git_url" ]] || return
    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/add-aur-package.sh" \
        "${arguments[@]}" \
        "$package_name" \
        "$git_url"
}

remove_package() {
    local package_name confirmation
    local -a arguments=()

    package_name="$(select_managed_package)" || return
    [[ -n "$package_name" ]] || return
    confirmation="$(
        select_one \
            "确认删除 ${package_name}" \
            '取消' \
            '从仓库删除'
    )" || return
    [[ "$confirmation" == '从仓库删除' ]] || return

    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/remove-package.sh" \
        "${arguments[@]}" \
        "$package_name"
}

sync_aur_sources() {
    local package_name selection package_csv
    local -a packages=()

    require_gh || return
    mapfile -t packages < <(select_aur_packages)
    (( ${#packages[@]} > 0 )) || return

    selection="selected"
    for package_name in "${packages[@]}"; do
        if [[ "$package_name" == "全部 AUR 软件包" ]]; then
            selection="all"
            break
        fi
    done

    if [[ "$selection" == "all" ]]; then
        package_csv="all"
    else
        package_csv="$(IFS=,; printf '%s' "${packages[*]}")"
    fi

    gh workflow run sync.yml \
        --repo "$github_repository" \
        --ref main \
        -f "packages=${package_csv}"
    if [[ "$package_csv" == "all" ]]; then
        printf '已请求同步全部 AUR 软件包。\n'
    else
        printf '已请求同步 AUR 软件包：%s\n' "$package_csv"
    fi
}

build_packages() {
    local candidate make_jobs package_csv jobs_choice selection
    local -a jobs_options=("${default_make_jobs} （默认）")
    local -a packages=()

    require_gh || return
    mapfile -t packages < <(select_build_packages)
    (( ${#packages[@]} > 0 )) || return

    selection="selected"
    for candidate in "${packages[@]}"; do
        if [[ "$candidate" == "全部软件包" ]]; then
            selection="all"
            break
        fi
    done

    if [[ "$selection" == "all" ]]; then
        package_csv="all"
    else
        package_csv="$(IFS=,; printf '%s' "${packages[*]}")"
    fi

    for candidate in 1 2 3 4; do
        [[ "$candidate" == "$default_make_jobs" ]] ||
            jobs_options+=("$candidate")
    done
    jobs_choice="$(
        select_one '编译线程数' "${jobs_options[@]}"
    )" || return
    make_jobs="${jobs_choice%% *}"

    gh workflow run build.yml \
        --repo "$github_repository" \
        --ref main \
        -f "packages=${package_csv}" \
        -f "make_jobs=${make_jobs}"
    if [[ "$package_csv" == "all" ]]; then
        printf '已请求构建全部软件包（编译线程数：%s）。\n' "$make_jobs"
    else
        printf '已请求构建：%s（编译线程数：%s）\n' \
            "$package_csv" "$make_jobs"
    fi

    if [[ "$(
        select_one '跟踪这次构建？' '否' '跟踪'
    )" == '跟踪' ]]; then
        track_running_build
    fi
}

check_local_packages() {
    local -a packages=()

    mapfile -t packages < <(select_managed_packages)
    (( ${#packages[@]} > 0 )) || return
    "${repo_root}/scripts/check-package.sh" "${packages[@]}"
}

update_local_repository() {
    sudo pacman -Sy
    pacman -Sl "$pacman_repository"
}

install_repository_package() {
    local package_name selected
    local -a packages=() chosen=()

    mapfile -t packages < <(
        pacman -Sl "$pacman_repository" 2>/dev/null |
            awk '{ print $2 }' |
            sort -u
    )
    if (( ${#packages[@]} == 0 )); then
        printf '%s 仓库当前没有可安装的软件包。\n' \
            "$pacman_repository" >&2
        return 1
    fi

    selected="$(
        printf '%s\n' "${packages[@]}" |
            fzf \
                "${fzf_options[@]}" \
                --multi \
                --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
                --header='Tab：选择  Ctrl-A：全选  Ctrl-D：取消全选' \
                --prompt='安装软件包> '
    )" || return
    while IFS= read -r package_name; do
        [[ -n "$package_name" ]] && chosen+=("$package_name")
    done <<< "$selected"
    (( ${#chosen[@]} > 0 )) || return

    sudo pacman -S --needed \
        "${chosen[@]/#/${pacman_repository}/}"
}

track_running_build() {
    local run_data run_id run_title selected status conclusion jobs_data
    local poll
    local -a runs=() running_jobs=()

    run_data="$(
        gh run list \
            --repo "$github_repository" \
            --workflow build.yml \
            --limit 5 \
            --json databaseId,status,displayTitle \
            --jq '.[] | select(.status != "completed") | [.databaseId, .displayTitle] | @tsv'
    )" || return
    if [[ -z "$run_data" ]]; then
        printf '没有正在运行或排队的构建。\n'
        return 0
    fi
    while IFS=$'\t' read -r run_id run_title; do
        [[ -n "$run_id" ]] && runs+=("${run_id}"$'\t'"${run_title}")
    done <<< "$run_data"
    (( ${#runs[@]} > 0 )) || return 0
    if (( ${#runs[@]} == 1 )); then
        selected="${runs[0]}"
    else
        selected="$(
            printf '%s\n' "${runs[@]}" |
                fzf \
                    "${fzf_options[@]}" \
                    --delimiter=$'\t' \
                    --with-nth=2.. \
                    --prompt='跟踪构建> '
        )" || return
    fi
    run_id="${selected%%$'\t'*}"

    for poll in $(seq 1 90); do
        status="$(
            gh run view "$run_id" --repo "$github_repository" \
                --json status,conclusion \
                --jq '.status + ":" + (.conclusion // "-")'
        )" || return
        case "$status" in
            completed:*) break ;;
        esac
        mapfile -t running_jobs < <(
            gh run view "$run_id" --repo "$github_repository" \
                --json jobs \
                --jq '.jobs[] | select(.status == "in_progress") | .name' 2>/dev/null
        )
        if (( ${#running_jobs[@]} > 0 )); then
            printf '[%3ds] 正在构建：%s\n' \
                $((poll * 20)) "${running_jobs[*]}"
        else
            printf '[%3ds] 等待调度中...\n' $((poll * 20))
        fi
        sleep 20
    done

    if [[ "$status" != completed:* ]]; then
        printf '跟踪超时，构建仍在进行。可以稍后从「查看最近的 GitHub Actions」继续。\n'
        return 0
    fi
    conclusion="${status#completed:}"
    printf '构建完成，结果：%s。\n' \
        "$(translate_action_conclusion "$conclusion")"
    jobs_data="$(
        gh run view "$run_id" --repo "$github_repository" \
            --json jobs \
            --jq '.jobs[] | select(.name | startswith("Build ")) | [.name, (.conclusion // .status)] | @tsv'
    )" || return
    while IFS=$'\t' read -r run_title status; do
        [[ -n "$run_title" ]] || continue
        printf '  %-50s %s\n' "${run_title#Build }" \
            "$(translate_action_conclusion "$status")"
    done <<< "$jobs_data"
}

triage_failed_builds() {
    local run_data run_id selected choice packages_csv
    local -a runs=() failed_packages=()

    run_data="$(
        gh run list \
            --repo "$github_repository" \
            --workflow build.yml \
            --limit 30 \
            --json databaseId,conclusion,displayTitle \
            --jq '.[] | select(.conclusion == "failure") | [.databaseId, .displayTitle] | @tsv'
    )" || return
    if [[ -z "$run_data" ]]; then
        printf '最近没有失败的构建。\n'
        return 0
    fi
    while IFS=$'\t' read -r run_id run_title; do
        [[ -n "$run_id" ]] && runs+=("${run_id}"$'\t'"${run_title}")
    done <<< "$run_data"
    selected="$(
        printf '%s\n' "${runs[@]}" |
            fzf \
                "${fzf_options[@]}" \
                --delimiter=$'\t' \
                --with-nth=2.. \
                --prompt='失败构建> '
    )" || return
    run_id="${selected%%$'\t'*}"

    mapfile -t failed_packages < <(
        gh run view "$run_id" --repo "$github_repository" \
            --json jobs \
            --jq '.jobs[] | select(.conclusion == "failure") | .name | sub("^Build "; "")'
    )
    if (( ${#failed_packages[@]} == 0 )); then
        printf '该构建没有失败的软件包任务（可能是发布阶段失败）。\n'
        return 0
    fi
    printf '失败的软件包：\n'
    printf '  %s\n' "${failed_packages[@]}"

    choice="$(
        select_one '处理方式' '返回' '查看失败日志' '重跑失败的软件包'
    )" || return
    case "$choice" in
        '查看失败日志')
            gh run view "$run_id" --repo "$github_repository" \
                --log-failed | ${PAGER:-less -R}
            ;;
        '重跑失败的软件包')
            packages_csv="$(IFS=,; printf '%s' "${failed_packages[*]}")"
            gh workflow run build.yml \
                --repo "$github_repository" \
                --ref main \
                -f "packages=${packages_csv}" \
                -f "make_jobs=4"
            printf '已请求重新构建：%s\n' "$packages_csv"
            ;;
    esac
}

check_local_updates() {
    local package_name installed available status comparison
    local -a rows=()

    while IFS= read -r package_name; do
        installed="$(
            pacman -Q "$package_name" 2>/dev/null |
                awk '{ print $2 }' || true
        )"
        available="$(
            pacman -Si "${pacman_repository}/${package_name}" 2>/dev/null |
                awk -F ': ' '/^(Version|版本)/ { print $2; exit }' || true
        )"
        if [[ -z "$available" ]]; then
            status='不在仓库中'
        elif [[ -z "$installed" ]]; then
            status='本机未安装'
        elif comparison="$(vercmp "$installed" "$available" 2>/dev/null)"; then
            case "$comparison" in
                -1) status='可升级' ;;
                0) status='已是最新' ;;
                *) status='本地版本更新' ;;
            esac
        elif [[ "$installed" == "$available" ]]; then
            status='已是最新'
        else
            status='版本不同'
        fi
        rows+=("${status}"$'\t'"${package_name}"$'\t'"${installed:--}"$'\t'"${available:--}")
    done < <(managed_packages)

    if (( ${#rows[@]} == 0 )); then
        printf '没有托管的软件包。\n'
        return 0
    fi

    printf '%s\n' "${rows[@]}" |
        sort -t$'\t' -k1,1 |
        fzf \
            "${fzf_options[@]}" \
            --delimiter=$'\t' \
            --header='状态 | 软件包 | 本机版本 | 仓库版本（先「更新本地 pacman 仓库」刷新）' \
            --prompt='本地可更新检查> '
}

translate_action_status() {
    case "$1" in
        queued) printf '排队中' ;;
        in_progress) printf '运行中' ;;
        completed) printf '已完成' ;;
        requested) printf '已请求' ;;
        waiting) printf '等待中' ;;
        pending) printf '待处理' ;;
        *) printf '%s' "$1" ;;
    esac
}

translate_action_conclusion() {
    case "$1" in
        success) printf '成功' ;;
        failure) printf '失败' ;;
        cancelled) printf '已取消' ;;
        skipped) printf '已跳过' ;;
        neutral) printf '中性' ;;
        timed_out) printf '超时' ;;
        action_required) printf '需要处理' ;;
        startup_failure) printf '启动失败' ;;
        stale) printf '已过期' ;;
        *) printf '%s' "$1" ;;
    esac
}

translate_workflow_name() {
    case "$1" in
        'Build private Arch repository')
            printf '构建私人 Arch 仓库'
            ;;
        'Remove packages from private repository')
            printf '从私人仓库删除软件包'
            ;;
        'Sync AUR package sources')
            printf '同步 AUR 软件包源'
            ;;
        'Check Arch packages')
            printf '检查软件包配置'
            ;;
        'Maintenance')
            printf '维护任务'
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

show_recent_actions() {
    local conclusion run_data run_id selected status title workflow
    local -a runs=()

    require_gh || return
    run_data="$(
        gh run list \
            --repo "$github_repository" \
            --limit 30 \
            --json databaseId,status,conclusion,workflowName,displayTitle \
            --jq \
            '.[] | [.databaseId, .status, (.conclusion // "-"), .workflowName, .displayTitle] | @tsv'
    )" || return
    while IFS=$'\t' read -r run_id status conclusion workflow title; do
        [[ -n "$run_id" ]] || continue
        runs+=(
            "${run_id}"$'\t'"$(translate_action_status "$status")"$'\t'"$(translate_action_conclusion "$conclusion")"$'\t'"$(translate_workflow_name "$workflow")"$'\t'"${title}"
        )
    done <<< "$run_data"
    if (( ${#runs[@]} == 0 )); then
        printf '没有找到 GitHub Actions 运行记录。\n'
        return
    fi

    selected="$(
        printf '%s\n' "${runs[@]}" |
            fzf \
                "${fzf_options[@]}" \
                --delimiter=$'\t' \
                --with-nth=2.. \
                --header='状态 | 结果 | 工作流 | 标题' \
                --prompt='Actions 运行记录> '
    )" || return
    run_id="${selected%%$'\t'*}"
    gh run view "$run_id" --repo "$github_repository"
}

while true; do
    branch="$(git -C "$repo_root" branch --show-current)"
    package_count="$(managed_packages | wc -l)"
    if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
        repository_state='有未提交修改'
    else
        repository_state='工作区干净'
    fi
    install_label="从 ${pacman_repository} 安装软件包"
    if (( push_changes == 1 )); then
        push_label='开启'
    else
        push_label='关闭'
    fi

    action="$(
        select_one \
            "${github_repository} | 分支 ${branch:-游离状态} | ${package_count} 个软件包 | ${repository_state} | 自动推送 ${push_label}" \
            '添加 AUR 软件包' \
            '从自定义 Git 添加软件包' \
            '从仓库删除软件包' \
            '在 GitHub 上同步 AUR 源' \
            '在 GitHub 上构建软件包' \
            '跟踪正在运行的构建' \
            '排查失败的构建' \
            '检查本地 PKGBUILD' \
            '检查本地软件包更新' \
            '更新本地 pacman 仓库' \
            "$install_label" \
            '查看最近的 GitHub Actions' \
            '拉取最新 main 分支' \
            "切换自动推送（当前${push_label}）" \
            '退出'
    )" || exit 0

    action_status=0
    case "$action" in
        '添加 AUR 软件包')
            add_aur_package || action_status=$?
            ;;
        '从自定义 Git 添加软件包')
            add_custom_package || action_status=$?
            ;;
        '从仓库删除软件包')
            remove_package || action_status=$?
            ;;
        '在 GitHub 上同步 AUR 源')
            sync_aur_sources || action_status=$?
            ;;
        '在 GitHub 上构建软件包')
            build_packages || action_status=$?
            ;;
        '跟踪正在运行的构建')
            track_running_build || action_status=$?
            ;;
        '排查失败的构建')
            triage_failed_builds || action_status=$?
            ;;
        '检查本地 PKGBUILD')
            check_local_packages || action_status=$?
            ;;
        '检查本地软件包更新')
            check_local_updates || action_status=$?
            ;;
        '更新本地 pacman 仓库')
            update_local_repository || action_status=$?
            ;;
        "$install_label")
            install_repository_package || action_status=$?
            ;;
        '查看最近的 GitHub Actions')
            show_recent_actions || action_status=$?
            ;;
        '拉取最新 main 分支')
            pull_main || action_status=$?
            ;;
        切换自动推送*)
            if (( push_changes == 1 )); then
                push_changes=0
            else
                push_changes=1
            fi
            continue
            ;;
        '退出')
            exit 0
            ;;
    esac

    if (( action_status != 0 )); then
        printf '\n操作失败，退出状态：%d。\n' "$action_status" >&2
    fi
    pause_after_action
done
