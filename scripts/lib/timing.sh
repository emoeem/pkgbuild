#!/usr/bin/env bash
# Timing helpers sourced by scripts/build-in-arch.sh.
#
# Holds only what bash can measure exactly: wall clock around orchestration
# phases, and cheap resource counters (children CPU time, cgroup peak memory,
# bytes downloaded). Everything derived from makepkg's own banners is parsed
# from the stamped build log by scripts/build-timing.py.

# shellcheck shell=bash

declare -A TIMING_PHASE_START=()
TIMING_FILE=""
TIMING_T0="0"

timing_init() {
    TIMING_FILE="$1"
    TIMING_T0="$(date +%s.%N)"
    : >"$TIMING_FILE"
}

_timing_seconds() {
    # Portable float subtraction without bc.
    awk -v start="$1" -v end="$2" 'BEGIN { printf "%.3f", end - start }'
}

timing_begin() {
    TIMING_PHASE_START["$1"]="$(date +%s.%N)"
}

timing_end() {
    local phase="$1"
    local status="${2:-ok}"
    local start="${TIMING_PHASE_START[$phase]:-}"
    [[ -n "$start" ]] || return 0
    local seconds
    seconds="$(_timing_seconds "$start" "$(date +%s.%N)")"
    printf '{"phase":"%s","seconds":%s,"status":"%s"}\n' \
        "$phase" "$seconds" "$status" >>"$TIMING_FILE"
    unset "TIMING_PHASE_START[$phase]"
}

timing_total() {
    [[ -n "$TIMING_FILE" ]] || return 0
    local seconds
    seconds="$(_timing_seconds "$TIMING_T0" "$(date +%s.%N)")"
    printf '{"phase":"total","seconds":%s,"status":"ok"}\n' \
        "$seconds" >>"$TIMING_FILE"
}

# Collect cheap resource facts for the "how expensive is this package" model
# used by the resource aware scheduler.
#
#   timing_resources <out-file> <build-dir> <source-cache-dir> <package-bytes>
timing_resources() {
    local out_file="$1"
    local build_dir="$2"
    # Not "source_cache_dir": build-in-arch.sh declares that name readonly at
    # top level, and "local source_cache_dir" then trips
    # "local: source_cache_dir: readonly variable" (exit 1) under set -e,
    # aborting every build before it starts.
    local sources_dir="$3"
    local package_bytes="${4:-0}"

    : >"$out_file"

    # Children CPU time: the second line of bash's times builtin is the
    # cumulative user/sys time of every child process ("0m1.234s 0m5.678s").
    local children_line cpu_seconds
    children_line="$(times | tail -n1)"
    cpu_seconds="$(
        printf '%s\n' "$children_line" |
            awk '
                function secs(token, parts) {
                    split(token, parts, "m")
                    sub(/s$/, "", parts[2])
                    return parts[1] * 60 + parts[2]
                }
                { printf "%.3f", secs($1) + secs($2) }
            '
    )"
    printf 'cpu_seconds=%s\n' "${cpu_seconds:-0}" >>"$out_file"

    local peak=""
    for candidate in /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory/memory.max_usage_in_bytes; do
        if [[ -r "$candidate" ]]; then
            peak="$(cat "$candidate" 2>/dev/null || true)"
            [[ -n "$peak" ]] && break
        fi
    done
    printf 'memory_peak_bytes=%s\n' "${peak:-0}" >>"$out_file"

    local bytes
    bytes="$(du -sb "$build_dir" 2>/dev/null | awk '{ print $1 }')"
    printf 'build_dir_bytes=%s\n' "${bytes:-0}" >>"$out_file"

    if [[ -d "$sources_dir" ]]; then
        bytes="$(du -sb "$sources_dir" 2>/dev/null | awk '{ print $1 }')"
        printf 'source_cache_bytes=%s\n' "${bytes:-0}" >>"$out_file"
    fi

    printf 'package_bytes=%s\n' "$package_bytes" >>"$out_file"

    local jobs="${MAKE_JOBS:-1}"
    printf 'make_jobs=%s\n' "$jobs" >>"$out_file"
}
