#!/usr/bin/env bash
# 把 stale 列表里的包 dispatch 给 build.yml 重建，跳过正在构建或近期刚失败
# 的包。运行列表与各 run 的 job 列表只拉一次；旧实现是在 per-package 循环
# 里反复请求（最多 20×N 次 API 调用）。
set -Eeuo pipefail

stale_file="${1:-maintenance-out/stale.txt}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
output_file="${GITHUB_OUTPUT:-/dev/null}"
[[ -s "$stale_file" ]] || {
  printf 'All packages are up to date with current repository sonames.\n' |
    tee -a "$summary_file"
  printf 'stale=\n' >> "$output_file"
  exit 0
}

runs_tsv="$(mktemp)"
jobs_tsv="$(mktemp)"
trap 'rm -f "$runs_tsv" "$jobs_tsv"' EXIT

# run_id / status / conclusion / created_epoch
gh api "repos/$GITHUB_REPOSITORY/actions/runs?event=workflow_dispatch&per_page=50" \
  --jq '.workflow_runs[] | [.id, .status, (.conclusion // ""), ((.created_at | fromdateiso8601))] | @tsv' \
  > "$runs_tsv"

# run_id / job 里的包名 / job 状态 / job 结论（build matrix 的 job 名是 "Build <pkg>"）
while IFS=$'\t' read -r run_id _status _conclusion _created; do
  [[ -n "$run_id" ]] || continue
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100" \
    --jq '.jobs[] | select(.name | startswith("Build ")) |
          [.name | sub("^Build "; ""), .status, (.conclusion // "")] | @tsv' |
    while IFS=$'\t' read -r pkg job_status job_conclusion; do
      printf '%s\t%s\t%s\t%s\n' "$run_id" "$pkg" "$job_status" "$job_conclusion"
    done
done < "$runs_tsv" > "$jobs_tsv"

declare -A active_pkg=() recent_fail_pkg=()
now="$(date -u +%s)"
while IFS=$'\t' read -r run_id pkg _job_status job_conclusion; do
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

if (( ${#dispatchable[@]} > 0 )); then
  stale="$(IFS=,; echo "${dispatchable[*]}")"
  printf 'Dispatching stale packages: %s\n' "$stale" | tee -a "$summary_file"
  gh workflow run build.yml \
    --repo "$GITHUB_REPOSITORY" \
    -f packages="$stale" \
    -f make_jobs=4 \
    -f bump_pkgrel=true
  printf 'Triggered rebuild for: %s\n' "$stale" | tee -a "$summary_file"
  printf 'stale=%s\n' "$stale" >> "$output_file"
else
  printf 'No rebuild dispatched: all stale packages are already running or in failure cooldown.\n' |
    tee -a "$summary_file"
  printf 'stale=\n' >> "$output_file"
fi
