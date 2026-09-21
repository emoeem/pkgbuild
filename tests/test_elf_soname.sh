#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/bin"

cat > "$tmp/lib/fixture.c" <<'SRC'
int fixture_value(void) { return 42; }
SRC
cc -fPIC -shared "$tmp/lib/fixture.c"   -Wl,-soname,libfixture.so.999 -o "$tmp/lib/libfixture.so.999"

ln -s libfixture.so.999 "$tmp/lib/libfixture.so"
cat > "$tmp/bin/main.c" <<'SRC'
extern int fixture_value(void);
int main(void) { return fixture_value() == 42 ? 0 : 1; }
SRC
cc "$tmp/bin/main.c" -L"$tmp/lib"   -Wl,-rpath,'$ORIGIN/../lib' -lfixture -o "$tmp/bin/fixture-test"

printf 'libc.so.6\nlibfixture.so.999\n' > "$tmp/providers-ok"
"$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-ok"

printf 'libfixture.so.998\n' > "$tmp/providers-bad"
if "$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-bad"; then
  echo 'ELF stale detector failed to reject missing SONAME' >&2
  exit 1
fi

make_repo_package() {
  local name="$1" metadata="$2"
  local staging="$tmp/$name"
  mkdir -p "$staging/usr/lib"
  cp "$tmp/lib/libfixture.so.999" "$staging/usr/lib/libfixture.so.999"
  printf '%s\n' "pkgname = $name" "pkgbase = $name" "pkgver = 1" \
    "pkgrel = 1" "arch = x86_64" "$metadata" > "$staging/.PKGINFO"
  tar --zstd --create --file "$tmp/$name-1-1-x86_64.pkg.tar.zst" \
    --directory "$staging" .PKGINFO usr
}

make_repo_package "fixture-provider" "provides = libfixture"
make_repo_package "fixture-alternative" "conflict = libfixture"
mkdir -p "$tmp/repository"
cp "$tmp/fixture-provider-1-1-x86_64.pkg.tar.zst" \
  "$tmp/repository/fixture-provider-1-1-x86_64.pkg.tar.zst"
cp "$tmp/fixture-alternative-1-1-x86_64.pkg.tar.zst" \
  "$tmp/repository/fixture-alternative-1-1-x86_64.pkg.tar.zst"
"$root/scripts/verify-repository-elf.sh" "$tmp/repository"

printf 'ELF SONAME fault-injection test passed.\n'
