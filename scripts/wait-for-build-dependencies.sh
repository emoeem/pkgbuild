#!/usr/bin/env bash
# Wait until this run's jobs for the in-repo prerequisites of a package have
# finished.
#
# GitHub's matrix starts every job at once, so without this a package would
# happily build against the *previous* version of a library that is being
# rebuilt in the same run (ffmpeg-full links mpeghdec / quirc / svt-jpeg-xs-git).
#
# Fail-open by design: if the API is unavailable the wait is skipped with a
# warning, because blocking a build on a monitoring API would be worse than the
# ordering hazard it prevents.
#
# Usage: wait-for-build-dependencies.sh --package NAME --run-id ID
set -Eeuo pipefail

package_name=""
run_id="${GITHUB_RUN_ID:-}"
repository="${GITHUB_REPOSITORY:-}"
timeout_minutes="${WAIT_TIMEOUT_MINUTES:-45}"
poll_seconds="${WAIT_POLL_SECONDS:-20}"

while (( $# > 0 )); do
    case "$1" in
        --package) package_name="$2"; shift 2 ;;
        --run-id) run_id="$2"; shift 2 ;;
        --repository) repository="$2"; shift 2 ;;
        --timeout-minutes) timeout_minutes="$2"; shift 2 ;;
        --poll-seconds) poll_seconds="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -n "$package_name" ]] || { printf 'wait-for-build-dependencies: --package is required\n' >&2; exit 2; }
[[ -n "$run_id" ]] || { printf 'wait-for-build-dependencies: --run-id is required\n' >&2; exit 2; }
[[ -n "$repository" ]] || { printf 'wait-for-build-dependencies: --repository is required\n' >&2; exit 2; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${script_dir}/.." && pwd)"

prerequisites="$(python3 "$root/scripts/build-dag.py" --prerequisites-for "$package_name")"
if [[ "$prerequisites" == "[]" || -z "$prerequisites" ]]; then
    printf '%s has no in-repo build prerequisites; nothing to wait for.\n' "$package_name"
    exit 0
fi

mapfile -t dependency_names < <(
    python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$prerequisites"
)
printf 'Waiting for in-repo prerequisites of %s: %s\n' \
    "$package_name" "${dependency_names[*]}"

deadline=$(( SECONDS + timeout_minutes * 60 ))
pending=()
while (( SECONDS < deadline )); do
    if ! jobs_json="$(timeout 60 gh api \
        "repos/${repository}/actions/runs/${run_id}/jobs?per_page=100" 2>/dev/null)"; then
        printf 'WARNING: could not read job status from the GitHub API; skipping the ordering wait.\n' >&2
        exit 0
    fi

    pending=()
    failed=()
    for dependency in "${dependency_names[@]}"; do
        read -r status conclusion < <(
            python3 -c '
import json, sys
data = json.loads(sys.argv[1])
name = "Build " + sys.argv[2]
for job in data.get("jobs", []):
    if job.get("name") == name:
        print(job.get("status", "unknown"), job.get("conclusion") or "-")
        break
else:
    print("missing -")
' "$jobs_json" "$dependency"
        )
        case "$status" in
            completed)
                case "$conclusion" in
                    success|skipped) ;;
                    *) failed+=("$dependency") ;;
                esac
                ;;
            *)
                pending+=("$dependency")
                ;;
        esac
    done

    if (( ${#failed[@]} > 0 )); then
        printf 'Prerequisite build(s) failed: %s\n' "${failed[*]}" >&2
        exit 1
    fi
    if (( ${#pending[@]} == 0 )); then
        printf 'All in-repo prerequisites finished successfully.\n'
        exit 0
    fi
    printf 'Still waiting for: %s\n' "${pending[*]}"
    sleep "$poll_seconds"
done

printf 'Timed out after %s minute(s) waiting for: %s\n' \
    "$timeout_minutes" "${pending[*]}" >&2
exit 1
