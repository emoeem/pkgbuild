#!/usr/bin/env bash
# retry_transient is what stands between a stale CDN edge and a red build, so
# it has to be tested by behaviour: how many times the command actually ran,
# and what the caller sees when retries run out.
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$here/.." && pwd)"

# shellcheck source=scripts/lib/timing.sh
source "$repo_root/scripts/lib/timing.sh"

failures=0
ok() { printf 'ok - %s\n' "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- runs once when the first attempt succeeds -----------------------------
calls=0
always_ok() { calls=$((calls + 1)); return 0; }

if retry_transient 3 0 -- always_ok; then
    if ((calls == 1)); then
        ok 'a successful command is not retried'
    else
        fail "expected 1 call, got $calls"
    fi
else
    fail 'retry_transient failed a command that succeeds'
fi

# --- retries and then succeeds --------------------------------------------
calls=0
fails_twice() {
    calls=$((calls + 1))
    ((calls <= 2)) && return 1
    return 0
}

if retry_transient 3 0 -- fails_twice 2>"$work/msg"; then
    if ((calls == 3)); then
        ok 'a command that fails twice is retried until it works'
    else
        fail "expected 3 calls, got $calls"
    fi
    if grep -q 'upstream mirror transient' "$work/msg"; then
        ok 'a retry says why it is retrying'
    else
        fail 'a retry did not explain itself'
    fi
else
    fail 'retry_transient gave up while attempts remained'
fi

# --- gives up after exactly the allowed number of attempts ----------------
calls=0
always_fails() { calls=$((calls + 1)); return 1; }

if retry_transient 3 0 -- always_fails 2>"$work/msg2"; then
    fail 'retry_transient reported success for a command that never succeeds'
else
    if ((calls == 3)); then
        ok 'a permanent failure stops at the attempt limit'
    else
        fail "expected 3 calls, got $calls"
    fi
    if grep -q 'still failing after 3 attempts' "$work/msg2"; then
        ok 'the final failure names the attempt count'
    else
        fail 'the final failure did not name the attempt count'
    fi
fi

# --- the "--" separator is optional --------------------------------------
calls=0
if retry_transient 2 0 always_ok; then
    if ((calls == 1)); then
        ok 'the command runs without a "--" separator'
    else
        fail "expected 1 call without separator, got $calls"
    fi
else
    fail 'retry_transient failed without a "--" separator'
fi

# --- it passes the command's own arguments through untouched --------------
seen=""
record_args() { seen="$*"; return 0; }
retry_transient 2 0 -- record_args -S --needed --noconfirm pkg-a pkg-b
if [[ "$seen" == "-S --needed --noconfirm pkg-a pkg-b" ]]; then
    ok 'arguments reach the command unchanged'
else
    fail "arguments were mangled: $seen"
fi

if ((failures > 0)); then
    printf '%s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'all retry_transient cases passed\n'
