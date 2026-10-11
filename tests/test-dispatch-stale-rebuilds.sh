#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/dispatch-stale-rebuilds.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/packages/demo-stale" "$tmp/packages/demo-active" "$tmp/packages/demo-failed" "$tmp/state"
printf 'pkgname=demo-stale\n' > "$tmp/packages/demo-stale/PKGBUILD"
printf 'pkgname=demo-active\n' > "$tmp/packages/demo-active/PKGBUILD"
printf 'pkgname=demo-failed\n' > "$tmp/packages/demo-failed/PKGBUILD"
export MOCK_LOG="$tmp/state/gh.log"
export GITHUB_REPOSITORY=emoeem/pkgbuild
export GITHUB_STEP_SUMMARY="$tmp/state/summary.txt"
export GITHUB_OUTPUT="$tmp/state/output.txt"

# mock gh:直接吐 --jq 过滤后的行,不实现 jq。run 2 有在跑的 job,run 1
# 一小时内刚失败过一个包——分别覆盖 SKIP 与 DEFER 分支。
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
        printf 'demo-failed\tcompleted\tfailure\ndemo-old\tcompleted\tsuccess\n'
        ;;
    esac
    ;;
  workflow)
    # gh workflow run build.yml ... — dispatch 落到日志里供断言
    ;;
esac
MOCK
chmod +x "$tmp/bin/gh"

printf 'demo-active\ndemo-failed\ndemo-stale\ndemo-gone\n' > "$tmp/stale.txt"
# 脚本按 CWD 相对路径找 packages/<pkg>/PKGBUILD(与 CI 在仓库根运行一致),
# 所以在沙箱里执行。
(
  cd "$tmp"
  PATH="$tmp/bin:$PATH" bash "$script" "$tmp/stale.txt"
)

grep -q 'SKIP demo-active: rebuild already queued/running' "$GITHUB_STEP_SUMMARY"
grep -q 'DEFER demo-failed: rebuild failed within the last 24h' "$GITHUB_STEP_SUMMARY"
grep -q 'IGNORE demo-gone: no such package directory' "$GITHUB_STEP_SUMMARY"
grep -q 'Dispatching stale packages: demo-stale' "$GITHUB_STEP_SUMMARY"
grep -q 'gh workflow run build.yml .* -f packages=demo-stale' "$MOCK_LOG"
grep -q 'stale=demo-stale' "$GITHUB_OUTPUT"
# 回归:第二层循环曾因变量名不匹配(_job_status vs job_status)在 set -u 下
# 第一行数据就崩,SKIP/DEFER 全部失灵——脚本能走完并正确分类即证明已修。
printf 'dispatch-stale-rebuilds tests passed: skip-active, defer-recent-failure, ignore-missing, dispatch-clean\n'
