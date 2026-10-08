#!/usr/bin/env bash
# 每天检查 sing-box-rule-sets 的远程源是否有变化，有变化就更新 PKGBUILD（pkgver 用日期 + 新 sha256）
# 并生成 .SRCINFO，供 CI 提交后自动重建包。没有变化则什么都不做（退出码 0）。
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
    # 顺序必须与 PKGBUILD 里远程 source 的顺序一致（前 N 行换新哈希，SKIP 的本地源原样保留）
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.srs"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.srs"
)

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
    new_sums+=("$(sha256sum "$out" | cut -d' ' -f1)")
    printf '  %s  %s\n' "${new_sums[$i]:0:12}" "$url"
done

# 取出 PKGBUILD 里当前的远程源 sha256sums（个数 = urls 的个数，别写死）
mapfile -t old_sums < <(awk -F"'" '/^sha256sums=\(/{f=1;next} f&&/^\)/{exit} f&&/\x27[0-9a-f]{64}\x27/{gsub(/[^0-9a-f]/,"");print}' "$pkgbuild" | head -n "${#urls[@]}")
old_sums=("${old_sums[@]:0:${#urls[@]}}")

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
python3 - "$pkgbuild" "$new_date" "${new_sums[@]}" <<'PY'
import re, sys, pathlib
path, date_, *sums = sys.argv[1:]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
s = re.sub(r"^pkgver=.*$", f"pkgver={date_}", s, count=1, flags=re.M)
s = re.sub(r"^pkgrel=\d+$", "pkgrel=1", s, count=1, flags=re.M)
m = re.search(r"sha256sums=\(\n(.*?)\n\)", s, flags=re.S)
lines = [line for line in m.group(1).splitlines() if line.strip()]
# 前 len(sums) 行是本脚本重新计算的远程源；其余行（本地源，真实哈希或
# SKIP）原样保留。旧的实现按 SKIP 出现次数补尾，本地源一旦改用真实
# 哈希就会把数组截短、让 makepkg 报「完整性校验缺失」。
tail = lines[len(sums):]
body = "".join(f"    '{v}'\n" for v in sums)
if tail:
    body += "\n".join(tail) + "\n"
s = s[:m.start()] + "sha256sums=(\n" + body + ")" + s[m.end():]
p.write_text(s, encoding="utf-8")
print(f"PKGBUILD updated: pkgver={date_}")
PY

if command -v makepkg >/dev/null 2>&1; then
    ( cd "$pkg_dir" && BUILDDIR="$(mktemp -d)" SRCDEST="$work" PKGDEST="$work" LOGDEST="$work" makepkg --printsrcinfo > "$srcinfo" )
else
    # 调度 runner（ubuntu）没有 makepkg：pkgver/pkgrel 是标量，sha256sums
    # 是多值键——前 N 行（N = 远程源个数）换成新哈希，本地源（SKIP）原样
    # 保留。不补这个的话 PKGBUILD 与 .SRCINFO 的哈希会错开，被 builder
    # 容器里的 check-package.sh 正确拦下（2026-10-05 实测翻过车）。
    python3 - "$srcinfo" "$new_date" "${new_sums[@]}" <<'PY'
import re, sys, pathlib
path, date_, *sums = sys.argv[1:]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
s = re.sub(r"^(\tpkgver = ).*$", rf"\g<1>{date_}", s, count=1, flags=re.M)
s = re.sub(r"^(\tpkgrel = ).*$", r"\g<1>1", s, count=1, flags=re.M)
state = {"i": 0}

def repl(m):
    i = state["i"]
    state["i"] += 1
    return f"\tsha256sums = {sums[i]}" if i < len(sums) else m.group(0)

s = re.sub(r"^\tsha256sums = .*$", repl, s, flags=re.M)
p.write_text(s, encoding="utf-8")
PY
fi
printf 'Updated %s\n' "${srcinfo#"$repo_root"/}"
