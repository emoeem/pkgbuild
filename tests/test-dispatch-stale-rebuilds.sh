#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/dispatch-stale-rebuilds.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp" "${retry_tmp:-}" "${fail_tmp:-}" "${queued_tmp:-}" "${cooldown_tmp:-}"
}
trap cleanup EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/packages/demo-stale" "$tmp/packages/demo-active" "$tmp/packages/demo-failed" \
  "$tmp/packages/demo-recent" "$tmp/state"
printf 'pkgname=demo-stale\n' > "$tmp/packages/demo-stale/PKGBUILD"
printf 'pkgname=demo-active\n' > "$tmp/packages/demo-active/PKGBUILD"
printf 'pkgname=demo-failed\n' > "$tmp/packages/demo-failed/PKGBUILD"
printf 'pkgname=demo-recent\n' > "$tmp/packages/demo-recent/PKGBUILD"
export MOCK_LOG="$tmp/state/gh.log"
export GITHUB_REPOSITORY=emoeem/pkgbuild
export GITHUB_STEP_SUMMARY="$tmp/state/summary.txt"
export GITHUB_OUTPUT="$tmp/state/output.txt"

# mock gh:直接吐 --jq 过滤后的行,不实现 jq。run 2 有在跑的 job,run 1
# 一小时内刚成功/刚失败过——分别覆盖 SKIP、DEFER 与成功冷却分支。
now="$(date -u +%s)"
cat > "$tmp/bin/gh" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "\$*" >> "\$MOCK_LOG"
case "\${1:-}" in
  api)
    case "\$2" in
      *workflows/build.yml/runs*)
        printf '2\tin_progress\t\t${now}\n'
        printf '1\tcompleted\tsuccess\t$((now - 3600))\n'
        ;;
      */runs/2/jobs*)
        printf 'demo-active\tin_progress\t\n'
        ;;
      */runs/1/jobs*)
        printf 'demo-failed\tcompleted\tfailure\ndemo-recent\tcompleted\tsuccess\ndemo-old\tcompleted\tsuccess\n'
        ;;
    esac
    ;;
  workflow)
    # gh workflow run build.yml ... — dispatch 落到日志里供断言
    ;;
esac
MOCK
chmod +x "$tmp/bin/gh"

printf 'demo-active\ndemo-failed\ndemo-recent\ndemo-stale\ndemo-gone\n' > "$tmp/stale.txt"
# 脚本按 CWD 相对路径找 packages/<pkg>/PKGBUILD(与 CI 在仓库根运行一致),
# 所以在沙箱里执行。
(
  cd "$tmp"
  PATH="$tmp/bin:$PATH" bash "$script" "$tmp/stale.txt"
)

grep -q 'SKIP demo-active: rebuild already queued/running' "$GITHUB_STEP_SUMMARY"
grep -q 'DEFER demo-failed: rebuild failed within the last 24h' "$GITHUB_STEP_SUMMARY"
grep -q 'SKIP demo-recent: rebuilt successfully 1h ago and no soname break is reported; cooling down for 24h' \
  "$GITHUB_STEP_SUMMARY"
grep -q 'IGNORE demo-gone: no such package directory' "$GITHUB_STEP_SUMMARY"
grep -q 'Dispatching stale packages: demo-stale' "$GITHUB_STEP_SUMMARY"
grep -q 'gh workflow run build.yml .* -f packages=demo-stale' "$MOCK_LOG"
grep -q 'stale=demo-stale' "$GITHUB_OUTPUT"
# 冷却中的包不能只从 stale 里消失：调用方（ABI watch 的 issue 步骤）靠
# deferred 区分「真的没问题」和「有漂移但暂缓」。
grep -q 'deferred=demo-recent' "$GITHUB_OUTPUT"
# 回归:第二层循环曾因变量名不匹配(_job_status vs job_status)在 set -u 下
# 第一行数据就崩,SKIP/DEFER 全部失灵——脚本能走完并正确分类即证明已修。
#
# --- dispatch 的瞬时 5xx ----------------------------------------------------
# 2026-10-27 的 ABI watch 在 `gh workflow run` 上收到 HTTP 502，直接退出 1，
# 一个 stale 包也没重建。下面三种情形分别覆盖：重试后成功、彻底失败、以及
# 502 其实已在 GitHub 侧入队（不能再 dispatch 第二次）。

# 场景 A：第一次 502，第二次成功。
retry_tmp="$(mktemp -d)"
mkdir -p "$retry_tmp/bin" "$retry_tmp/packages/demo-stale" "$retry_tmp/state"
printf 'pkgname=demo-stale\n' > "$retry_tmp/packages/demo-stale/PKGBUILD"
printf 'demo-stale\n' > "$retry_tmp/stale.txt"
retry_log="$retry_tmp/state/gh.log"
retry_count="$retry_tmp/state/count"
cat > "$retry_tmp/bin/gh" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "\$*" >> "$retry_log"
case "\${1:-}" in
  api) : ;;
  workflow)
    count=\$(( \$(cat "$retry_count" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "\$count" > "$retry_count"
    if (( count == 1 )); then
      printf 'gh: Server Error (HTTP 502)\n' >&2
      exit 1
    fi
    ;;
esac
MOCK
chmod +x "$retry_tmp/bin/gh"
(
  cd "$retry_tmp"
  PATH="$retry_tmp/bin:$PATH" \
    GITHUB_REPOSITORY=emoeem/pkgbuild \
    GITHUB_STEP_SUMMARY="$retry_tmp/state/summary.txt" \
    GITHUB_OUTPUT="$retry_tmp/state/output.txt" \
    DISPATCH_RETRY_DELAY=0 DISPATCH_VERIFY_ATTEMPTS=1 DISPATCH_VERIFY_DELAY=0 \
    bash "$script" "$retry_tmp/stale.txt"
) || {
  printf 'FAIL: a transient 502 aborted the dispatch instead of retrying\n' >&2
  exit 1
}
[[ "$(cat "$retry_count")" == 2 ]] || {
  printf 'FAIL: expected one retry after the 502, got %s attempt(s)\n' "$(cat "$retry_count")" >&2
  exit 1
}
grep -q 'stale=demo-stale' "$retry_tmp/state/output.txt" \
  || { printf 'FAIL: retried dispatch did not record the stale package\n' >&2; exit 1; }

# 场景 B：每次 dispatch 都 502，且 API 里没有对应的 run —— 必须失败。
fail_tmp="$(mktemp -d)"
mkdir -p "$fail_tmp/bin" "$fail_tmp/packages/demo-stale" "$fail_tmp/state"
printf 'pkgname=demo-stale\n' > "$fail_tmp/packages/demo-stale/PKGBUILD"
printf 'demo-stale\n' > "$fail_tmp/stale.txt"
fail_count="$fail_tmp/state/count"
cat > "$fail_tmp/bin/gh" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
case "\${1:-}" in
  api) : ;;
  workflow)
    count=\$(( \$(cat "$fail_count" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "\$count" > "$fail_count"
    printf 'gh: Server Error (HTTP 502)\n' >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$fail_tmp/bin/gh"
if (
  cd "$fail_tmp"
  PATH="$fail_tmp/bin:$PATH" \
    GITHUB_REPOSITORY=emoeem/pkgbuild \
    GITHUB_STEP_SUMMARY="$fail_tmp/state/summary.txt" \
    GITHUB_OUTPUT="$fail_tmp/state/output.txt" \
    DISPATCH_ATTEMPTS=2 DISPATCH_RETRY_DELAY=0 \
    DISPATCH_VERIFY_ATTEMPTS=1 DISPATCH_VERIFY_DELAY=0 \
    bash "$script" "$fail_tmp/stale.txt"
); then
  printf 'FAIL: a dispatch that never landed was reported as successful\n' >&2
  exit 1
fi
[[ "$(cat "$fail_count")" == 2 ]] || {
  printf 'FAIL: expected two dispatch attempts before giving up, got %s\n' "$(cat "$fail_count")" >&2
  exit 1
}

# 场景 C：gh 报 502，但 build.yml 里目标包已经 queued —— 视为已 dispatch，
# 且不再发第二次，否则同一批包会被构建两遍。
queued_tmp="$(mktemp -d)"
mkdir -p "$queued_tmp/bin" "$queued_tmp/packages/demo-stale" "$queued_tmp/state"
printf 'pkgname=demo-stale\n' > "$queued_tmp/packages/demo-stale/PKGBUILD"
printf 'demo-stale\n' > "$queued_tmp/stale.txt"
queued_count="$queued_tmp/state/count"
queued_summary="$queued_tmp/state/summary.txt"
cat > "$queued_tmp/bin/gh" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
case "\${1:-}" in
  api)
    count=\$(cat "$queued_count" 2>/dev/null || echo 0)
    case "\$2" in
      *workflows/build.yml/runs*)
        if (( count >= 1 )); then
          printf '3\tin_progress\t\t${now}\n'
        fi
        ;;
      */runs/3/jobs*)
        printf 'demo-stale\tin_progress\t\n'
        ;;
    esac
    ;;
  workflow)
    count=\$(( \$(cat "$queued_count" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "\$count" > "$queued_count"
    printf 'gh: Server Error (HTTP 502)\n' >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$queued_tmp/bin/gh"
(
  cd "$queued_tmp"
  PATH="$queued_tmp/bin:$PATH" \
    GITHUB_REPOSITORY=emoeem/pkgbuild \
    GITHUB_STEP_SUMMARY="$queued_summary" \
    GITHUB_OUTPUT="$queued_tmp/state/output.txt" \
    DISPATCH_RETRY_DELAY=0 DISPATCH_VERIFY_ATTEMPTS=2 DISPATCH_VERIFY_DELAY=0 \
    bash "$script" "$queued_tmp/stale.txt"
) || {
  printf 'FAIL: a 502 that had already queued the rebuild was reported as failure\n' >&2
  exit 1
}
[[ "$(cat "$queued_count")" == 1 ]] || {
  printf 'FAIL: dispatch was repeated after the rebuild had already queued (%s attempts)\n' \
    "$(cat "$queued_count")" >&2
  exit 1
}
grep -q 'already queued/running; treating it as dispatched' "$queued_summary" \
  || { printf 'FAIL: the ambiguous dispatch outcome was not explained\n' >&2; exit 1; }
grep -q 'stale=demo-stale' "$queued_tmp/state/output.txt" \
  || { printf 'FAIL: queued dispatch did not record the stale package\n' >&2; exit 1; }

# 场景 D：成功冷却 + SONAME 紧急豁免。
# 2026-11-10：没有成功冷却时，ffmpeg-full 每 2 小时被同一批依赖漂移反复
# dispatch（8 天 31 次 bump 重建）。这里钉住两点：一小时前成功重建过的
# 版本漂移包被跳过；同一时刻的 SONAME 破坏必须照常 dispatch（等不起 24h）。
cooldown_tmp="$(mktemp -d)"
mkdir -p "$cooldown_tmp/bin" "$cooldown_tmp/packages/demo-version" \
  "$cooldown_tmp/packages/demo-soname" "$cooldown_tmp/state"
printf 'pkgname=demo-version\n' > "$cooldown_tmp/packages/demo-version/PKGBUILD"
printf 'pkgname=demo-soname\n' > "$cooldown_tmp/packages/demo-soname/PKGBUILD"
printf 'demo-soname\ndemo-version\n' > "$cooldown_tmp/stale.txt"
printf 'demo-soname\n' > "$cooldown_tmp/urgent.txt"
cooldown_log="$cooldown_tmp/state/gh.log"
cat > "$cooldown_tmp/bin/gh" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "\$*" >> "$cooldown_log"
case "\${1:-}" in
  api)
    case "\$2" in
      *workflows/build.yml/runs*)
        printf '9\tcompleted\tsuccess\t$((now - 3600))\n'
        ;;
      */runs/9/jobs*)
        printf 'demo-version\tcompleted\tsuccess\ndemo-soname\tcompleted\tsuccess\n'
        ;;
    esac
    ;;
esac
MOCK
chmod +x "$cooldown_tmp/bin/gh"
(
  cd "$cooldown_tmp"
  PATH="$cooldown_tmp/bin:$PATH" \
    GITHUB_REPOSITORY=emoeem/pkgbuild \
    GITHUB_STEP_SUMMARY="$cooldown_tmp/state/summary.txt" \
    GITHUB_OUTPUT="$cooldown_tmp/state/output.txt" \
    STALE_URGENT_FILE="$cooldown_tmp/urgent.txt" \
    bash "$script" "$cooldown_tmp/stale.txt"
) || { printf 'FAIL: the cooldown scenario aborted the dispatch\n' >&2; exit 1; }
grep -q 'SKIP demo-version: rebuilt successfully 1h ago' "$cooldown_tmp/state/summary.txt" \
  || { printf 'FAIL: a package rebuilt an hour ago was dispatched again\n' >&2; exit 1; }
grep -q 'Dispatching stale packages: demo-soname' "$cooldown_tmp/state/summary.txt" \
  || { printf 'FAIL: a soname break was held back by the success cooldown\n' >&2; exit 1; }
grep -q 'stale=demo-soname' "$cooldown_tmp/state/output.txt" \
  || { printf 'FAIL: the urgent package was not the only one dispatched\n' >&2; exit 1; }
grep -q 'deferred=demo-version' "$cooldown_tmp/state/output.txt" \
  || { printf 'FAIL: the cooling-down package was not reported as deferred\n' >&2; exit 1; }
grep -q 'gh workflow run build.yml .* -f packages=demo-soname' "$cooldown_log" \
  || { printf 'FAIL: the urgent rebuild was not dispatched\n' >&2; exit 1; }

printf 'dispatch-stale-rebuilds tests passed: skip-active, defer-recent-failure, ignore-missing, dispatch-clean, retry-502, fail-502, queued-after-502, success-cooldown, urgent-bypass\n'
