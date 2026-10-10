#!/usr/bin/env bash
# Fault-injection regression tests for scripts/runtime-verify.sh.
#
# Each fixture ships a deliberately broken payload so a silently-disabled check
# shows up as a missing failure instead of a green run: a dangling symlink, a
# library whose SONAME disagrees with its file name, an executable with an
# unresolved runtime library, and a world-writable file.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

command -v gcc >/dev/null 2>&1 || { printf 'gcc is required for this test; skipping.\n'; exit 0; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pack() {
    local directory="$1" output="$2"
    (
        cd "$directory"
        bsdtar -cf "$output.tar" .PKGINFO usr etc 2>/dev/null ||
            bsdtar -cf "$output.tar" .PKGINFO usr
        zstd -q -f -o "$output" "$output.tar"
        rm -f "$output.tar"
    )
}

printf '%s\n' '1/3: a broken package is rejected with the exact failure classes'

pkg="$work/broken"
mkdir -p "$pkg/usr/bin" "$pkg/usr/lib" "$pkg/etc"
cat >"$work/fake.c" <<'EOF'
int helper(void);
int main(void) { return helper() - 1; }
EOF
cat >"$work/helper.c" <<'EOF'
int helper(void) { return 1; }
EOF
gcc -shared -fPIC -Wl,-soname,libfake.so.1 -o "$pkg/usr/lib/libfake.so.99" "$work/helper.c"
ln -sf libfake.so.99 "$pkg/usr/lib/libfake.so"
gcc -o "$pkg/usr/bin/broken" "$work/fake.c" -L"$pkg/usr/lib" -lfake
rm -f "$pkg/usr/lib/libfake.so"
ln -sf /nonexistent/target "$pkg/usr/lib/libdangling.so"
# A versioned library with no SONAME at all: the quirc 1.2 defect, where the
# installed name promises a version the loader can never resolve.
gcc -shared -fPIC -o "$pkg/usr/lib/libnosoname.so.1" "$work/helper.c"
printf 'x\n' >"$pkg/etc/wide-open.conf"
chmod 777 "$pkg/etc/wide-open.conf"
printf 'pkgname = faultfixture\npkgver = 1.0-1\narch = x86_64\n' >"$pkg/.PKGINFO"
pack "$pkg" "$work/faultfixture.pkg.tar.zst"

if bash "$root/scripts/runtime-verify.sh" --file "$work/faultfixture.pkg.tar.zst" \
    --json-out "$work/report.json" >/dev/null 2>&1; then
    fail 'a broken package passed runtime verification'
fi

python3 - "$work/report.json" <<'PY' || exit 1
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
checks = {finding["check"] for finding in report["findings"]}
expected = {"broken-symlink", "soname-mismatch", "missing-soname", "world-writable", "unresolved-library"}
missing = expected - checks
if missing:
    raise SystemExit(f"missing failure class(es): {sorted(missing)} (got {sorted(checks)})")
if report["status"] != "fail":
    raise SystemExit("report status is not fail")
print(f"  detected: {sorted(checks)}")
PY

printf '%s\n' '2/3: a healthy package passes'
ok="$work/ok"
mkdir -p "$ok/usr/bin" "$ok/usr/lib"
cp /usr/bin/true "$ok/usr/bin/ok-true"
# A versioned library whose SONAME matches its file name is the normal case;
# without it this suite only ever saw a mismatching SONAME, which is how a
# bracket-stripping bug could report every real library as broken.
gcc -shared -fPIC -Wl,-soname,libok.so.1 -o "$ok/usr/lib/libok.so.1" "$work/helper.c"
printf 'pkgname = okfixture\npkgver = 1.0-1\narch = x86_64\n' >"$ok/.PKGINFO"
pack "$ok" "$work/okfixture.pkg.tar.zst"
bash "$root/scripts/runtime-verify.sh" --file "$work/okfixture.pkg.tar.zst" >/dev/null ||
    fail 'a healthy package failed runtime verification'

printf '%s\n' '3/3: smoke manifest expectations are enforced'
smoke="$work/smoke"
mkdir -p "$smoke/usr/bin"
printf 'pkgname = ffmpeg-full\npkgver = 1.0-1\narch = x86_64\n' >"$smoke/.PKGINFO"
pack "$smoke" "$work/smokefixture.pkg.tar.zst"
if bash "$root/scripts/runtime-verify.sh" --file "$work/smokefixture.pkg.tar.zst" >/dev/null 2>&1; then
    fail 'a package missing its declared binaries passed verification'
fi

printf '%s\n' 'All runtime verification tests passed.'
