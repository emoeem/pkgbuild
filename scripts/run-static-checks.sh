#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$(mktemp -d)}"
passed=0
run() { printf '==> %s\n' "$1"; shift; "$@"; passed=$((passed + 1)); }
run 'Bash syntax' bash -c 'for f in manage.sh client/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; do [[ ! -f "$f" ]] || bash -n "$f"; done'
if command -v shellcheck >/dev/null 2>&1; then run 'ShellCheck' shellcheck --severity=warning manage.sh client/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; else echo 'SKIP ShellCheck: not installed'; fi
if command -v actionlint >/dev/null 2>&1; then run 'actionlint' actionlint .github/workflows/*.yml; else echo 'SKIP actionlint: not installed'; fi
run 'Python compile' python3 -m py_compile scripts/*.py scripts/lib/*.py tests/*.py
run 'Git diff whitespace' git diff --check
printf 'Static checks completed (%d check groups).\n' "$passed"
