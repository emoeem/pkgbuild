#!/usr/bin/env bash
# 守护「本地 pre-commit 入口 = check.yml 静态关卡」这条等价关系本身。
#
# 三种回归都在这里挡住：
#   1. 清单被悄悄改小（--list 少了检查项）或写下了一个实现不出来的名字；
#   2. 检查失败被吞掉（检查挂掉却仍然退出 0）、缺工具时静默跳过；
#   3. check.yml / .pre-commit-config.yaml / .githooks 又各自维护一份清单，两边漂移。
#
# 本文件刻意**不**列入 scripts/run-static-checks.sh 的检查清单：它会执行 pre-commit
# 钩子，而钩子又会跑一遍那份清单，列进去就是递归。它由 check.yml 单独一步运行。
set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 &&
        pwd
)"
readonly repo_root
readonly runner="${repo_root}/scripts/run-static-checks.sh"
readonly hook="${repo_root}/.githooks/pre-commit"
readonly installer="${repo_root}/scripts/install-git-hooks.sh"
readonly workflow="${repo_root}/.github/workflows/check.yml"
readonly pre_commit_config="${repo_root}/.pre-commit-config.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
ok() { printf 'ok: %s\n' "$*"; }

read -r -d '' expected <<'EOF' || true
package-manifest-policy
package-manifest-tests
select-packages
elf-soname
workflow-images
aur-dependency-fallback
build-regressions
shell-syntax
shellcheck
python-syntax
EOF
readonly expected

# 1. 清单内容与项数：少一项、多一项、重复一项都算回归（新增检查时同步改这里）。
if ! listed="$(bash "$runner" --list)"; then
    fail '--list should exit 0'
fi
if [[ "$listed" == "$expected" ]]; then
    ok '--list reports the expected static checks, in order'
else
    fail "--list differs from the expected checks:
--- expected
${expected}
--- got
${listed}"
fi
mapfile -t listed_names <<<"$listed"
if [[ "$(printf '%s\n' "${listed_names[@]}" | sort | uniq -d)" != "" ]]; then
    fail '--list contains duplicate check names'
fi

# 2. 每个名字都必须实现得出来，而且当前工作树是绿的：一次性把全部名字传给 --only。
count="${#listed_names[@]}"
joined="$(printf '%s,' "${listed_names[@]}")"
if output="$(bash "$runner" --only "${joined%,}" 2>&1)"; then
    if [[ "$output" == *"RESULT static checks passed (${count}/${count})"* ]]; then
        ok 'every listed check exists and passes on this tree'
    else
        fail "unexpected summary line for a full run:
${output}"
    fi
else
    fail "a full run failed:
${output}"
fi

# 3. --only 只跑点名的那个检查（不能顺手把整份清单跑一遍）。
output="$(bash "$runner" --only shell-syntax 2>&1)"
if [[ "$(printf '%s\n' "$output" | grep -c '^==> ')" == "1" ]] &&
    [[ "$output" == *'==> shell-syntax'* ]]; then
    ok '--only runs exactly the requested check'
else
    fail "--only ran the wrong number of checks:
${output}"
fi

# 4. 检查失败必须往上冒：假 shellcheck 直接退出 1，运行器要点名并返回 1。
mkdir -p "${work}/failing-bin"
cat > "${work}/failing-bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'stub shellcheck: refusing to pass\n' >&2
exit 1
EOF
chmod +x "${work}/failing-bin/shellcheck"
set +e
output="$(PATH="${work}/failing-bin:${PATH}" bash "$runner" --only shellcheck 2>&1)"
status=$?
set -e
if ((status != 0)) && [[ "$output" == *'FAILED shellcheck'* ]]; then
    ok 'a failing check is reported by name and fails the run'
else
    fail "a failing check was not surfaced (status=${status}):
${output}"
fi

# 5. 工具缺失是响亮的失败，不是静默跳过（PATH 里只有空目录，shellcheck 找不到）。
mkdir -p "${work}/empty-bin"
set +e
output="$(PATH="${work}/empty-bin" /bin/bash "$runner" --only shellcheck 2>&1)"
status=$?
set -e
if ((status != 0)) && [[ "$output" == *'shellcheck is not installed'* ]]; then
    ok 'a missing tool fails loudly'
else
    fail "a missing tool did not fail loudly (status=${status}):
${output}"
fi

# 6. 拼错的名字要报错（退出 2），不能当成空清单而“全绿”。
set +e
output="$(bash "$runner" --only not-a-check 2>&1)"
status=$?
set -e
if ((status == 2)) && [[ "$output" == *'unknown check(s): not-a-check'* ]]; then
    ok 'an unknown check name is rejected'
else
    fail "an unknown check name was not rejected (status=${status}):
${output}"
fi

# 7. 钩子与安装器：钩子必须真的调用同一个运行器，安装器必须挂上 .githooks。
for path in "$hook" "$installer" "$runner"; do
    if [[ -x "$path" ]]; then
        ok "executable: ${path#"$repo_root"/}"
    else
        fail "${path#"$repo_root"/} should be executable"
    fi
done
if grep -q 'scripts/run-static-checks.sh' "$hook"; then
    ok 'the git hook runs the shared static-check entry point'
else
    fail 'the git hook does not run scripts/run-static-checks.sh'
fi
if EMO_SKIP_STATIC_CHECKS=1 bash "$hook" >/dev/null 2>&1; then
    ok 'EMO_SKIP_STATIC_CHECKS=1 bypasses the hook'
else
    fail 'EMO_SKIP_STATIC_CHECKS=1 should let the hook exit 0'
fi
if grep -q 'core.hooksPath .githooks' "$installer"; then
    ok 'the installer points core.hooksPath at .githooks'
else
    fail 'the installer does not set core.hooksPath=.githooks'
fi

# 8. 不能又回到「check.yml 自己抄一份清单」的老样子。
if grep -q 'bash scripts/run-static-checks.sh' "$workflow"; then
    ok 'check.yml runs the shared static-check entry point'
else
    fail 'check.yml does not run scripts/run-static-checks.sh'
fi
if grep -q 'python3 scripts/check-package-manifests.py' "$workflow"; then
    fail 'check.yml still runs the manifest gate inline instead of via the entry point'
else
    ok 'check.yml has no second, inline copy of the manifest gate'
fi
if grep -q 'scripts/run-static-checks.sh' "$pre_commit_config"; then
    ok '.pre-commit-config.yaml uses the shared entry point'
else
    fail '.pre-commit-config.yaml does not use scripts/run-static-checks.sh'
fi

if ((failures > 0)); then
    printf '%d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'All static-check entry point checks passed.\n'
