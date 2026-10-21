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
# machine that installed the package next to scx-tools.
#
# This used to live as a direct edit to packages/scx-scheds-git/PKGBUILD, and
# the next AUR synchronization replaced the file wholesale and silently brought
# the collision back (run 39571220772). It lives here because
# sync-aur-packages.sh re-applies overlays on every sync, so the exclusion
# survives indefinitely.
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
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = '# emoeem overlay: scxtui belongs to scx-tools'
installed = "! -name 'scxtui'"

if installed in text:
    # Already applied (manual run, or a second sync). Nothing to do, but keep
    # the marker so the static gate can still prove the overlay is in effect.
    if marker not in text:
        raise SystemExit(
            'PKGBUILD already excludes scxtui but carries no overlay marker; '
            'restore the upstream file and re-run the sync'
        )
    raise SystemExit(0)

upstream = """  # Install all built executables (skip .so and .d files)
  find target/release \\
    -maxdepth 1 -type f -executable ! -name '*.so' \\
"""
patched = f"""  {marker}
  # Install all built executables (skip .so files; scxtui belongs to scx-tools)
  find target/release \\
    -maxdepth 1 -type f -executable ! -name '*.so' {installed} \\
"""

if text.count(upstream) != 1:
    raise SystemExit(
        'expected the upstream package() executables rule exactly once; '
        'upstream restructured package(), re-check whether scxtui is still '
        'installed unconditionally'
    )

path.write_text(text.replace(upstream, patched, 1))
PY
