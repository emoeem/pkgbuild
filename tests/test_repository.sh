#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT

mkdir -p "$temp/incoming" "$temp/repository"

make_package() {
    local name="$1" version="$2"
    local staging="$temp/staging-${name}"
    mkdir -p "$staging"
    cat > "$staging/.PKGINFO" <<EOF
pkgname = ${name}
pkgbase = ${name}
pkgver = ${version}
pkgdesc = integration test package
url = https://example.invalid/${name}
builddate = 0
packager = integration test
size = 1
arch = x86_64
license = MIT
EOF
    printf 'test payload\n' > "$staging/payload.txt"
    tar --zstd --create --file "$temp/incoming/${name}-${version}-1-x86_64.pkg.tar.zst" \
        --directory "$staging" .PKGINFO payload.txt
}

make_package "epoch-demo" "1:2.0"

INCOMING_DIR="$temp/incoming" \
REPOSITORY_DIR="$temp/repository" \
REPOSITORY_NAME="emoeem" \
REMOVE_PACKAGES_FILE="$temp/remove-empty" \
REPOSITORY_SERVER="file:///tmp/emoeem-test/x86_64" \
  bash "$root/scripts/create-repository.sh" >/dev/null

[[ -f "$temp/repository/epoch-demo-1.2.0-1-x86_64.pkg.tar.zst" ]]
[[ -f "$temp/repository/emoeem.db" ]]
[[ -f "$temp/repository/emoeem.files" ]]
[[ -f "$temp/repository/emoeem.conf" ]]
[[ -f "$temp/repository/SHA256SUMS" ]]

bsdtar -xOf "$temp/repository/emoeem.db" 'epoch-demo-1:2.0/desc' |
    grep -Fxq 'epoch-demo-1.2.0-1-x86_64.pkg.tar.zst'
if bsdtar -xOf "$temp/repository/emoeem.db" 'epoch-demo-1:2.0/desc' |
    grep -Fq 'epoch-demo-1:2.0-1-x86_64.pkg.tar.zst'; then
    echo 'repository database retained an unsanitized GitHub asset filename' >&2
    exit 1
fi

mkdir -p "$temp/empty"
printf 'epoch-demo\n' > "$temp/remove"
INCOMING_DIR="$temp/empty" \
REPOSITORY_DIR="$temp/repository" \
REPOSITORY_NAME="emoeem" \
REMOVE_PACKAGES_FILE="$temp/remove" \
REPOSITORY_SERVER="file:///tmp/emoeem-test/x86_64" \
  bash "$root/scripts/create-repository.sh" >/dev/null

if find "$temp/repository" -maxdepth 1 -name 'epoch-demo-*.pkg.tar.zst' -print -quit | grep -q .; then
    echo 'removed package still exists in repository' >&2
    exit 1
fi

printf 'repository integration tests passed\n'
