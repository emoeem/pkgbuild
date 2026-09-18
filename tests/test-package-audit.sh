#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Keep the production audit testable in a tiny fixture. The fixture provides
# makepkg-readable PKGBUILDs and checks duplicate providers/self dependencies.
mkdir -p "$work/packages/demo-a" "$work/packages/demo-b"

cat > "$work/packages/demo-a/PKGBUILD" <<'EOF'
pkgname=demo-a
pkgver=1
pkgrel=1
arch=(x86_64)
provides=(demo-virtual)
EOF

cat > "$work/packages/demo-b/PKGBUILD" <<'EOF'
pkgname=demo-b
pkgver=1
pkgrel=1
arch=(x86_64)
depends=(demo-virtual)
EOF

if ! command -v makepkg >/dev/null 2>&1; then
    echo 'makepkg is required for package audit tests.' >&2
    exit 2
fi
(cd "$work/packages/demo-a" && makepkg --printsrcinfo > .SRCINFO)
(cd "$work/packages/demo-b" && makepkg --printsrcinfo > .SRCINFO)

bash -n "$root/scripts/audit-packages.sh"
bash -n "$root/tests/test-package-audit.sh"
AUDIT_ROOT="$work" "$root/scripts/audit-packages.sh" >/dev/null

# A duplicate virtual provider must be rejected.
sed -i 's/pkgname=demo-b/pkgname=demo-b\nprovides=(demo-virtual)/' "$work/packages/demo-b/PKGBUILD"
(cd "$work/packages/demo-b" && makepkg --printsrcinfo > .SRCINFO)
if AUDIT_ROOT="$work" "$root/scripts/audit-packages.sh" >/dev/null 2>&1; then
    echo 'duplicate provider was not rejected' >&2
    exit 1
fi

printf 'package audit regression tests passed\n'
