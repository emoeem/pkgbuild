#!/usr/bin/env bash
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

dispatchable=()
now="$(date -u +%s)"
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  active=0
  recent_failure=0
  while IFS=$'\t' read -r run_id run_status run_conclusion run_time; do
    [[ -n "$run_id" ]] || continue
    job="$(gh run view "$run_id" --repo "$GITHUB_REPOSITORY" --json jobs       --jq '.jobs[] | select(.name == "Build '"$pkg"'") | [.name,.status,.conclusion] | @tsv' 2>/dev/null || true)"
    [[ -n "$job" ]] || continue
    case "$run_status" in
      queued|in_progress) active=1 ;;
      completed)
        if [[ "$run_conclusion" == "failure" ||
              "$run_conclusion" == "cancelled" ||
              "$run_conclusion" == "timed_out" ]]; then
          age=$((now - run_time))
          (( age < 86400 )) && recent_failure=1
        fi
        ;;
    esac
  done < <(
    gh api "repos/$GITHUB_REPOSITORY/actions/runs?event=workflow_dispatch&per_page=20"       --jq '.workflow_runs[] | [.id,.status,.conclusion,((.created_at | fromdateiso8601))] | @tsv'
  )

  if (( active )); then
    printf 'SKIP %s: rebuild already queued/running.\n' "$pkg" |
      tee -a "$summary_file"
  elif (( recent_failure )); then
    printf 'DEFER %s: rebuild failed within the last 24h; retry later.\n' "$pkg" |
      tee -a "$summary_file"
  else
    dispatchable+=("$pkg")
  fi
done < "$stale_file"
if (( ${#dispatchable[@]} > 0 )); then
  stale="$(IFS=,; echo "${dispatchable[*]}")"
  printf 'Dispatching stale packages: %s\n' "$stale" | tee -a "$summary_file"
  gh workflow run build.yml     --repo "$GITHUB_REPOSITORY"     -f packages="$stale"     -f make_jobs=4 \
    -f bump_pkgrel=true
  printf 'Triggered rebuild for: %s\n' "$stale" | tee -a "$summary_file"
  printf 'stale=%s\n' "$stale" >> "$output_file"
else
  printf 'No rebuild dispatched: all stale packages are already running or in failure cooldown.\n' |
    tee -a "$summary_file"
  printf 'stale=\n' >> "$output_file"
fi
