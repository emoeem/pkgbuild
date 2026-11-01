#!/usr/bin/env bash
# 把 stale 列表里的包 dispatch 给 build.yml 重建，跳过正在构建或近期刚失败
# 的包。运行列表与各 run 的 job 列表只拉一次；旧实现是在 per-package 循环
# 里反复请求（最多 20×N 次 API 调用）。
#
# dispatch 本身也必须吸收 GitHub 侧的瞬时 5xx。2026-10-27 的 ABI watch 在
# `gh workflow run` 上收到 HTTP 502，整轮检测变红，一个 stale 包都没重建。
# 502 有可能是在请求已经被接受之后才返回的，所以每次重试前先查 build.yml：
# 目标包已有 queued/in_progress job 就说明 dispatch 落地了，盲目重试只会把
# 同一批包排队两次（build.yml 没有全局 concurrency 去去重）。
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/timing.sh
source "${script_dir}/lib/timing.sh"

stale_file="${1:-maintenance-out/stale.txt}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
output_file="${GITHUB_OUTPUT:-/dev/null}"
[[ -s "$stale_file" ]] || {
  printf 'All packages are up to date with current repository sonames.\n' |
    tee -a "$summary_file"
  printf 'stale=\n' >> "$output_file"
  exit 0
}

dispatch_attempts="${DISPATCH_ATTEMPTS:-3}"
dispatch_delay="${DISPATCH_RETRY_DELAY:-5}"
verify_attempts="${DISPATCH_VERIFY_ATTEMPTS:-3}"
verify_delay="${DISPATCH_VERIFY_DELAY:-3}"

runs_tsv="$(mktemp)"
jobs_tsv="$(mktemp)"
trap 'rm -f -- "$runs_tsv" "$jobs_tsv"' EXIT

# 拉取 build.yml 的 run 列表以及每个 run 里 "Build <pkg>" job 的状态。
# run_id / status / conclusion / created_epoch 写入 runs_out；
# run_id / 包名 / job 状态 / job 结论 写入 jobs_out。
load_build_state() {
  local runs_out="$1" jobs_out="$2" per_page="${3:-50}"
  gh api "repos/$GITHUB_REPOSITORY/actions/workflows/build.yml/runs?per_page=${per_page}" \
    --jq '.workflow_runs[] | [.id, .status, (.conclusion // ""), ((.created_at | fromdateiso8601))] | @tsv' \
    > "$runs_out"

  : > "$jobs_out"
  while IFS=$'\t' read -r run_id _status _conclusion _created; do
    [[ -n "$run_id" ]] || continue
    gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100" \
      --jq '.jobs[] | select(.name | startswith("Build ")) |
            [(.name | sub("^Build "; "")), .status, (.conclusion // "")] | @tsv' |
      while IFS=$'\t' read -r pkg job_status job_conclusion; do
        printf '%s\t%s\t%s\t%s\n' "$run_id" "$pkg" "$job_status" "$job_conclusion"
      done
  done < "$runs_out" >> "$jobs_out"
}

# 只看 build.yml 且不限触发方式：push 与 workflow_dispatch 都会排队
# "Build <pkg>" 作业，漏掉 push 会把正在重建的包再 dispatch 一遍。
load_build_state "$runs_tsv" "$jobs_tsv" 50

declare -A active_pkg=() recent_fail_pkg=()
now="$(date -u +%s)"
while IFS=$'\t' read -r run_id pkg job_status job_conclusion; do
  [[ -n "$pkg" ]] || continue
  case "$job_status" in
    queued | in_progress) active_pkg["$pkg"]=1 ;;
    completed)
      if [[ "$job_conclusion" == failure ||
            "$job_conclusion" == cancelled ||
            "$job_conclusion" == timed_out ]]; then
        run_time="$(awk -F '\t' -v id="$run_id" '$1 == id {print $4; exit}' "$runs_tsv")"
        if [[ -n "$run_time" ]]; then
          age=$((now - run_time))
          ((age < 86400)) && recent_fail_pkg["$pkg"]=1
        fi
      fi
      ;;
  esac
done < "$jobs_tsv"

dispatchable=()
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  # Discovering one name that no longer exists in the source tree used to make
  # select-packages.py reject the whole selection, so the dispatched build
  # failed in ten seconds and nothing was ever rebuilt.
  if [[ ! -f "packages/${pkg}/PKGBUILD" ]]; then
    printf 'IGNORE %s: no such package directory; not dispatching.\n' "$pkg" |
      tee -a "$summary_file"
    continue
  fi
  if [[ -n "${active_pkg[$pkg]:-}" ]]; then
    printf 'SKIP %s: rebuild already queued/running.\n' "$pkg" |
      tee -a "$summary_file"
  elif [[ -n "${recent_fail_pkg[$pkg]:-}" ]]; then
    printf 'DEFER %s: rebuild failed within the last 24h; retry later.\n' "$pkg" |
      tee -a "$summary_file"
  else
    dispatchable+=("$pkg")
  fi
done < "$stale_file"

list_has_package() {
  [[ ",${1}," == *",${2},"* ]]
}

# dispatch 返回错误后，判断这次请求是否其实已经被 GitHub 接受：在最近的
# build.yml run 里找目标包的 queued/in_progress job。刚创建的 run 可能要过
# 几秒才出现在 API 里，所以按 verify_attempts 轮询，而不是立刻下结论。
rebuild_is_queued() {
  local packages="$1" attempt=1 pkg job_status run_id
  local verify_runs verify_jobs
  while :; do
    verify_runs="$(mktemp)"
    verify_jobs="$(mktemp)"
    if load_build_state "$verify_runs" "$verify_jobs" 10; then
      while IFS=$'\t' read -r run_id pkg job_status _conclusion; do
        [[ -n "$pkg" ]] || continue
        case "$job_status" in
          queued | in_progress)
            if list_has_package "$packages" "$pkg"; then
              rm -f -- "$verify_runs" "$verify_jobs"
              return 0
            fi
            ;;
        esac
      done < "$verify_jobs"
    fi
    rm -f -- "$verify_runs" "$verify_jobs"
    if ((attempt >= verify_attempts)); then
      return 1
    fi
    printf 'Dispatch result is unknown; checking again in %ds whether the rebuild was accepted.\n' \
      "$verify_delay" >&2
    sleep "$verify_delay"
    attempt=$((attempt + 1))
  done
}

dispatch_once() {
  local packages="$1"
  if gh workflow run build.yml \
    --repo "$GITHUB_REPOSITORY" \
    -f packages="$packages" \
    -f make_jobs=4 \
    -f bump_pkgrel=true; then
    return 0
  fi
  if rebuild_is_queued "$packages"; then
    printf 'Dispatch reported an error, but a rebuild for %s is already queued/running; treating it as dispatched.\n' \
      "$packages" | tee -a "$summary_file"
    return 0
  fi
  return 1
}

if (( ${#dispatchable[@]} > 0 )); then
  stale="$(IFS=,; echo "${dispatchable[*]}")"
  printf 'Dispatching stale packages: %s\n' "$stale" | tee -a "$summary_file"
  RETRY_TRANSIENT_REASON='GitHub API transient?' \
    retry_transient "$dispatch_attempts" "$dispatch_delay" -- dispatch_once "$stale"
  printf 'Triggered rebuild for: %s\n' "$stale" | tee -a "$summary_file"
  printf 'stale=%s\n' "$stale" >> "$output_file"
else
  printf 'No rebuild dispatched: all stale packages are already running or in failure cooldown.\n' |
    tee -a "$summary_file"
  printf 'stale=\n' >> "$output_file"
fi
