#!/usr/bin/env bash
# 每天检查 sing-box-rule-sets 的远程源是否有变化：下载校验可达性与内容合法性，
# 哈希记录在 .source-hashes 里比对，有变化就更新 pkgver（日期）并生成 .SRCINFO，
# 供 CI 提交后自动重建包。没有变化则什么都不做（退出码 0）。
#
# 刷新阶段校验每份远程源并记录 SHA-256；同一组哈希同时写入 PKGBUILD 的
# sha256sums，让 makepkg 在构建下载阶段再次验证。若上游在刷新与构建之间变化，
# 构建会失败关闭，而不是把未经记录的新内容打进软件包。
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
# .source-hashes 是六份远程源的审计基线；PKGBUILD sha256sums 还包含三份
# 仓库内源文件的哈希，数组顺序必须与 source 完全一致。
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
    # refresh 阶段先检查内容，makepkg 再用相同 SHA-256 校验下载：远程 .srs 必须
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

source_changed=0
for ((i = 0; i < ${#urls[@]}; i++)); do
    if [[ "${old_sums[$i]:-}" != "${new_sums[$i]}" ]]; then
        printf 'changed: source %d\n  old %s\n  new %s\n' "$i" "${old_sums[$i]:-<none>}" "${new_sums[$i]}"
        source_changed=1
    fi
done

# The final three source entries are repository-maintained files; makepkg must
# verify them too. The checksum order mirrors PKGBUILD's source array exactly.
expected_sums=(
    "${new_sums[@]}"
    "$(sha256sum "$pkg_dir/must-direct.json" | cut -d' ' -f1)"
    "$(sha256sum "$pkg_dir/ads-extra.json" | cut -d' ' -f1)"
    "$(sha256sum "$pkg_dir/LICENSE-anti-AD" | cut -d' ' -f1)"
)

# Determine whether this is initial SKIP migration, an upstream change, or a
# change to one of the local source files.
checksum_state="$(python3 - "$pkgbuild" "${expected_sums[@]}" <<'PY'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"^sha256sums=\(\s*(.*?)^\)", s, re.M | re.S)
current = re.findall(r"['\"]([^'\"]+)['\"]", m.group(1)) if m else []
expected = sys.argv[2:]
if current == expected:
    print("match")
elif any(value == "SKIP" for value in current):
    print("skip")
elif len(current) == len(expected) and current[-3:] != expected[-3:]:
    print("local-changed")
else:
    print("mismatch")
PY
)"

if (( ! source_changed )) && [[ "$checksum_state" == match ]]; then
    printf 'No rule-set source or checksum change; nothing to do.\n'
    exit 0
fi
if [[ "$checksum_state" == local-changed ]]; then
    printf 'Local rule-set source changed; package release will be incremented.\n'
fi
if (( CHECK_ONLY )); then
    printf 'Changes detected (--check: not modifying anything).\n'
    exit 0
fi

new_date="$(date -u +%Y%m%d)"
python3 - "$pkgbuild" "$new_date" "$source_changed" "$checksum_state" "${expected_sums[@]}" <<'PY'
import re, sys, pathlib
path, date_, source_changed, checksum_state = sys.argv[1:5]
checksums = sys.argv[5:]
p = pathlib.Path(path)
s = p.read_text(encoding="utf-8")
if source_changed == "1":
    current_ver = re.search(r"^pkgver=(.*)$", s, re.M)
    if current_ver and current_ver.group(1) == date_:
        m = re.search(r"^pkgrel=(\d+)$", s, re.M)
        if not m:
            raise SystemExit("unable to find pkgrel in PKGBUILD")
        s = s[:m.start(1)] + str(int(m.group(1)) + 1) + s[m.end(1):]
    else:
        s = re.sub(r"^pkgver=.*$", f"pkgver={date_}", s, count=1, flags=re.M)
        s = re.sub(r"^pkgrel=\d+$", "pkgrel=1", s, count=1, flags=re.M)
elif checksum_state == "local-changed":
    m = re.search(r"^pkgrel=(\d+)$", s, re.M)
    if not m:
        raise SystemExit("unable to find pkgrel in PKGBUILD")
    s = s[:m.start(1)] + str(int(m.group(1)) + 1) + s[m.end(1):]
block = "sha256sums=(\n" + "".join(f"    '{value}'\n" for value in checksums) + ")"
s, count = re.subn(r"^sha256sums=\(\s*.*?^\)", lambda _: block, s, count=1, flags=re.M | re.S)
if count != 1:
    raise SystemExit("unable to replace sha256sums array")
p.write_text(s, encoding="utf-8")
print(f"PKGBUILD checksum array updated ({len(checksums)} sources)")
if source_changed == "1":
    print(f"PKGBUILD updated for source change on {date_}")
elif checksum_state == "local-changed":
    print("PKGBUILD pkgrel incremented for local source change")
PY

if command -v makepkg >/dev/null 2>&1; then
    mkdir -p "$work/build"
    ( cd "$pkg_dir" && BUILDDIR="$work/build" SRCDEST="$work" PKGDEST="$work" LOGDEST="$work" makepkg --printsrcinfo > "$srcinfo" )
else
    # The scheduled Ubuntu runner has no makepkg; mirror metadata and checksums
    # into .SRCINFO so the next CachyOS check can validate the same source list.
    python3 - "$srcinfo" "$new_date" "$source_changed" "$checksum_state" "${expected_sums[@]}" <<'PY'
import re, sys, pathlib
path, date_, source_changed, checksum_state = sys.argv[1:5]
checksums = sys.argv[5:]
p = pathlib.Path(path)
lines = p.read_text(encoding="utf-8").splitlines()
if source_changed == "1":
    current_ver = next((line.split(" = ", 1)[1] for line in lines if line.startswith("\tpkgver = ")), "")
    if current_ver == date_:
        for i, line in enumerate(lines):
            if line.startswith("\tpkgrel = "):
                lines[i] = re.sub(r"^(\tpkgrel = )(\d+)$", lambda m: m.group(1) + str(int(m.group(2)) + 1), line)
                break
    else:
        lines = [re.sub(r"^(\tpkgver = ).*$", rf"\g<1>{date_}", line) if line.startswith("\tpkgver = ") else line for line in lines]
        lines = [re.sub(r"^(\tpkgrel = ).*$", r"\g<1>1", line) if line.startswith("\tpkgrel = ") else line for line in lines]
elif checksum_state == "local-changed":
    for i, line in enumerate(lines):
        if line.startswith("\tpkgrel = "):
            lines[i] = re.sub(r"^(\tpkgrel = )(\d+)$", lambda m: m.group(1) + str(int(m.group(2)) + 1), line)
            break
indices = [i for i, line in enumerate(lines) if line.startswith("\tsha256sums = ")]
if len(indices) != len(checksums):
    raise SystemExit(f".SRCINFO has {len(indices)} sha256sums entries; expected {len(checksums)}")
for i, value in zip(indices, checksums):
    lines[i] = f"\tsha256sums = {value}"
p.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
fi
printf 'Updated %s\n' "${srcinfo#"$repo_root"/}"
printf '%s\n' "${new_sums[@]}" > "$hashes_file"
printf 'Updated %s\n' "${hashes_file#"$repo_root"/}"
