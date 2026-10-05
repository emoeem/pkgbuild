#!/usr/bin/env bash
# Automatic repair with transactions, a severity level and a repair budget.
#
#   analyse the failure -> pick a rule -> snapshot the workspace
#     -> apply one narrowly scoped fix -> validate
#     -> (optionally) rebuild + re-validate -> commit, otherwise roll back
#
# Every attempt is appended to an audit log so it is always possible to see
# what was changed, why, by which rule, and whether it was kept or reverted.
#
# Levels (AUTO_FIX_LEVEL is the maximum this run may apply):
#   0  report only, never touch a file
#   1  safe housekeeping: .SRCINFO regeneration, cache cleanup
#   2  validated metadata repair: checksum refresh, pkgrel bump
#   3  repairs that need a rebuild + validation to be trusted
#   4  forbidden: only a suggested patch is written, never applied
#
# Usage:
#   auto-repair.sh --package NAME --failure failure.json [options]

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=scripts/lib/transaction.sh
source "${script_dir}/lib/transaction.sh"

package_name=""
failure_file=""
root=""
max_level="${AUTO_FIX_LEVEL:-2}"
max_attempts="${MAX_REPAIR_ATTEMPTS:-2}"
attempts_used="${REPAIR_ATTEMPTS_USED:-0}"
apply=0
audit_file=""
out_file=""
rebuild_cmd=""
validate_cmd=""
json_only=0
record_dir=""

while (( $# > 0 )); do
    case "$1" in
        --package) package_name="$2"; shift 2 ;;
        --failure) failure_file="$2"; shift 2 ;;
        --root) root="$2"; shift 2 ;;
        --level) max_level="$2"; shift 2 ;;
        --max-attempts) max_attempts="$2"; shift 2 ;;
        --attempts-used) attempts_used="$2"; shift 2 ;;
        --apply) apply=1; shift ;;
        --audit) audit_file="$2"; shift 2 ;;
        --out) out_file="$2"; shift 2 ;;
        --rebuild-cmd) rebuild_cmd="$2"; shift 2 ;;
        --validate-cmd) validate_cmd="$2"; shift 2 ;;
        --json) json_only=1; shift ;;
        --help | -h)
            sed -n '2,26p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

root="${root:-${script_dir}/..}"
root="$(cd -- "$root" && pwd)"
readonly root
[[ -n "$package_name" ]] || { printf 'auto-repair: --package is required\n' >&2; exit 2; }
[[ "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]] || { printf 'invalid package name\n' >&2; exit 2; }
[[ -n "$failure_file" && -f "$failure_file" ]] || {
    printf 'auto-repair: --failure must point at a failure.json\n' >&2
    exit 2
}
[[ "$max_level" =~ ^[0-4]$ ]] || { printf 'invalid --level\n' >&2; exit 2; }
[[ "$max_attempts" =~ ^[0-9]+$ ]] || { printf 'invalid --max-attempts\n' >&2; exit 2; }
[[ "$attempts_used" =~ ^[0-9]+$ ]] || { printf 'invalid --attempts-used\n' >&2; exit 2; }

package_dir="$root/packages/$package_name"
if [[ ! -f "$package_dir/PKGBUILD" ]]; then
    printf 'auto-repair: no PKGBUILD for %s\n' "$package_name" >&2
    exit 2
fi

mapfile -t verdict < <(
    python3 - "$failure_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rules = data.get("matched_rules") or [{}]
for value in (
    data.get("category", "BuildError"),
    rules[0].get("id", "unknown"),
    data.get("confidence", "low"),
    data.get("auto_fix", {}).get("level", "none"),
    (data.get("root_cause") or "unclassified").replace("\n", " "),
):
    print(value)
PY
)
category="${verdict[0]:-BuildError}"
rule_id="${verdict[1]:-unknown}"
confidence="${verdict[2]:-low}"
level_hint="${verdict[3]:-none}"
root_cause="${verdict[4]:-unclassified}"

strategy="none"
strategy_level=0
strategy_reason="no automatic repair is known for this failure"

case "$category" in
    PKGBuildError)
        case "$rule_id" in
            srcinfo-stale)
                strategy="regenerate_srcinfo"
                strategy_level=1
                strategy_reason="the generated .SRCINFO no longer matches the PKGBUILD"
                ;;
        esac
        ;;
    SourceError)
        case "$rule_id" in
            checksum-mismatch)
                if [[ -f "$package_dir/.aur-url" ]]; then
                    strategy="refresh_checksum"
                    strategy_level=2
                    strategy_reason="an AUR-tracked source changed upstream; refresh the declared checksums"
                else
                    strategy_reason="checksum mismatch on a repository-managed source: refusing to accept new upstream content automatically"
                fi
                ;;
        esac
        ;;
    SONAMEError | RuntimeDependencyError)
        strategy="bump_pkgrel"
        strategy_level=3
        strategy_reason="dependency SONAME/ABI drift: the package must be rebuilt against the new provider"
        ;;
    CacheError)
        strategy="clear_cache"
        strategy_level=1
        strategy_reason="the build cache is unusable for this package"
        ;;
    EnvironmentError)
        case "$rule_id" in
            out-of-memory)
                strategy="reduce_parallelism"
                strategy_level=3
                strategy_reason="the build ran out of memory; lowering MAKE_JOBS is the only safe lever"
                ;;
        esac
        ;;
esac

attempt=$(( attempts_used + 1 ))

emit_record() {
    local status="$1" detail="$2" rollback_status="$3" validation_status="$4"
    python3 - \
        "$package_name" "$attempt" "$rule_id" "$category" "$strategy" \
        "$strategy_level" "$confidence" "$strategy_reason" "$status" "$detail" \
        "$rollback_status" "$validation_status" "$max_attempts" "$max_level" \
        "$out_file" "$audit_file" "$json_only" "$record_dir" \
        "$level_hint" "$root_cause" <<'PY'
import json, os, sys
from datetime import datetime, timezone

(
    package, attempt, rule, category, strategy, level, confidence, reason,
    status, detail, rollback, validation, max_attempts, max_level,
    out_file, audit_file, json_only, record_dir, analyzer_level, analyzer_cause,
) = sys.argv[1:21]

record = {
    "schema": 1,
    "package": package,
    "attempt": int(attempt),
    "rule": rule,
    "category": category,
    "strategy": strategy,
    "level": f"level{level}",
    "confidence": confidence,
    "reason": reason,
    "status": status,
    "detail": detail,
    "validation": validation,
    "rollback": rollback,
    "budget": {
        "max_attempts": int(max_attempts),
        "max_level": int(max_level),
        "attempt": int(attempt),
    },
    "analyzer": {"level": analyzer_level, "root_cause": analyzer_cause},
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if record_dir and os.path.isdir(record_dir):
    digests = os.path.join(record_dir, "after.json")
    patch = os.path.join(record_dir, "diff.patch")
    commands = os.path.join(record_dir, "commands.txt")
    if os.path.isfile(digests):
        try:
            record["digests"] = json.load(open(digests, encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    if os.path.isfile(patch):
        record["diff"] = open(patch, encoding="utf-8").read()
    if os.path.isfile(commands):
        record["commands"] = open(commands, encoding="utf-8").read().splitlines()

payload = json.dumps(record, indent=2, sort_keys=True, ensure_ascii=False)
if out_file:
    with open(out_file, "w", encoding="utf-8") as handle:
        handle.write(payload + "\n")
if audit_file:
    with open(audit_file, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")
if not json_only:
    print(f"Repair #{attempt}")
    print("--------------------")
    print(f"Package:    {package}")
    print(f"Reason:     {reason}")
    print(f"Rule:       {rule} ({category})")
    print(f"Strategy:   {strategy} ({record['level']})")
    print(f"Status:     {status}")
    print(f"Detail:     {detail}")
    print(f"Validation: {validation}")
    print(f"Rollback:   {rollback}")
    print("")
PY
}

if (( attempt > max_attempts )); then
    emit_record "budget-exhausted" \
        "repair budget of $max_attempts attempt(s) is already used up" "not-needed" "not-run"
    exit 0
fi

if (( strategy_level == 0 )); then
    emit_record "report-only" "$strategy_reason" "not-needed" "not-run"
    exit 0
fi

if (( strategy_level > max_level )); then
    emit_record "blocked-by-level" \
        "strategy $strategy needs level$strategy_level but AUTO_FIX_LEVEL is $max_level" \
        "not-needed" "not-run"
    exit 0
fi

if (( strategy_level >= 4 )); then
    emit_record "patch-suggested" \
        "level 4 repairs are never applied automatically; a suggested patch is produced instead" \
        "not-needed" "not-run"
    exit 0
fi

if (( apply == 0 )); then
    emit_record "dry-run" \
        "would apply $strategy (level$strategy_level); rerun with --apply" \
        "not-needed" "not-run"
    exit 0
fi

txn_init "$root" "packages/$package_name/PKGBUILD" "packages/$package_name/.SRCINFO"
txn_snapshot
txn_record_before

record_dir="$(mktemp -d)"
: >"$record_dir/commands.txt"

run_validation() {
    local status=0
    local generated

    if bash -n "$package_dir/PKGBUILD"; then
        printf 'bash -n packages/%s/PKGBUILD: pass\n' "$package_name" >>"$record_dir/commands.txt"
    else
        printf 'bash -n packages/%s/PKGBUILD: FAIL\n' "$package_name" >>"$record_dir/commands.txt"
        status=1
    fi

    if command -v makepkg >/dev/null 2>&1; then
        generated="$(mktemp -d)"
        if (
            cd "$package_dir" &&
                BUILDDIR="$generated" SRCDEST="$generated" \
                    PKGDEST="$generated" LOGDEST="$generated" \
                    makepkg --printsrcinfo >"$generated/SRCINFO"
        ) && diff -q "$package_dir/.SRCINFO" "$generated/SRCINFO" >/dev/null; then
            printf 'makepkg --printsrcinfo matches .SRCINFO: pass\n' >>"$record_dir/commands.txt"
        else
            printf 'makepkg --printsrcinfo matches .SRCINFO: FAIL\n' >>"$record_dir/commands.txt"
            status=1
        fi
        rm -rf "$generated"
    else
        printf 'makepkg unavailable: .SRCINFO comparison skipped\n' >>"$record_dir/commands.txt"
    fi

    if [[ -n "$validate_cmd" ]]; then
        if bash -c "$validate_cmd"; then
            printf '%s: pass\n' "$validate_cmd" >>"$record_dir/commands.txt"
        else
            printf '%s: FAIL\n' "$validate_cmd" >>"$record_dir/commands.txt"
            status=1
        fi
    fi
    return "$status"
}

apply_fix() {
    case "$strategy" in
        regenerate_srcinfo)
            if ! command -v makepkg >/dev/null 2>&1; then
                printf 'makepkg is required to regenerate .SRCINFO\n' >&2
                return 1
            fi
            (cd "$package_dir" && makepkg --printsrcinfo >.SRCINFO) || return 1
            detail="regenerated .SRCINFO from PKGBUILD"
            ;;
        refresh_checksum)
            if command -v updpkgsums >/dev/null 2>&1; then
                (cd "$package_dir" && updpkgsums) || return 1
            elif command -v makepkg >/dev/null 2>&1; then
                local sums
                sums="$(cd "$package_dir" && makepkg -g)" || return 1
                python3 - "$package_dir/PKGBUILD" "$sums" <<'PY' || return 1
import re, sys
path, sums = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
replacement = "sha256sums=(" + " ".join(sums.split()) + ")"
new, count = re.subn(
    r"^sha256sums=\(.*?\)$", replacement, text, count=1, flags=re.MULTILINE | re.DOTALL
)
if count == 0:
    sys.exit("PKGBUILD has no sha256sums array to update")
open(path, "w", encoding="utf-8").write(new)
PY
            else
                printf 'neither updpkgsums nor makepkg is available\n' >&2
                return 1
            fi
            (cd "$package_dir" && makepkg --printsrcinfo >.SRCINFO) || return 1
            detail="refreshed source checksums and regenerated .SRCINFO"
            ;;
        bump_pkgrel)
            local current next
            current="$(awk -F= '/^pkgrel=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$package_dir/PKGBUILD")"
            if [[ "$current" =~ ^([0-9]+)$ ]]; then
                next="$(( BASH_REMATCH[1] + 1 ))"
            elif [[ "$current" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
                next="${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] + 1 ))"
            else
                printf 'cannot bump unsupported pkgrel: %s\n' "$current" >&2
                return 1
            fi
            sed -i -E "s/^pkgrel=.*/pkgrel=$next/" "$package_dir/PKGBUILD"
            (cd "$package_dir" && makepkg --printsrcinfo >.SRCINFO) || return 1
            detail="bumped pkgrel $current -> $next and regenerated .SRCINFO"
            ;;
        clear_cache)
            local cache_dir="${CACHE_DIR:-}"
            if [[ -n "$cache_dir" ]]; then
                rm -rf "${cache_dir}/sources/$package_name" \
                    "${cache_dir}/yay/$package_name" 2>/dev/null || true
                detail="cleared cached sources for $package_name"
            else
                detail="no CACHE_DIR configured; nothing to clear"
            fi
            ;;
        reduce_parallelism)
            printf 'MAKE_JOBS is owned by CI; this repair only recommends lowering it\n' >&2
            return 1
            ;;
        *)
            printf 'no strategy implemented for %s\n' "$strategy" >&2
            return 1
            ;;
    esac
    return 0
}

txn_digest >"$record_dir/before.txt"
if ! apply_fix; then
    txn_rollback
    if txn_restored; then
        rollback_status="restored"
    else
        rollback_status="RESTORE-MISMATCH"
    fi
    txn_cleanup
    emit_record "failed" "applying $strategy failed" "$rollback_status" "not-run"
    exit 1
fi
txn_diff >"$record_dir/diff.patch"
txn_digest >"$record_dir/after.txt"

python3 - "$record_dir" <<'PY'
import json, os, sys
record_dir = sys.argv[1]

def digest(path):
    result = []
    if not os.path.isfile(path):
        return result
    for line in open(path, encoding="utf-8"):
        parts = line.split(None, 1)
        if len(parts) == 2:
            result.append({"sha256": parts[0], "path": parts[1].strip()})
    return result

json.dump(
    {
        "before": digest(os.path.join(record_dir, "before.txt")),
        "after": digest(os.path.join(record_dir, "after.txt")),
    },
    open(os.path.join(record_dir, "after.json"), "w", encoding="utf-8"),
    indent=2,
)
PY

if run_validation; then
    validation_status="pass"
else
    validation_status="fail"
fi

if [[ "$validation_status" != "pass" ]]; then
    txn_rollback
    if txn_restored; then
        rollback_status="restored"
    else
        rollback_status="RESTORE-MISMATCH"
    fi
    txn_cleanup
    emit_record "rolled-back" \
        "$detail; post-fix validation failed, the workspace was restored" \
        "$rollback_status" "$validation_status"
    exit 1
fi

if [[ -n "$rebuild_cmd" ]]; then
    if bash -c "$rebuild_cmd"; then
        printf 'rebuild: pass\n' >>"$record_dir/commands.txt"
    else
        printf 'rebuild: FAIL\n' >>"$record_dir/commands.txt"
        txn_rollback
        if txn_restored; then
            rollback_status="restored"
        else
            rollback_status="RESTORE-MISMATCH"
        fi
        txn_cleanup
        emit_record "rolled-back" "$detail; rebuild failed after the fix" \
            "$rollback_status" "$validation_status"
        exit 1
    fi
fi

txn_commit
emit_record "applied" "$detail" "not-needed" "$validation_status"
exit 0
