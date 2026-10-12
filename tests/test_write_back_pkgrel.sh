#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/write-back-pkgrel.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# bsdtar is only asked for the .PKGINFO of the built package; stubbing it keeps
# the test free of real package files.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
cat "$MOCK_PKGINFO"
MOCK
chmod +x "$tmp/bin/bsdtar"

source_tree="$tmp/source"
mkdir -p "$tmp/remote.git" "$source_tree/packages/ffmpeg-full"
git init -q --bare "$tmp/remote.git"
git init -q -b main "$source_tree"
printf 'pkgbase = ffmpeg-full\n\tpkgver = 9.0.2\n\tpkgrel = 2.6\n' \
    > "$source_tree/packages/ffmpeg-full/.SRCINFO"
printf 'pkgver=9.0.2\npkgrel=2.6\n' > "$source_tree/packages/ffmpeg-full/PKGBUILD"
git -C "$source_tree" -c user.name=test -c user.email=test@example.invalid add -A
git -C "$source_tree" -c user.name=test -c user.email=test@example.invalid commit -qm init
git -C "$source_tree" remote add origin "$tmp/remote.git"
git -C "$source_tree" push -q origin main

mkdir -p "$tmp/incoming/ffmpeg-full"
: > "$tmp/incoming/ffmpeg-full/ffmpeg-full-9.0.2-2.7-x86_64.pkg.tar.zst"

# makepkg writes the whole `[epoch:]pkgver-pkgrel` into a single .PKGINFO field
# (`pkgver = 9.0.2-2.7`) and no pkgrel line at all, which is what this fixture
# reproduces.
write_pkginfo() {
    printf 'pkgname = ffmpeg-full\npkgbase = ffmpeg-full\npkgver = %s\n' "$1" > "$tmp/pkginfo"
}

run_back() {
    PATH="$tmp/bin:$PATH" MOCK_PKGINFO="$tmp/pkginfo" \
        bash "$script" "$tmp/incoming" "$source_tree" 2>&1
}

write_pkginfo 9.0.2-2.7
output="$(run_back)"
grep -q 'WROTE BACK ffmpeg-full: pkgrel 2.6 -> 2.7' <<<"$output"
grep -qx 'pkgrel=2.7' "$source_tree/packages/ffmpeg-full/PKGBUILD"
grep -qP '^\tpkgrel = 2\.7$' "$source_tree/packages/ffmpeg-full/.SRCINFO"
grep -q 'write back bumped pkgrel for ffmpeg-full' \
    <<<"$(git -C "$source_tree" log -1 --format=%s)"
echo 'ok: a built package writes its bumped pkgrel back to PKGBUILD and .SRCINFO'

# An epoch still splits at the last dash: 1:4.7.0-2.7 -> pkgver 1:4.7.0.
printf 'pkgname = ffmpeg-full\npkgbase = ffmpeg-full\npkgver = 1:9.0.2-2.7\n' > "$tmp/pkginfo"
output="$(run_back)"
grep -q 'SKIP ffmpeg-full: source pkgver 9.0.2 already differs from built 1:9.0.2' <<<"$output"
grep -qx 'pkgrel=2.7' "$source_tree/packages/ffmpeg-full/PKGBUILD"
echo 'ok: an epoch does not shift the pkgver/pkgrel split'

write_pkginfo 9.0.2-2.7
output="$(run_back)"
grep -q 'No pkgrel write-back needed.' <<<"$output"
[[ "$(git -C "$source_tree" log --format=%s | grep -c 'write back bumped pkgrel')" == 1 ]]
echo 'ok: an already aligned package writes nothing back and commits nothing'

write_pkginfo 9.0.3-2.9
output="$(run_back)"
grep -q 'SKIP ffmpeg-full: source pkgver 9.0.2 already differs from built 9.0.3' <<<"$output"
grep -qx 'pkgrel=2.7' "$source_tree/packages/ffmpeg-full/PKGBUILD"
echo 'ok: a moved upstream pkgver leaves the source tree pkgrel alone'
