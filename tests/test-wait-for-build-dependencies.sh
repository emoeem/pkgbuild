#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
real_python="$(command -v python3)"
cat > "$work/bin/python3" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == *build-dag.py ]]; then printf '["quirc"]\n'; else exec "$REAL_PYTHON3" "$@"; fi
MOCK
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${GH_MOCK_MODE:-api-fail}" in
    api-fail) exit 1 ;;
    failed) printf '{"jobs":[{"name":"Build quirc","status":"completed","conclusion":"failure"}]}' ;;
    success) printf '{"jobs":[{"name":"Build quirc","status":"completed","conclusion":"success"}]}' ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$work/bin/python3" "$work/bin/gh"
export REAL_PYTHON3="$real_python"
critical_file="$work/critical.txt"
printf 'ffmpeg-full\n' > "$critical_file"
set +e
output="$(PATH="$work/bin:$PATH" CRITICAL_BUILD_DEPENDENCIES_FILE="$critical_file" GH_MOCK_MODE=api-fail bash "$root/scripts/wait-for-build-dependencies.sh" --package ffmpeg-full --run-id 123 --repository emoeem/pkgbuild --timeout-minutes 1 --poll-seconds 1 2>&1)"
status=$?
set -e
if (( status == 0 )) || [[ "$output" != *'refusing to build critical package ffmpeg-full'* ]]; then
    printf 'critical API outage did not fail closed (status=%s):\n%s\n' "$status" "$output" >&2; exit 1
fi
output="$(PATH="$work/bin:$PATH" CRITICAL_BUILD_DEPENDENCIES_FILE="$critical_file" GH_MOCK_MODE=api-fail bash "$root/scripts/wait-for-build-dependencies.sh" --package quirc --run-id 123 --repository emoeem/pkgbuild --timeout-minutes 1 --poll-seconds 1 2>&1)"
[[ "$output" == *'WARNING:'* && "$output" == *'non-critical package quirc'* ]]
set +e
output="$(PATH="$work/bin:$PATH" CRITICAL_BUILD_DEPENDENCIES_FILE="$critical_file" GH_MOCK_MODE=failed bash "$root/scripts/wait-for-build-dependencies.sh" --package quirc --run-id 123 --repository emoeem/pkgbuild --timeout-minutes 1 --poll-seconds 1 2>&1)"
status=$?
set -e
if (( status == 0 )) || [[ "$output" != *'Prerequisite build(s) failed: quirc'* ]]; then
    printf 'failed dependency job was not propagated (status=%s):\n%s\n' "$status" "$output" >&2; exit 1
fi
printf 'Dependency ordering regression test passed.\n'
