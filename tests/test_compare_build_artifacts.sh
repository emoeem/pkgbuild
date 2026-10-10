#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/compare-build-artifacts.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
make_artifact() {
  local path="$1" dependency_version="$2" package_version="$3"
  local dir="$tmp/package"
  rm -rf "$dir"; mkdir -p "$dir/usr/share/demo"
  printf 'installed = demo-dependency-%s\ninstalled = glibc-2.0-1\n' "$dependency_version" > "$dir/.BUILDINFO"
  printf 'pkgname = demo\npkgver = %s\npkgarch = x86_64\n' "$package_version" > "$dir/.PKGINFO"
  printf 'content %s\n' "$package_version" > "$dir/usr/share/demo/content.txt"
  bsdtar -cf "$path" -C "$dir" .BUILDINFO .PKGINFO usr
}
make_artifact "$tmp/legacy.pkg.tar.zst" 1.0-1 1.0-1
make_artifact "$tmp/chroot.pkg.tar.zst" 1.1-1 1.0-1
"$script" "$tmp/legacy.pkg.tar.zst" "$tmp/chroot.pkg.tar.zst" "$tmp/pass.json" >/dev/null
python3 - "$tmp/pass.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result['pass'] is True
assert result['dependency_versions']['not_older'] is True
assert 'files' in result['sections'] and 'ldd' in result['sections'] and 'PKGINFO' in result['sections']
PY
make_artifact "$tmp/old-chroot.pkg.tar.zst" 0.9-1 1.0-1
if "$script" "$tmp/legacy.pkg.tar.zst" "$tmp/old-chroot.pkg.tar.zst" "$tmp/fail.json" >/dev/null 2>&1; then
  echo 'comparison should fail when chroot dependency is older than legacy' >&2
  exit 1
fi
python3 - "$tmp/fail.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result['pass'] is False
assert result['dependency_versions']['older_than_legacy'] == ['demo-dependency']
PY
printf 'artifact comparison tests passed: dependency versions and machine-readable diff\n'
