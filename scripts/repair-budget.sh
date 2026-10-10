#!/usr/bin/env bash
# Repair budget: how many automatic repairs a package may consume in a window.
#
# The build -> fail -> repair -> build spiral is the failure mode this guards
# against: without a budget the pipeline can keep "fixing" a package forever
# and never surface the real problem to a human.
#
# Usage: repair-budget.sh --package NAME [--history FILE] [--max N] [--window-hours N]
# Exit: 0 when another attempt is allowed, 1 when the budget is exhausted.
set -Eeuo pipefail

package_name=""
history="${REPAIR_HISTORY:-state/repair-history.jsonl}"
max_attempts="${MAX_REPAIR_ATTEMPTS:-2}"
window_hours="${REPAIR_WINDOW_HOURS:-24}"

while (( $# > 0 )); do
    case "$1" in
        --package) package_name="$2"; shift 2 ;;
        --history) history="$2"; shift 2 ;;
        --max) max_attempts="$2"; shift 2 ;;
        --window-hours) window_hours="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -n "$package_name" ]] || { printf 'repair-budget: --package is required\n' >&2; exit 2; }
[[ "$max_attempts" =~ ^[0-9]+$ ]] || { printf 'invalid --max\n' >&2; exit 2; }
[[ "$window_hours" =~ ^[0-9]+$ ]] || { printf 'invalid --window-hours\n' >&2; exit 2; }

if [[ ! -f "$history" ]]; then
    printf '%s: no repair history yet; attempt 1 of %s allowed.\n' "$package_name" "$max_attempts"
    exit 0
fi

used="$(python3 - "$history" "$package_name" "$window_hours" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone

history, package, window_hours = sys.argv[1], sys.argv[2], int(sys.argv[3])
cutoff = datetime.now(timezone.utc) - timedelta(hours=window_hours)
used = 0
for line in open(history, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get("package") != package or record.get("status") != "applied":
        continue
    timestamp = record.get("timestamp") or record.get("generated_at") or ""
    try:
        moment = datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        moment = datetime.now(timezone.utc)
    if moment >= cutoff:
        used += 1
print(used)
PY
)"

printf '%s: %s applied repair(s) in the last %s hour(s); budget %s.\n' \
    "$package_name" "$used" "$window_hours" "$max_attempts"
if (( used >= max_attempts )); then
    printf 'Repair budget exhausted for %s; a human must look at this package.\n' "$package_name" >&2
    exit 1
fi
exit 0
