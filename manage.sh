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
用法：$(basename "$0") [选项] [动作代号]

不带动作代号时打开基于 fzf 的私人软件仓库管理界面。

  --no-push   启动时关闭自动 Git 推送（只影响界面里的开关初值）
  --list      列出所有动作代号（一行一个，制表符分隔说明），给脚本/补全用
  -h, --help  显示这份帮助

给了动作代号就**跳过菜单直接执行那一个动作**，例如：

  $(basename "$0") dashboard    # 仓库状态总览
  $(basename "$0") doctor       # 运行环境自检
  $(basename "$0") build        # 在 GitHub 上构建软件包（里面还会用 fzf 选包）

代号见 --list。需要选包/确认的动作照样会用 fzf 和交互式提问，所以请在终端里跑。
EOF
}

push_changes=1
action_code=''

# 动作表：`代号:函数名:菜单里显示的名字`。
#
# **这是唯一一份动作清单** —— 菜单、`--list`、直接点名执行都读它，
# 所以三边不可能对不上（以前只有菜单那一处 case，脚本没法点名执行）。
readonly -a manage_actions=(
    'dashboard:show_dashboard:仓库状态总览'
    'add-aur:add_aur_package:添加 AUR 软件包'
    'add-custom:add_custom_package:从自定义 Git 添加软件包'
    'remove:remove_package:从仓库删除软件包'
    'sync-aur:sync_aur_sources:在 GitHub 上同步 AUR 源'
    'build:build_packages:在 GitHub 上构建软件包'
    'track:track_running_build:跟踪正在运行的构建'
    'triage:triage_failed_builds:排查失败的构建'
    'check-local:check_local_packages:检查本地 PKGBUILD'
    'audit:audit_all_packages:审计全部软件包'
    'plan:show_build_plan:构建计划与 DAG'
    'parallel:run_parallel_build:并行构建（本地）'
    'timing:show_build_timing:构建时序统计'
    'repair:repair_center:修复中心'
    'doctor:run_doctor:运行环境自检（doctor）'
    'updates:check_local_updates:检查本地软件包更新'
    'update-repo:update_local_repository:更新本地 pacman 仓库'
    'install:install_repository_package:从仓库安装软件包'
    'actions:show_recent_actions:查看最近的 GitHub Actions'
    'pull:pull_main:拉取最新 main 分支'
)

run_action() {
    local wanted="$1" entry code function
    for entry in "${manage_actions[@]}"; do
        code="${entry%%:*}"
        [[ "$code" == "$wanted" ]] || continue
        function="${entry#*:}"
        function="${function%%:*}"
        "$function"
        return $?
    done
    printf '不认识的动作代号：%s\n' "$wanted" >&2
    printf '可用代号：%s --list\n' "$(basename "$0")" >&2
    return 2
}

list_actions() {
    local entry
    for entry in "${manage_actions[@]}"; do
        printf '%s\t%s\n' "${entry%%:*}" "${entry##*:}"
    done
}

while (( $# > 0 )); do
    case "$1" in
        --no-push)
            push_changes=0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --list)
            list_actions
            exit 0
            ;;
        -*)
            printf '不认识的选项：%s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$action_code" ]]; then
                printf '一次只能点名一个动作（已经给了 %s）。\n' "$action_code" >&2
                usage >&2
                exit 2
            fi
            action_code="$1"
            ;;
    esac
    shift
done

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
    --with-nth=1..
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

# 和 `select_one` 一样，但每项是 `值|显示文字`：只显示后半截，返回整行。
# 主菜单用它 —— 动作表里的代号不该出现在菜单上。
select_one_keyed() {
    local prompt="$1"
    shift

    printf '%s\n' "$@" |
        fzf "${fzf_options[@]}" \
            --delimiter='|' \
            --with-nth=2.. \
            --prompt="${prompt}> "
}

select_managed_package() {
    local selected

    selected="$(
        package_records |
            fzf "${fzf_package_options[@]}" --prompt='软件包> ' \
                --header='包名 | 版本 | 架构 | 描述（预览 PKGBUILD）'
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
            --header='包名 | 版本 | 架构 | 描述；Tab：选择  Ctrl-A：全选  Ctrl-D：取消全选' \
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
            --header='包名 | 版本 | 架构 | 描述；选择“全部 AUR 软件包”，或使用 Tab 多选' \
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
            --header='包名 | 版本 | 架构 | 描述；选择“全部软件包”，或使用 Tab 多选' \
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

audit_all_packages() {
    "${repo_root}/scripts/audit-packages.sh"
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

run_doctor() {
    "${repo_root}/scripts/doctor.sh"
}

show_build_plan() {
    local selection before after
    selection="$(
        select_one '计划范围' \
            '全部软件包（all）' \
            '与上一个提交的差异（changed）' \
            '指定软件包（逗号分隔）' \
            '取消'
    )" || return
    before=""
    after="HEAD"
    case "$selection" in
        取消) return ;;
        全部软件包*) selection="all" ;;
        与上一个提交*)
            selection="changed"
            before="$(git -C "$repo_root" rev-parse HEAD~1 2>/dev/null || echo '')"
            after="$(git -C "$repo_root" rev-parse HEAD)"
            ;;
        *)
            selection="$(prompt_value '软件包（逗号分隔）')" || return
            ;;
    esac
    python3 "${repo_root}/scripts/build-planner.py" \
        --selection "$selection" \
        --before "${before}" \
        --after "${after}" \
        --format text
    printf '\n'
    python3 "${repo_root}/scripts/build-dag.py" --format text
}

run_parallel_build() {
    local mode
    mode="$(
        select_one '并行构建' \
            '预演（只显示波次，不构建）' \
            '真实构建（容器 / 本机）' \
            '取消'
    )" || return
    case "$mode" in
        取消) return ;;
        预演*) "${repo_root}/scripts/parallel-build.sh" --dry-run ;;
        *) "${repo_root}/scripts/parallel-build.sh" ;;
    esac
}

show_build_timing() {
    local database="${repo_root}/state/timing-history.jsonl"
    if [[ ! -f "$database" ]]; then
        printf '还没有构建时序记录（%s 不存在）。\n' "$database"
        return 0
    fi
    local aggregated
    aggregated="$(mktemp)"
    python3 "${repo_root}/scripts/build-timing.py" aggregate --dir /dev/null --out /dev/null >/dev/null 2>&1 || true
    python3 - "$database" "$aggregated" <<'PY'
import json, sys
from datetime import datetime, timezone

records = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        records.append(json.loads(line))
    except json.JSONDecodeError:
        continue

grouped = {}
for record in records:
    name = record.get("package", "unknown")
    entry = grouped.setdefault(name, {"package": name, "runs": 0, "total": 0.0, "status": ""})
    entry["runs"] += 1
    entry["total"] += float(record.get("total_seconds") or 0)
    entry["status"] = record.get("status") or entry["status"]

hits = sum(int((record.get("cache") or {}).get("hits") or 0) for record in records)
misses = sum(int((record.get("cache") or {}).get("misses") or 0) for record in records)
json.dump(
    {
        "schema": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "packages": sorted(
            (
                {
                    "package": entry["package"],
                    "runs": entry["runs"],
                    "total_seconds": round(entry["total"] / max(entry["runs"], 1), 1),
                    "last_status": entry["status"],
                }
                for entry in grouped.values()
            ),
            key=lambda item: item["total_seconds"],
            reverse=True,
        ),
        "totals": {
            "packages": len(records),
            "seconds": round(sum(float(record.get("total_seconds") or 0) for record in records), 1),
            "failures": sum(1 for record in records if record.get("status") != "success"),
            "cache_hits": hits,
            "cache_misses": misses,
            "cache_hit_rate": round(hits / (hits + misses), 4) if hits + misses else None,
        },
    },
    open(sys.argv[2], "w", encoding="utf-8"),
    indent=2,
)
PY
    python3 "${repo_root}/scripts/build-timing.py" report --db "$aggregated"
    rm -f "$aggregated"
}

repair_center() {
    local mode package_name
    mode="$(
        select_one '修复中心' \
            '分析构建日志' \
            '对指定软件包尝试自动修复（预演）' \
            '查看修复历史' \
            '取消'
    )" || return
    case "$mode" in
        取消) return ;;
        分析构建日志)
            local log
            printf '构建日志路径：'
            read -r log || return
            [[ -f "$log" ]] || { printf '日志不存在：%s\n' "$log" >&2; return 1; }
            package_name="$(prompt_value '软件包名')" || return
            python3 "${repo_root}/scripts/analyze-build-failure.py" \
                --package "$package_name" --log "$log"
            ;;
        对指定软件包*)
            local failure
            package_name="$(select_managed_package)" || return
            printf 'failure.json 路径：'
            read -r failure || return
            [[ -f "$failure" ]] || { printf '文件不存在：%s\n' "$failure" >&2; return 1; }
            bash "${repo_root}/scripts/auto-repair.sh" \
                --package "$package_name" \
                --failure "$failure" \
                --level "${AUTO_FIX_LEVEL:-1}" \
                --json
            ;;
        查看修复历史)
            local history="${repo_root}/state/repair-history.jsonl"
            if [[ -f "$history" ]]; then
                python3 - "$history" <<'PY'
import json, sys

lines = [line for line in open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines() if line.strip()]
for line in lines[-20:]:
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    print(
        f"{record.get('timestamp', '?'):<21}{record.get('package', '?'):<26}"
        f"{record.get('strategy', '?'):<20}{record.get('status', '?')}"
    )
PY
            else
                printf '还没有修复历史。\n'
            fi
            ;;
    esac
}

show_dashboard() {
    local branch package_count aur_count dirty
    local recent="-" running="-" failed="-"

    branch="$(git -C "$repo_root" branch --show-current)"
    package_count="$(managed_packages | wc -l)"
    aur_count="$(aur_package_records | wc -l)"
    if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then dirty='有未提交修改'; else dirty='工作区干净'; fi
    if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
        recent="$(gh run list --repo "$github_repository" --limit 1 --json status,conclusion --jq '.[0] | (.conclusion // .status)' 2>/dev/null || echo '-')"
        running="$(gh run list --repo "$github_repository" --limit 30 --json status --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null || echo '-')"
        failed="$(gh run list --repo "$github_repository" --limit 30 --json conclusion --jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo '-')"
    fi

    printf '\n'
    printf '╭────────────────────────── 仓库状态 ──────────────────────────╮\n'
    printf '│ GitHub       %-46s │\n' "$github_repository"
    printf '│ 分支         %-46s │\n' "${branch:-游离状态}"
    printf '│ 工作区       %-46s │\n' "$dirty"
    printf '│ 软件包       %-46s │\n' "$package_count"
    printf '│ AUR 管理     %-46s │\n' "$aur_count"
    printf '│ 最近 Actions %-46s │\n' "$recent"
    printf '│ 运行中       %-46s │\n' "$running"
    printf '│ 最近失败     %-46s │\n' "$failed"

    local timing_records=0 repair_records=0
    # 注意别写成 `wc -l <文件 2>/dev/null`：那个 `2>/dev/null` 管的是 wc，
    # 而「文件不存在」是 **shell 的重定向**报出来的，照样漏到屏幕上
    # （实测 dashboard 会多两行「没有那个文件或目录」）。
    if [[ -f "$repo_root/state/timing-history.jsonl" ]]; then
        timing_records="$(wc -l <"$repo_root/state/timing-history.jsonl")"
    fi
    if [[ -f "$repo_root/state/repair-history.jsonl" ]]; then
        repair_records="$(wc -l <"$repo_root/state/repair-history.jsonl")"
    fi
    printf '│ 构建时序记录 %-46s │\n' "$timing_records 条"
    printf '│ 自动修复记录 %-46s │\n' "$repair_records 条"
    printf '╰──────────────────────────────────────────────────────────────╯\n'
}

# 点名执行：跳过菜单，直接跑那一个动作（给脚本和工具箱用）。
if [[ -n "$action_code" ]]; then
    run_action "$action_code"
    exit $?
fi

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

    # 菜单项由上面的动作表生成（`代号|菜单文字`），所以加一个动作只改那一处。
    menu_items=()
    for action_entry in "${manage_actions[@]}"; do
        action_menu_code="${action_entry%%:*}"
        action_menu_label="${action_entry##*:}"
        # 「从仓库安装」那一条要带上仓库名，才是给用户看的
        if [[ "$action_menu_code" == 'install' ]]; then
            action_menu_label="$install_label"
        fi
        menu_items+=("${action_menu_code}|${action_menu_label}")
    done
    menu_items+=("toggle-push|切换自动推送（当前${push_label}）")
    menu_items+=("quit|退出")

    action="$(
        select_one_keyed \
            "${github_repository} | 分支 ${branch:-游离状态} | ${package_count} 个软件包 | ${repository_state} | 自动推送 ${push_label}" \
            "${menu_items[@]}"
    )" || exit 0

    action_code_selected="${action%%|*}"
    action_status=0
    case "$action_code_selected" in
        toggle-push)
            if (( push_changes == 1 )); then
                push_changes=0
            else
                push_changes=1
            fi
            continue
            ;;
        quit)
            exit 0
            ;;
        *)
            run_action "$action_code_selected" || action_status=$?
            ;;
    esac

    if (( action_status != 0 )); then
        printf '\n操作失败，退出状态：%d。\n' "$action_status" >&2
    fi
    pause_after_action
done
