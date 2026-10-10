#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/verify-publish-inputs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/incoming" "$tmp/source/packages"

cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
cat "$MOCK_PKGINFO"
MOCK
chmod +x "$tmp/bin/bsdtar"

make_case() {
    local name="$1" source_ver="$2" source_rel="$3" actual="$4" dynamic="$5"
    local package_dir="$tmp/source/packages/$name"
    mkdir -p "$package_dir"
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n' "$name" "$source_ver" "$source_rel" > "$package_dir/.SRCINFO"
    {
        printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n' "$name" "$source_ver" "$source_rel"
        if [[ "$dynamic" == yes ]]; then
            printf 'pkgver() { echo dynamic; }\n'
        fi
    } > "$package_dir/PKGBUILD"
    touch "$tmp/incoming/$name-$actual-x86_64.pkg.tar.zst"
    printf 'pkgname = %s\npkgver = %s\n' "$name" "$actual" > "$tmp/pkginfo"
}

run_case() {
    PATH="$tmp/bin:$PATH" MOCK_PKGINFO="$tmp/pkginfo" \
        bash "$script" "$tmp/incoming" "$tmp/source"
}

# A VCS package may resolve pkgver() to a newer commit than its checked-in .SRCINFO.
make_case svt-jpeg-xs-git 0.9.0.r5.ge0940ac 1 0.9.0.r123.ge5a61be-1 yes
output="$(run_case)"
grep -q 'Accepted resolved git pkgver for svt-jpeg-xs-git' <<<"$output"
echo 'ok: resolved VCS pkgver is accepted when stable prefix and pkgrel match'

# A regular package still requires an exact source version (unless pkgrel is intentionally bumped).
rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-1 no
output="$(run_case)"
[[ -z "$output" ]]
echo 'ok: exact static package version is accepted'

rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.1-1 no
if output="$(run_case 2>&1)"; then
    echo 'expected static version mismatch to fail' >&2
    exit 1
fi
grep -q 'Publication mismatch for stable-demo' <<<"$output"
echo 'ok: static package version mismatch is rejected'

rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-2 no
output="$(run_case)"
grep -q 'Accepted bumped pkgrel for stable-demo' <<<"$output"
echo 'ok: intentional pkgrel bump is accepted'
