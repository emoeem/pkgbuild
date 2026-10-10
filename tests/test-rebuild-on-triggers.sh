#!/usr/bin/env bash
# .rebuild-on（逐包声明式重建触发）的机制测试：
#
#   1. scripts/list-rebuild-triggers.sh 解析 packages/*/.rebuild-on；坏行必须报错
#      而不是被跳过（静默跳过等于让检测范围悄悄缩小）。
#   2. scripts/check-elf-needed.sh 的两个附属模式：
#        --list-needed    产物里所有 NEEDED 名字
#        --require-needed 声明的 soname 必须真的出现在 NEEDED 里（过期豁免要报错）
#   3. 声明 → provider 集合 → ELF 检查 的效果：声明过的包放行，没声明的包照样报缺库。
set -Eeuo pipefail
export LC_ALL=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

checks=0
failures=0
pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf 'FAIL %s\n' "$1"; }

assert_eq() { # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1: expected [$2], got [$3]"
    fi
}

assert_contains() { # <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1: [$3] not in [$2]"
    fi
}

lister="$root/scripts/list-rebuild-triggers.sh"
check_elf="$root/scripts/check-elf-needed.sh"

# -- 1. 声明文件的解析 --------------------------------------------------------
mkdir -p "$tmp/packages/first" "$tmp/packages/second" "$tmp/empty"
cat > "$tmp/packages/first/.rebuild-on" <<'DECLARATIONS'
# 注释和空行会被忽略
soname libshine.so.3 shine

package linuxqq
DECLARATIONS
printf 'package alpha\n' > "$tmp/packages/second/.rebuild-on"

expected="$(printf 'soname\tfirst\tlibshine.so.3\tshine\npackage\tfirst\tlinuxqq\npackage\tsecond\talpha')"
assert_eq "解析全部声明" "$expected" "$(bash "$lister" "$tmp/packages")"
assert_eq "只列一个包的声明" "$(printf 'package\tsecond\talpha')" \
    "$(bash "$lister" "$tmp/packages" second)"
assert_eq "没有 .rebuild-on 时输出为空" "" "$(bash "$lister" "$tmp/empty")"

printf 'container some/image:latest\n' > "$tmp/packages/second/.rebuild-on"
if out="$(bash "$lister" "$tmp/packages" 2>&1)"; then
    fail "未知触发类型必须报错"
else
    pass "未知触发类型必须报错"
fi
assert_contains "未知触发类型的报错文本" "$out" "unknown trigger kind"

printf 'soname libshine.so.3\n' > "$tmp/packages/second/.rebuild-on"
if out="$(bash "$lister" "$tmp/packages" 2>&1)"; then
    fail "soname 缺 provider 必须报错"
else
    pass "soname 缺 provider 必须报错"
fi
assert_contains "soname 缺 provider 的报错文本" "$out" 'expected `soname <soname> <provider>`'

printf 'package alpha\n' > "$tmp/packages/second/.rebuild-on"

# -- 2/3. 声明与 ELF 检查联动 -------------------------------------------------
mkdir -p "$tmp/elf/lib" "$tmp/elf/app"
cat > "$tmp/elf/lib/fixture.c" <<'SRC'
int fixture_value(void) { return 42; }
SRC
cc -fPIC -shared "$tmp/elf/lib/fixture.c" \
    -Wl,-soname,libfixture.so.999 -o "$tmp/elf/lib/libfixture.so.999"
ln -s libfixture.so.999 "$tmp/elf/lib/libfixture.so"
cat > "$tmp/elf/app/main.c" <<'SRC'
extern int fixture_value(void);
int main(void) { return fixture_value() == 42 ? 0 : 1; }
SRC
cc "$tmp/elf/app/main.c" -L"$tmp/elf/lib" -Wl,-rpath,'$ORIGIN/../lib' \
    -lfixture -o "$tmp/elf/app/consumer"

# 仓库/容器能提供的名字里没有 libfixture.so.999 —— 这就是没有声明时那个包看到的世界。
printf 'libc.so.6\n' > "$tmp/providers-bare"
# 声明过的包在自己的 provider 集合里额外拿到声明的名字。
printf 'libc.so.6\nlibfixture.so.999\n' > "$tmp/providers-declared"

if out="$(bash "$check_elf" "$tmp/elf" "$tmp/providers-bare")"; then
    fail "没有声明时必须报出缺的 soname"
else
    pass "没有声明时必须报出缺的 soname"
fi
assert_contains "报出的 soname 名字" "$out" "libfixture.so.999"
if bash "$check_elf" "$tmp/elf" "$tmp/providers-declared"; then
    pass "声明之后同一个产物通过"
else
    fail "声明之后同一个产物通过"
fi

printf 'libfixture.so.999\n' > "$tmp/declared"
if bash "$check_elf" --require-needed "$tmp/elf" "$tmp/declared"; then
    pass "--require-needed 接受产物里真实存在的 soname"
else
    fail "--require-needed 接受产物里真实存在的 soname"
fi

printf 'libfixture.so.998\n' > "$tmp/declared-stale"
if out="$(bash "$check_elf" --require-needed "$tmp/elf" "$tmp/declared-stale")"; then
    fail "--require-needed 必须拒绝过期声明"
else
    pass "--require-needed 必须拒绝过期声明"
fi
assert_contains "过期声明的名字" "$out" "libfixture.so.998"

printf '# 注释\n\nlibfixture.so.999\n' > "$tmp/declared-comments"
if bash "$check_elf" --require-needed "$tmp/elf" "$tmp/declared-comments"; then
    pass "--require-needed 忽略注释与空行"
else
    fail "--require-needed 忽略注释与空行"
fi

assert_contains "--list-needed 列出产物的 NEEDED" \
    "$(bash "$check_elf" --list-needed "$tmp/elf")" "libfixture.so.999"

printf '\n%s checks, %s failure(s)\n' "$checks" "$failures"
if (( failures > 0 )); then
    exit 1
fi
printf 'Rebuild trigger checks passed.\n'
