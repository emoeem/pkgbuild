#!/usr/bin/env bash
# One-shot environment diagnosis: ./scripts/doctor.sh
#
# Answers "can this machine build and publish this repository right now, and if
# not, which piece is missing" without starting a build. Every check is
# independent, reports PASS / WARN / FAIL, and never aborts the run.
#
# Usage: doctor.sh [--json FILE] [--strict] [--repository-dir DIR]
#
#   --strict            treat WARN as failure (exit 1)
#   --repository-dir    also verify a published repository directory
set -Eeuo pipefail

export LC_ALL=C

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${script_dir}/.." && pwd)"

json_out=""
strict=0
repository_dir=""

while (( $# > 0 )); do
    case "$1" in
        --json) json_out="$2"; shift 2 ;;
        --strict) strict=1; shift ;;
        --repository-dir) repository_dir="$2"; shift 2 ;;
        --help | -h) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

pass_count=0
warn_count=0
fail_count=0
findings="$(mktemp)"
trap 'rm -f "$findings"' EXIT

record() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        PASS) pass_count=$(( pass_count + 1 )) ;;
        WARN) warn_count=$(( warn_count + 1 )) ;;
        FAIL) fail_count=$(( fail_count + 1 )) ;;
    esac
    python3 -c '
import json, sys
print(json.dumps({"status": sys.argv[1], "check": sys.argv[2], "detail": sys.argv[3]}))
' "$status" "$name" "$detail" >>"$findings"
    printf '%-10s %-22s %s\n' "$status" "$name" "$detail"
}

check() {
    local name="$1"
    shift
    local detail
    if detail="$(bash -c "$1" 2>&1)"; then
        record PASS "$name" "${detail:-ok}"
    else
        record FAIL "$name" "${detail:-failed}"
    fi
}

printf 'Doctor\n'
printf '%s\n' "---------------------------"
printf '\n'

# --- version control --------------------------------------------------------
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$root" branch --show-current)"
    dirty="$(git -C "$root" status --porcelain | wc -l)"
    if (( dirty > 0 )); then
        record WARN Git "branch ${branch:-detached}, $dirty uncommitted change(s)"
    else
        record PASS Git "branch ${branch:-detached}, clean"
    fi
else
    record FAIL Git "$root is not a git work tree"
fi

check 'Package metadata' "python3 '$root/scripts/build-planner.py' --selection all --format json | python3 -c 'import json,sys; print(str(len(json.load(sys.stdin)[\"rebuild\"])) + \" package(s) parsed\")'"

if command -v actionlint >/dev/null 2>&1; then
    check 'CI configuration' "actionlint '$root'/.github/workflows/*.yml >/dev/null && echo 'actionlint clean'"
else
    record WARN 'CI configuration' 'actionlint not installed; workflow syntax unchecked'
fi

check Shellcheck "command -v shellcheck >/dev/null && shellcheck --severity=warning '$root'/scripts/*.sh '$root'/scripts/lib/*.sh '$root'/tests/*.sh >/dev/null && echo 'shellcheck clean'"

# --- tooling ----------------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
    if gh auth token >/dev/null 2>&1; then
        record PASS 'GitHub CLI' 'authenticated'
    else
        record WARN 'GitHub CLI' 'installed but not authenticated (gh auth login)'
    fi
else
    record WARN 'GitHub CLI' 'gh not installed; AUR sync and rebuild dispatch are unavailable'
fi

runtime=""
for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then
        runtime="$candidate"
        break
    fi
done
if [[ -n "$runtime" ]]; then
    if "$runtime" info >/dev/null 2>&1; then
        record PASS 'Container runtime' "$runtime is usable"
    else
        record WARN 'Container runtime' "$runtime installed but the daemon is unreachable"
    fi
else
    record WARN 'Container runtime' 'neither docker nor podman found; only native CachyOS builds are possible'
fi

if command -v pacman >/dev/null 2>&1; then
    if [[ -r /etc/os-release ]] && grep -q '^ID=cachyos$' /etc/os-release; then
        record PASS pacman 'CachyOS host with pacman'
    else
        record PASS pacman 'pacman available'
    fi
else
    record WARN pacman 'pacman not available; only container builds are possible'
fi

if command -v makepkg >/dev/null 2>&1; then
    record PASS makepkg "$(makepkg --version | head -n1)"
else
    record WARN makepkg 'makepkg not available on this host'
fi

if command -v ccache >/dev/null 2>&1; then
    record PASS ccache 'available'
else
    record WARN ccache 'ccache not installed; C/C++ rebuilds will not hit a compiler cache'
fi

# --- repository state -------------------------------------------------------
if [[ -n "$repository_dir" ]]; then
    if [[ -d "$repository_dir" ]]; then
        if bash "$root/scripts/verify-repository.sh" "$repository_dir" >/dev/null 2>&1; then
            record PASS Repository "$repository_dir verified"
        else
            record FAIL Repository "$repository_dir failed verification"
        fi
    else
        record FAIL Repository "$repository_dir does not exist"
    fi
else
    record WARN Repository 'no --repository-dir given; published repository not verified'
fi

tracked="$(git -C "$root" ls-files | wc -l)"
untracked_scripts="$(git -C "$root" ls-files --others --exclude-standard -- scripts .github | wc -l)"
if (( untracked_scripts > 0 )); then
    record WARN 'Tracked files' "$tracked tracked; $untracked_scripts script/workflow file(s) uncommitted, so CI cannot see them"
else
    record PASS 'Tracked files' "$tracked tracked, no untracked script"
fi

# --- resources --------------------------------------------------------------
cache_dir="${PKGBUILD_CACHE_DIR:-$root/.cache/pkgbuild}"
if [[ -d "$cache_dir" ]]; then
    cache_size="$(du -sh "$cache_dir" 2>/dev/null | awk '{ print $1 }')"
    if [[ -w "$cache_dir" ]]; then
        record PASS Cache "present and writable (${cache_size:-unknown})"
    else
        record FAIL Cache "$cache_dir is not writable"
    fi
else
    record WARN Cache "no cache at $cache_dir yet"
fi

disk_available="$(df -Pk "$root" | awk 'NR==2 { print $4 }')"
if (( disk_available > 50 * 1024 * 1024 )); then
    record PASS 'Disk space' "$(( disk_available / 1048576 )) GiB free"
elif (( disk_available > 15 * 1024 * 1024 )); then
    record WARN 'Disk space' "$(( disk_available / 1048576 )) GiB free; ffmpeg-full needs about 25 GiB"
else
    record FAIL 'Disk space' "$(( disk_available / 1048576 )) GiB free; builds will run out of space"
fi

memory_kb="$(awk '/MemTotal/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
if (( memory_kb > 16 * 1024 * 1024 )); then
    record PASS Memory "$(( memory_kb / 1048576 )) GiB total"
elif (( memory_kb > 6 * 1024 * 1024 )); then
    record WARN Memory "$(( memory_kb / 1048576 )) GiB total; limit MAKE_JOBS to avoid OOM kills"
else
    record FAIL Memory "$(( memory_kb / 1048576 )) GiB total; parallel builds will be OOM-killed"
fi

# --- network ----------------------------------------------------------------
network_ok=0
for url in https://aur.archlinux.org https://github.com; do
    if curl -sS -o /dev/null --max-time 8 "$url" >/dev/null 2>&1; then
        network_ok=1
    fi
done
if (( network_ok == 1 )); then
    record PASS Network 'reachable (aur.archlinux.org / github.com)'
else
    record WARN Network 'no reachability confirmed; source downloads will fail'
fi

# --- summary ----------------------------------------------------------------
printf '\nResult: '
if (( fail_count > 0 )); then
    printf 'NOT READY (%d failure(s))\n' "$fail_count"
    result="NOT_READY"
elif (( warn_count > 0 )); then
    printf 'READY WITH WARNINGS (%d warning(s))\n' "$warn_count"
    result="READY_WITH_WARNINGS"
else
    printf 'READY\n'
    result="READY"
fi

if [[ -n "$json_out" ]]; then
    python3 - "$findings" "$json_out" "$result" "$pass_count" "$warn_count" "$fail_count" <<'PY'
import json, sys
findings, out, result, passed, warned, failed = sys.argv[1:7]
checks = []
with open(findings, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            checks.append(json.loads(line))
json.dump(
    {
        "schema": 1,
        "result": result,
        "counts": {"pass": int(passed), "warn": int(warned), "fail": int(failed)},
        "checks": checks,
    },
    open(out, "w", encoding="utf-8"),
    indent=2,
    sort_keys=True,
)
PY
fi

if (( fail_count > 0 )); then
    exit 1
fi
if (( strict == 1 && warn_count > 0 )); then
    exit 1
fi
exit 0
