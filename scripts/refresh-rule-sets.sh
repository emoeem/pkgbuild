#!/usr/bin/env bash
# 每天检查 sing-box-rule-sets 的远程源是否有变化：下载校验可达性与内容合法性，
# 哈希记录在 .source-hashes 里比对，有变化就更新 pkgver（日期）并生成 .SRCINFO，
# 供 CI 提交后自动重建包。没有变化则什么都不做（退出码 0）。
#
# PKGBUILD 里的 sha256sums 全部是 SKIP（上游日更，钉哈希必然在两次 refresh
# 之间漂移，2026-10-11 anti-ad.txt 实测），所以本脚本不再改写哈希数组，
# 只负责：可达性/合法性校验、变化检测、日期版本化。
#
# 用法：scripts/refresh-rule-sets.sh [--check]
#   --check  只报告是否有变化，不写文件（供本地预览）
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly repo_root
readonly pkg_dir="${repo_root}/packages/sing-box-rule-sets"
readonly pkgbuild="${pkg_dir}/PKGBUILD"
readonly srcinfo="${pkg_dir}/.SRCINFO"
CHECK_ONLY=0
# 不认识的参数必须拒绝：这个脚本会改写 PKGBUILD 并触发发布，拼错参数
# 静默跑下去比直接失败危险得多。
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
        printf 'usage: %s [--check]\n' "${0##*/}"
        printf '  --check  只报告是否有变化，不写文件\n'
        exit 0
        ;;
    *)
        printf 'unknown argument: %s (supported: --check)\n' "$1" >&2
        exit 2
        ;;
esac

readonly -a urls=(
    "https://anti-ad.net/adguard.txt"
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs"
    "https://raw.githubusercontent.com/HenryChiao/mihomo_yamls/ruleset/singbox/version4/cncidr.srs"
    "https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblocksingbox.srs"
    # 顺序必须与 PKGBUILD 里远程 source 的顺序一致
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.srs"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.srs"
)
# 内容基线的落点：哈希不再进 PKGBUILD（那里是 SKIP），但「上游变了没有」
# 仍然要可审计地记录在仓库里，--check 与无人值守运行才有可比对象。
readonly hashes_file="${pkg_dir}/.source-hashes"

[[ -f "$pkgbuild" ]] || { printf 'missing %s\n' "$pkgbuild" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf 'Downloading %d rule-set source(s)...\n' "${#urls[@]}"
new_sums=()
for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    out="${work}/src${i}"
    if ! curl --fail --silent --show-error --location \
            --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 \
            --max-time 600 -o "$out" "$url"; then
        printf 'download failed: %s\n' "$url" >&2
        exit 1
    fi
    [[ -s "$out" ]] || { printf 'empty download: %s\n' "$url" >&2; exit 1; }
    # SKIP 意味着 makepkg 不再是完整性关卡，这里就是唯一关卡：远程 .srs 必须
    # 带 SRS magic，AdGuard 文本必须有实质内容（万行级），防止 404 页面或
    # 截断响应被当成合法规则集打进包里。
    case "$url" in
        *.srs)
            [[ "$(head -c 3 "$out")" == "SRS" ]] ||
                { printf 'not a sing-box rule-set (bad magic): %s\n' "$url" >&2; exit 1; }
            ;;
        *)
            (( $(wc -l < "$out") >= 10000 )) ||
                { printf 'suspiciously small rule list: %s\n' "$url" >&2; exit 1; }
            ;;
    esac
    new_sums+=("$(sha256sum "$out" | cut -d' ' -f1)")
    printf '  %s  %s\n' "${new_sums[$i]:0:12}" "$url"
done

mapfile -t old_sums < <(cat "$hashes_file" 2>/dev/null || true)

changed=0
for ((i = 0; i < ${#urls[@]}; i++)); do
    if [[ "${old_sums[$i]:-}" != "${new_sums[$i]}" ]]; then
        printf 'changed: source %d\n  old %s\n  new %s\n' "$i" "${old_sums[$i]:-<none>}" "${new_sums[$i]}"
        changed=1
    fi
done

if (( ! changed )); then
    printf 'No rule-set source changed; nothing to do.\n'
    exit 0
fi
if (( CHECK_ONLY )); then
    printf 'Changes detected (--check: not modifying anything).\n'
    exit 0
fi

new_date="$(date -u +%Y%m%d)"
python3 - "$pkgbuild" "$new_date" <<'PY'
import re, sys, pathlib
path, date_ = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
# sha256sums 全部是 SKIP，这里只做日期版本化
s = re.sub(r"^pkgver=.*$", f"pkgver={date_}", s, count=1, flags=re.M)
s = re.sub(r"^pkgrel=\d+$", "pkgrel=1", s, count=1, flags=re.M)
p.write_text(s, encoding="utf-8")
print(f"PKGBUILD updated: pkgver={date_}")
PY

printf '%s\n' "${new_sums[@]}" > "$hashes_file"
printf 'Updated %s\n' "${hashes_file#"$repo_root"/}"

if command -v makepkg >/dev/null 2>&1; then
    ( cd "$pkg_dir" && BUILDDIR="$(mktemp -d)" SRCDEST="$work" PKGDEST="$work" LOGDEST="$work" makepkg --printsrcinfo > "$srcinfo" )
else
    # 调度 runner（ubuntu）没有 makepkg：pkgver/pkgrel 是标量，直接改写；
    # sha256sums 保持 SKIP，与 PKGBUILD 一致——一旦写出真实哈希就会被
    # builder 容器里的 check-package.sh 正确拦下（2026-10-05 实测翻过车）。
    python3 - "$srcinfo" "$new_date" <<'PY'
import re, sys, pathlib
path, date_ = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
s = re.sub(r"^(\tpkgver = ).*$", rf"\g<1>{date_}", s, count=1, flags=re.M)
s = re.sub(r"^(\tpkgrel = ).*$", r"\g<1>1", s, count=1, flags=re.M)
p.write_text(s, encoding="utf-8")
PY
fi
printf 'Updated %s\n' "${srcinfo#"$repo_root"/}"
