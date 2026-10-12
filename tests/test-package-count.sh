#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/scripts" "$work/packages/a" "$work/packages/b"
cp "$root/scripts/count-packages.sh" "$work/scripts/count-packages.sh"
printf '#!/usr/bin/env bash\n' > "$work/packages/a/PKGBUILD"
printf '#!/usr/bin/env bash\n' > "$work/packages/b/PKGBUILD"
printf '当前维护 2 个 package base。\n' > "$work/README.md"
bash "$work/scripts/count-packages.sh"
printf '当前维护 3 个 package base。\n' > "$work/README.md"
if bash "$work/scripts/count-packages.sh" >/dev/null 2>&1; then
    printf 'count checker accepted a mismatched README.\n' >&2; exit 1
fi
printf 'Package count regression test passed.\n'
