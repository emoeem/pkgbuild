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

printf 'ELF SONAME fault-injection test passed.\n'
