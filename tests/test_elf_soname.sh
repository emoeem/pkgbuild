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

# pacman spells a SONAME provide differently than the dynamic linker
# (libfixture.so=999-64 versus libfixture.so.999); the check has to normalise
# that, otherwise every repository package looks broken.
printf 'libc.so.6\nlibfixture.so=999-64\n' > "$tmp/providers-ok"
"$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-ok"

printf 'libfixture.so.998\n' > "$tmp/providers-bad"
if "$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-bad"; then
  echo 'ELF stale detector failed to reject missing SONAME' >&2
  exit 1
fi

# SONAMEs containing regular-expression metacharacters (libstdc++.so.6,
# libatk-1.0.so.0, ...) must be matched literally, not as a pattern.
cc -fPIC -shared "$tmp/lib/fixture.c" -Wl,-soname,'libfixture++.so.999' \
  -o "$tmp/lib/libfixture++.so.999"
ln -sf 'libfixture++.so.999' "$tmp/lib/libfixture++.so"
cc "$tmp/bin/main.c" -L"$tmp/lib" -Wl,-rpath,'$ORIGIN/../lib' \
  -l'fixture++' -o "$tmp/bin/fixture-plus-test"
printf 'libc.so.6\nlibfixture.so.999\nlibfixture++.so.999\n' > "$tmp/providers-plus"
"$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-plus"

# A localized environment used to translate the readelf label, turning every
# NEEDED entry into an unmatched string ("共享库：[libfixture.so.999]").
for candidate in zh_CN.UTF-8 zh_CN.utf8 ja_JP.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
  if locale -a 2>/dev/null | grep -qxF "$candidate"; then
    LC_ALL="$candidate" "$root/scripts/check-elf-needed.sh" "$tmp" "$tmp/providers-plus"
    printf 'LC_ALL=%s regression check passed.\n' "$candidate"
    break
  fi
done

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
