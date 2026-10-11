#!/usr/bin/env bash
# Keep the local ABI fix on top of each fresh AUR quirc PKGBUILD.
# sync-aur-packages.sh always stages a clean AUR tree before invoking this file.
set -Eeuo pipefail

package_dir="${1:?usage: quirc.sh <package-dir>}"
pkgbuild="$package_dir/PKGBUILD"

fail() {
    printf 'quirc overlay: %s\n' "$1" >&2
    exit 1
}

[[ -f "$pkgbuild" ]] || fail "PKGBUILD not found in ${package_dir}"

python3 - "$pkgbuild" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = '# emoeem overlay: quirc pkgrel bump'

# A fresh AUR file has an unannotated integer pkgrel. If the overlay is run a
# second time, retain the already-adjusted value rather than incrementing again.
if marker not in text:
    match = re.search(r'^pkgrel=([0-9]+(?:\.[0-9]+)*)\s*$', text, re.M)
    if not match:
        raise SystemExit('expected one numeric pkgrel in upstream PKGBUILD')
    parts = match.group(1).split('.')
    parts[-1] = str(int(parts[-1]) + 1)
    adjusted_pkgrel = '.'.join(parts)
    text = text[:match.start()] + f'pkgrel={adjusted_pkgrel}  {marker}' + text[match.end():]

build_old = '''  CFLAGS+=" -fPIC" make libquirc.so quirc-demo quirc-scanner'''
build_new = '''  # emoeem overlay: quirc SONAME compatibility fix
  CFLAGS+=" -fPIC" \\
    LDFLAGS+=" -Wl,-soname,libquirc.so.1" \\
    make libquirc.so quirc-demo quirc-scanner'''
if build_new not in text:
    if text.count(build_old) != 1:
        raise SystemExit('expected the upstream build() command exactly once')
    text = text.replace(build_old, build_new, 1)

install_old = '''  install -Dm644 "libquirc.so.$pkgver" -t "$pkgdir/usr/lib/"
  ln -s "libquirc.so.$pkgver" "$pkgdir/usr/lib/libquirc.so"'''
install_new = '''  install -Dm644 "libquirc.so.$pkgver" -t "$pkgdir/usr/lib/"
  ln -s "libquirc.so.$pkgver" "$pkgdir/usr/lib/libquirc.so.1"
  ln -s "libquirc.so.1" "$pkgdir/usr/lib/libquirc.so"'''
if install_new not in text:
    if text.count(install_old) != 1:
        raise SystemExit('expected the upstream library install/link commands exactly once')
    text = text.replace(install_old, install_new, 1)

path.write_text(text)
PY
