#!/usr/bin/env bash
# Repository install test: the last gate before publishing.
#
# Everything up to here has only proven that a package *file* is consistent.
# This installs the freshly built packages from the repository into a throwaway
# container, resolving their dependencies from that same repository, and then
# runs runtime verification against the installed result.
#
# A repository that cannot satisfy its own packages is not published.
#
# Runs inside the CachyOS/Arch container. Inputs are paths so it can also be
# exercised by hand:
#
#   /repository   the repository directory (db + files db + packages)
#   /incoming     freshly built packages, one directory per package base
#
# Environment:
#   REPOSITORY_NAME      pacman repository name (default: emoeem)
#   INSTALL_TEST_ALL=1   also install packages that pull a very large closure
#   INSTALL_TEST_SKIP    comma separated package names to skip
set -Eeuo pipefail

# Tool output (pacman, ldd, readelf) is parsed below; a localized label would
# turn a check into a silent no-op.
export LC_ALL=C

repository_dir="${REPOSITORY_DIR:-/repository}"
incoming_dir="${INCOMING_DIR:-/incoming}"
repository_name="${REPOSITORY_NAME:-emoeem}"
workspace_dir="${WORKSPACE_DIR:-/workspace}"
install_all="${INSTALL_TEST_ALL:-0}"
skip_list="${INSTALL_TEST_SKIP:-}"

# Packages whose install closure is too large for the publication window; they
# are still covered by the per-package runtime verification in the build job.
heavy_default="ffmpeg-full daed-emo sing-box-ebpf scx-scheds-git vapoursynth-plugin-mlrt-ncnn-runtime"

[[ -d "$repository_dir" ]] || { printf 'no repository directory: %s\n' "$repository_dir" >&2; exit 2; }
[[ -d "$incoming_dir" ]] || { printf 'no incoming directory: %s\n' "$incoming_dir" >&2; exit 2; }

if [[ ! -f "$repository_dir/$repository_name.db" ]]; then
    printf 'repository database is missing: %s/%s.db\n' "$repository_dir" "$repository_name" >&2
    exit 1
fi

# --- wire the repository into pacman so dependencies resolve from it --------
# PACMAN_CONF 覆盖点默认即 /etc/pacman.conf;测试用它指到临时文件。
pacman_conf="${PACMAN_CONF:-/etc/pacman.conf}"
if ! grep -qx "[$repository_name]" "$pacman_conf"; then
    trimmed="$(mktemp)"
    awk -v name="$repository_name" '
        $0 == "[" name "]" {skip=1; next}
        skip && /^\[/ {skip=0}
        !skip {print}
    ' "$pacman_conf" >"$trimmed"
    {
        printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$repository_name" "$repository_dir"
        cat "$trimmed"
    } >"$pacman_conf"
    rm -f "$trimmed"
fi

printf 'Refreshing package databases...\n'
pacman -Syu --noconfirm >/dev/null

mapfile -t selected_package_records < <(bash "$workspace_dir/scripts/select-incoming-packages.sh" "$incoming_dir")
if (( ${#selected_package_records[@]} == 0 )); then
    printf 'no valid incoming package files found under %s\n' "$incoming_dir" >&2
    exit 1
fi

declare -A chosen_path=()
for record in "${selected_package_records[@]}"; do
    name="${record%%$'\t'*}"
    package_file="${record#*$'\t'}"
    [[ -n "$name" && -f "$package_file" ]] || continue
    chosen_path["$name"]="$package_file"
done

selected=()
skipped=()
# 注意必须是 [@]：带引号的 [*] 会把所有键按 IFS 首字符拼成单个词，待测包
# ≥2 时 name 就成了 "pkg-a pkg-b"，在 set -u 下 chosen_path[$name] 直接
# unbound 崩溃 —— 这正是多包发布必挂、单包发布侥幸存活的原因。
for name in "${!chosen_path[@]}"; do
    [[ -n "$name" ]] || continue
    if [[ ",${skip_list}," == *",$name,"* ]]; then
        skipped+=("$name (explicitly skipped)")
        continue
    fi
    if [[ "$install_all" != "1" && " $heavy_default " == *" $name "* ]]; then
        skipped+=("$name (heavy install closure; set INSTALL_TEST_ALL=1 to include)")
        continue
    fi
    selected+=("${chosen_path[$name]}")
done

if (( ${#selected[@]} == 0 )); then
    printf 'Nothing to install-test.\n'
    for entry in "${skipped[@]}"; do
        printf '  skipped: %s\n' "$entry"
    done
    exit 0
fi

printf 'Install test for %d package(s):\n' "${#selected[@]}"
printf '  %s\n' "${selected[@]}"
for entry in "${skipped[@]}"; do
    printf '  skipped: %s\n' "$entry"
done

printf 'Installing from the repository...\n'
install_log="$(mktemp)"
trap 'rm -f "$install_log"' EXIT
if ! pacman -U --noconfirm --needed --overwrite '*' "${selected[@]}" 2>&1 | tee "$install_log"; then
    # 仓库必须满足「自己的」闭包。依赖里来自外部的包(AUR 等,构建期由 yay
    # 解析,如 linuxqq-wayland-fix-git 的 linuxqq)在 clean 容器里天然不可
    # 解析,不算仓库缺陷——对这类缺失按已安装假设重试。缺的若是本仓库自己
    # 的包,那是真闸门,必须失败(fail closed)。
    mapfile -t missing < <(sed -n 's/^warning: cannot resolve "\([^"]*\)", a dependency of.*/\1/p' "$install_log" | sort -u)
    declare -a assume_args=() external=() internal=()
    for dep in "${missing[@]}"; do
        [[ -n "$dep" ]] || continue
        dep_name="${dep%%[<>=]*}"
        if pacman -Sl "$repository_name" 2>/dev/null | awk '{print $2}' | grep -qxF "$dep_name"; then
            internal+=("$dep")
        else
            external+=("$dep_name")
            assume_args+=("--assume-installed=$dep_name")
        fi
    done
    if (( ${#internal[@]} > 0 )); then
        printf 'FAIL: unresolvable dependencies pointing at this repository: %s\n' "${internal[*]}" >&2
        exit 1
    fi
    if (( ${#external[@]} == 0 )); then
        printf 'FAIL: the repository could not install its own packages (no unresolvable dependency reported).\n' >&2
        exit 1
    fi
    printf 'External dependencies absent from every configured repository; assuming installed: %s\n' "${external[*]}"
    if ! pacman -U --noconfirm --needed --overwrite '*' "${assume_args[@]}" "${selected[@]}" 2>&1 | tee "$install_log"; then
        printf 'FAIL: the repository could not install its own packages.\n' >&2
        exit 1
    fi
fi

# --- runtime verification against the installed result ----------------------
names=()
for package_file in "${selected[@]}"; do
    info="$(bsdtar -xOf "$package_file" .PKGINFO)"
    name="$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$info")"
    [[ -n "$name" ]] && names+=("$name")
done

status=0
for name in "${names[@]}"; do
    if ! bash "$workspace_dir/scripts/runtime-verify.sh" --package "$name"; then
        status=1
    fi
done

if (( status != 0 )); then
    printf 'FAIL: runtime verification failed for an installed package.\n' >&2
    exit 1
fi

printf 'Repository install test passed for %d package(s).\n' "${#names[@]}"
