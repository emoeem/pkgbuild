#!/usr/bin/env bash
# Keep /usr/bin/scxtui out of scx-scheds-git after every AUR sync.
#
# Upstream's package() installs every executable from target/release
# unconditionally. Upstream also started building scxtui, which the scx-tools
# dependency already ships as /usr/bin/scxtui: the two packages collide on that
# exact path, and pacman aborts the transaction with
#
#     scx-scheds-git: /usr/bin/scxtui exists in filesystem (owned by scx-tools)
#
# which fails the build *after* a 14 minute compile, and would break every
# machine that installed the package next to scx-tools. Upstream demoting
# scx-tools to optdepends (b4d44e7) does not change this: any machine that has
# scx-tools installed still hits the collision, so the exclusion stays.
#
# This used to live as a direct edit to packages/scx-scheds-git/PKGBUILD, and
# the next AUR synchronization replaced the file wholesale and silently brought
# the collision back (run 39571220772). It lives here because
# sync-aur-packages.sh re-applies overlays on every sync, so the exclusion
# survives indefinitely.
#
# Matching strategy (2026-11-05, after upstream b4d44e7 broke the previous
# whole-template literal match — runs #103/#104): the exclusion is injected on
# the single line that carries both `-executable` and the upstream
# `! -name '*.so'` predicate, and the marker comment goes above the start of
# the find statement. Everything else in package() may change freely (upstream
# added an `xtask install` step and an extra `! -name 'xtask'` predicate in
# that very commit); only the loss or duplication of the predicate line itself
# fails the overlay, on purpose.
#
# Idempotent: a repeated run leaves the file untouched.

set -Eeuo pipefail

package_dir="${1:?usage: scx-scheds-git.sh <package-dir>}"
pkgbuild="${package_dir}/PKGBUILD"

fail() {
    printf 'scx-scheds-git overlay: %s\n' "$1" >&2
    exit 1
}

[[ -f "$pkgbuild" ]] || fail "PKGBUILD not found in ${package_dir}"

python3 - "$pkgbuild" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = '# emoeem overlay: scxtui belongs to scx-tools'
installed = "! -name 'scxtui'"
so_exclude = "! -name '*.so'"

if installed in text:
    # Already applied (manual run, or a second sync). Nothing to do, but keep
    # the marker so the static gate can still prove the overlay is in effect.
    if marker not in text:
        raise SystemExit(
            'PKGBUILD already excludes scxtui but carries no overlay marker; '
            'restore the upstream file and re-run the sync'
        )
    raise SystemExit(0)

lines = text.splitlines(keepends=True)
hits = [
    i for i, line in enumerate(lines)
    if '-executable' in line and so_exclude in line
]
if len(hits) != 1:
    raise SystemExit(
        f'expected exactly one executable install line carrying {so_exclude}, '
        f'found {len(hits)}; upstream restructured package(), re-check '
        'whether scxtui is still installed unconditionally'
    )

hit = hits[0]
lines[hit] = lines[hit].replace(so_exclude, f'{so_exclude} {installed}', 1)

# The marker must not sit inside a backslash continuation, so anchor it above
# the statement's first line instead of next to the patched predicate.
start = next(
    (i for i in range(hit, -1, -1) if re.match(r'^[ \t]*find\b', lines[i])),
    None,
)
if start is None:
    raise SystemExit(
        'could not locate the start of the executable find statement; '
        'upstream restructured package(), re-check the overlay'
    )
indent = re.match(r'[ \t]*', lines[start]).group(0)
lines.insert(start, f'{indent}{marker}\n')

path.write_text(''.join(lines))
PY
