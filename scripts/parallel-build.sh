#!/usr/bin/env bash
# Local wave-parallel builder.
#
# CI runs one job per package through a GitHub matrix. Locally the same set is
# built here, but scheduled: packages are grouped into waves by their in-repo
# dependencies and only packages that can actually interleave run at the same
# time, bounded by the resource weights from scripts/build-dag.py.
#
# Usage:
#   parallel-build.sh [options]
#
#   --packages LIST     comma separated package names (default: every package)
#   --plan FILE         take the rebuild set from a build-plan.json
#   --jobs N            concurrent packages (default: the DAG slot width)
#   --make-jobs N       compiler jobs per package (default: half the CPUs)
#   --out DIR           output root (default: ./build-output)
#   --runner MODE       container | local | auto (default: auto)
#   --image IMAGE       builder image for container mode
#   --dry-run           print the schedule and exit without building
#   --keep-going        do not stop the wave when one package fails
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
root="$(cd -- "${script_dir}/.." && pwd)"
readonly root

packages=""
plan=""
jobs=0
make_jobs=0
out_dir="${root}/build-output"
runner="auto"
image="${BUILDER_IMAGE:-ghcr.io/emoeem/pkgbuild-builder:latest}"
dry_run=0
keep_going=0

while (( $# > 0 )); do
    case "$1" in
        --packages) packages="$2"; shift 2 ;;
        --plan) plan="$2"; shift 2 ;;
        --jobs) jobs="$2"; shift 2 ;;
        --make-jobs) make_jobs="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --runner) runner="$2"; shift 2 ;;
        --image) image="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --keep-going) keep_going=1; shift ;;
        --help | -h) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

cpus="$(nproc)"
(( make_jobs > 0 )) || make_jobs="$(( cpus > 1 ? cpus / 2 : 1 ))"

if [[ -n "$plan" && -f "$plan" ]]; then
    packages="$(python3 - "$plan" <<'PY'
import json, sys
print(",".join(json.load(open(sys.argv[1], encoding="utf-8")).get("rebuild", [])))
PY
)"
fi

dag_args=(--format json --cpus "$cpus")
if [[ -n "$packages" ]]; then
    dag_args+=(--packages "$packages")
fi
if (( jobs > 0 )); then
    dag_args+=(--max-parallel-jobs "$jobs")
fi

schedule_file="$(mktemp)"
trap 'rm -f "$schedule_file"' EXIT
python3 "$root/scripts/build-dag.py" "${dag_args[@]}" >"$schedule_file"
slot_width="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"]["parallel_jobs_per_slot"])' "$schedule_file")"
wave_count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"]["waves"])' "$schedule_file")"

printf 'Wave-parallel local build: %s wave(s), up to %s package(s) at a time, make -j%s\n' \
    "$wave_count" "$slot_width" "$make_jobs"

build_package() {
    local package_name="$1"
    local package_out="${out_dir}/${package_name}"
    mkdir -p "$package_out"
    printf '  -> building %s (log: %s/build.log)\n' "$package_name" "${package_out}"
    case "$runner" in
        container)
            "$container_runtime" run --rm \
                --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
                --volume "${root}:/workspace:ro" \
                --volume "${package_out}:/out" \
                --volume "${out_dir}/cache:/cache" \
                --env "PACKAGE_NAME=${package_name}" \
                --env "MAKE_JOBS=${make_jobs}" \
                --env "CACHE_DIR=/cache" \
                "$image" \
                bash /workspace/scripts/build-in-arch.sh \
                >"${package_out}/build.log" 2>&1
            ;;
        local)
            # tee instead of a redirect: a redirect around sudo would be
            # opened by the caller, and shellcheck is right to flag it.
            PACKAGE_NAME="${package_name}" \
            MAKE_JOBS="${make_jobs}" \
            OUTPUT_DIR="${package_out}" \
            CACHE_DIR="${out_dir}/cache" \
                sudo -E bash "$root/scripts/build-in-arch.sh" 2>&1 |
                tee "${package_out}/build.log"
            ;;
        *)
            printf 'unsupported runner: %s\n' "$runner" >&2
            return 2
            ;;
    esac
}

if (( dry_run == 1 )); then
    python3 - "$schedule_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for wave in data["waves"]:
    print(f"Wave {wave['wave']}")
    for slot in wave["slots"]:
        print("  " + ", ".join(slot["packages"]))
PY
    printf 'dry run: nothing was built\n'
    exit 0
fi

container_runtime=""
case "$runner" in
    auto)
        if command -v docker >/dev/null 2>&1; then
            container_runtime=docker
            runner=container
        elif command -v podman >/dev/null 2>&1; then
            container_runtime=podman
            runner=container
        elif (( EUID == 0 )); then
            runner=local
        else
            printf 'No container runtime and not running as root; use --dry-run or install podman.\n' >&2
            exit 2
        fi
        ;;
    container)
        if command -v docker >/dev/null 2>&1; then
            container_runtime=docker
        elif command -v podman >/dev/null 2>&1; then
            container_runtime=podman
        else
            printf 'container runner requested but neither docker nor podman is available\n' >&2
            exit 2
        fi
        ;;
esac

mkdir -p "$out_dir"
failures=0
wave_index=0
while (( wave_index < wave_count )); do
    mapfile -t wave_packages < <(
        python3 - "$schedule_file" "$wave_index" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(data["waves"][int(sys.argv[2])]["packages"]))
PY
    )
    printf 'Wave %d: %s\n' "$wave_index" "${wave_packages[*]}"
    running=0
    wave_failed=0
    pids=()
    for package_name in "${wave_packages[@]}"; do
        while (( running >= slot_width )); do
            if ! wait -n 2>/dev/null; then
                wave_failed=1
                failures=$(( failures + 1 ))
            fi
            running=$(( running - 1 ))
        done
        build_package "$package_name" &
        pids+=("$!")
        running=$(( running + 1 ))
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            wave_failed=1
            failures=$(( failures + 1 ))
        fi
    done
    if (( wave_failed == 1 && keep_going == 0 )); then
        printf 'Wave %d failed; stopping.\n' "$wave_index" >&2
        exit 1
    fi
    wave_index=$(( wave_index + 1 ))
done

if (( failures > 0 )); then
    printf '%d package(s) failed. See %s/*/build.log\n' "$failures" "$out_dir" >&2
    exit 1
fi
printf 'All packages built. Artifacts under %s\n' "$out_dir"
