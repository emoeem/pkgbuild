#!/usr/bin/env bash
set -Eeuo pipefail

# Force the C locale: the checks below parse tool output (readelf, pacman,
# ldd, ...) whose labels are localized, and a translated label silently
# turns the check into a no-op instead of failing loudly.
export LC_ALL=C

repo_dir="${1:-}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$repo_dir" ]] || { echo "usage: $0 <published-repo-dir> [repo-root] [stale-file]" >&2; exit 2; }
stale_file="${3:-}"

if [[ -n "${LOCAL_REPO_DIR:-}" ]]; then
    local_copy="$(mktemp -d)"
    trap 'rm -rf "$local_copy"' EXIT
    cp -a "${LOCAL_REPO_DIR}/." "$local_copy/"
    shopt -s nullglob
    local_packages=("$local_copy"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#local_packages[@]} > 0 )); then
        repo-add --remove "$local_copy/emoeem.db.tar.gz" "${local_packages[@]}" >/dev/null
        printf '[emoeem]\nSigLevel = Never\nServer = file://%s\n' "$local_copy" > /tmp/emo-repo.conf
        awk '/^\[emoeem\]$/{skip=1;next} skip && /^\[/{skip=0} !skip{print}' /etc/pacman.conf >> /tmp/emo-repo.conf
        cat /tmp/emo-repo.conf > /etc/pacman.conf
    fi
fi

strip_dep() { printf '%s' "$1" | sed -E 's/[<>=].*$//'; }
recorded_version() {
    local buildinfo="$1" name="$2"
    awk -F ' = ' -v n="$name" '$1 == "installed" && $2 ~ ("^" n "-") {v=$2} END {if(v) print v}' "$buildinfo" |
        sed -E 's/-[^-]+$//' | sed -E "s/^${name}-//"
}
current_version() { pacman -Si "$1" 2>/dev/null | awk -F ': +' '$1 == "Version" {print $2; exit}'; }

packages=0
compared=0
unresolved=0
stale=0

for pkg in "$repo_dir"/*.pkg.tar.zst; do
    [[ -e "$pkg" ]] || continue
    name="$(bsdtar -xOf "$pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    buildinfo="$(mktemp)"; bsdtar -xOf "$pkg" .BUILDINFO > "$buildinfo"
    src="${root}/packages/${name}/.SRCINFO"
    [[ -f "$src" ]] || { rm -f "$buildinfo"; continue; }
    packages=$((packages + 1))
    while IFS= read -r raw; do
        dep="$(strip_dep "$raw")"; [[ -n "$dep" && "$dep" != *.so* ]] || continue
        old="$(recorded_version "$buildinfo" "$dep")"; new="$(current_version "$dep")"
        # 没记录版本的依赖无法比较；有记录但查不到当前版本的依赖说明
        # pacman 数据库没同步，必须单独计数，否则整轮扫描会静默空转。
        [[ -n "$old" ]] || continue
        compared=$((compared + 1))
        if [[ -z "$new" ]]; then
            unresolved=$((unresolved + 1))
            continue
        fi
        if [[ "$old" != "$new" ]]; then
            stale=$((stale + 1))
            printf 'STALE %s: direct dependency %s changed %s -> %s\n' "$name" "$dep" "$old" "$new"
            [[ -n "$stale_file" ]] && printf '%s\n' "$name" >> "$stale_file"
        fi
    done < <(awk -F ' = ' '$1 ~ /^\t(depends|makedepends|checkdepends)$/ {print $2}' "$src")
    rm -f "$buildinfo"
done

# 这一行是给工作流断言用的：干净时也必须有输出，否则「检测器崩了」和
# 「确实没有漂移」在日志里长得一模一样 —— 这正是 openvino SONAME 漂移
# 没能被及时拦下的原因之一。
printf 'SUMMARY packages=%d compared=%d stale=%d unresolved=%d\n' \
    "$packages" "$compared" "$stale" "$unresolved"

if (( compared == 0 )); then
    printf 'Nothing could be compared: the pacman databases are probably not synced (run pacman -Syu first) or no published package records dependency versions.\n' >&2
    printf 'Refusing to report "no drift" from an incomplete scan.\n' >&2
    exit 3
fi

if (( unresolved > 0 )); then
    printf 'WARNING: %d dependency version(s) could not be resolved against the current repositories; drift may be under-reported.\n' \
        "$unresolved" >&2
fi
