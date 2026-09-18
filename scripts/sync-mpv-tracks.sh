#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly mpv_repo='https://github.com/mpv-player/mpv.git'

usage() { printf 'Usage: %s [stable|development|optional|all]\n' "$(basename "$0")"; }
track="${1:-all}"
[[ "$track" =~ ^(stable|development|optional|all)$ ]] || { usage >&2; exit 2; }

regen_srcinfo() {
    local package_dir="$1"
    if command -v makepkg >/dev/null 2>&1; then
        (cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO)
        return
    fi
    command -v docker >/dev/null 2>&1 || {
        echo 'makepkg or docker is required to regenerate .SRCINFO' >&2
        exit 1
    }
    docker run --rm \
        --volume "$root:/workspace" \
        docker.io/library/archlinux:base-devel \
        bash -c "cd /workspace && cd '${package_dir#"$root/"}' && makepkg --printsrcinfo > .SRCINFO"
}

fetch_sha256() {
    local url="$1" output="$2"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -q -x 4 -s 4 --file-allocation=none --allow-overwrite=true \
            --max-tries=10 --retry-wait=3 -o "$(basename "$output")" \
            -d "$(dirname "$output")" "$url"
    else
        curl -fL --retry 10 --retry-all-errors --retry-delay 3 \
            --connect-timeout 30 -o "$output" "$url"
    fi
    sha256sum "$output" | awk '{print $1}'
}

sync_stable() {
    local latest tag archive checksum pkg
    latest="$(git ls-remote --tags --refs "$mpv_repo" 'refs/tags/v*' |
        awk -F/ '$NF ~ /^v[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $NF}' |
        sort -V | tail -n1)"
    [[ -n "$latest" ]] || { echo 'Unable to determine latest mpv release' >&2; exit 1; }
    tag="$latest"
    pkg="${tag#v}"
    if grep -Fxq "MPV_STABLE_TAG=${tag}" "$root/tracks/mpv/stable.env" 2>/dev/null; then
        echo "Stable: ${tag} already synchronized"
        return 0
    fi
    archive="$(mktemp --suffix=.tar.gz)"
    checksum="$(fetch_sha256 "https://github.com/mpv-player/mpv/archive/refs/tags/${tag}.tar.gz" "$archive")"
    rm -f "$archive"

    sed -i -E "s/^pkgver=.*/pkgver=${pkg}/" "$root/packages/mpv-emo/PKGBUILD"
    sed -i -E "s/^sha256sums=\('.*'\)/sha256sums=('${checksum}')/" "$root/packages/mpv-emo/PKGBUILD"
    printf 'MPV_STABLE_TAG=%s\nMPV_STABLE_SHA256=%s\n' "$tag" "$checksum" > "$root/tracks/mpv/stable.env"
    regen_srcinfo "$root/packages/mpv-emo"
    echo "Stable: ${tag} (${checksum})"
}

sync_development() {
    local commit short
    commit="$(git ls-remote "$mpv_repo" refs/heads/master | awk '{print $1}')"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'Unable to resolve mpv master' >&2; exit 1; }
    short="${commit:0:9}"
    if grep -Fxq "MPV_DEVELOPMENT_FULL_COMMIT=${commit}" "$root/tracks/mpv/development.env" 2>/dev/null; then
        echo "Development: ${commit} already synchronized"
        return 0
    fi
    sed -i -E "s/#commit=[0-9a-f]+\x27\)/#commit=${commit}')/" "$root/packages/mpv-emo-git/PKGBUILD"
    sed -i -E "s/^pkgver=.*/pkgver=0.0.0.r0.g${short}/" "$root/packages/mpv-emo-git/PKGBUILD"
    printf 'MPV_DEVELOPMENT_COMMIT=%s\nMPV_DEVELOPMENT_FULL_COMMIT=%s\n' "$short" "$commit" > "$root/tracks/mpv/development.env"
    regen_srcinfo "$root/packages/mpv-emo-git"
    echo "Development: master ${commit}"
}

sync_optional() {
    local tag version mpvver archive mpv_archive checksum1 checksum2 metadata
    tag="$(curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
        --connect-timeout 30 "https://api.github.com/repos/mgth/mpv-omniphony/releases/latest" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Unable to determine latest Omniphony release: $tag" >&2
        exit 1
    }
    if grep -Fxq "OMNIPHONY_TAG=${tag}" "$root/tracks/mpv/optional.env" 2>/dev/null; then
        echo "Optional: Omniphony ${tag} already synchronized"
        return 0
    fi
    version="${tag#v}"
    metadata="$(curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
        "https://raw.githubusercontent.com/mgth/mpv-omniphony/${tag}/packaging/PKGBUILD")"
    mpvver="$(sed -nE 's/^_mpvver=([^[:space:]]+).*/\1/p' <<< "$metadata" | head -n1)"
    [[ -n "$mpvver" ]] || { echo "Omniphony ${tag} does not declare _mpvver" >&2; exit 1; }

    archive="$(mktemp --suffix=.tar.gz)"
    mpv_archive="$(mktemp --suffix=.tar.gz)"
    checksum1="$(fetch_sha256 "https://github.com/mpv-player/mpv/archive/refs/tags/v${mpvver}.tar.gz" "$mpv_archive")"
    checksum2="$(fetch_sha256 "https://github.com/mgth/mpv-omniphony/archive/refs/tags/${tag}.tar.gz" "$archive")"
    rm -f "$archive" "$mpv_archive"

    sed -i -E "s/^pkgver=.*/pkgver=${version}/" "$root/packages/mpv-emo-omniphony/PKGBUILD"
    sed -i -E "s/^_mpvver=.*/_mpvver=${mpvver}/" "$root/packages/mpv-emo-omniphony/PKGBUILD"
    sed -i -E "s/^_omniphony_tag=.*/_omniphony_tag=${tag}/" "$root/packages/mpv-emo-omniphony/PKGBUILD"
    sed -i -E "s/^sha256sums=.*/sha256sums=('${checksum1}'/" "$root/packages/mpv-emo-omniphony/PKGBUILD"
    sed -i -E "0,/^[[:space:]]+'[0-9a-f]{64}')$/s//            '${checksum2}')/" "$root/packages/mpv-emo-omniphony/PKGBUILD"
    regen_srcinfo "$root/packages/mpv-emo-omniphony"
    printf 'OMNIPHONY_TAG=%s\nOMNIPHONY_MPV=%s\n' "$tag" "$mpvver" > "$root/tracks/mpv/optional.env"
    echo "Optional: Omniphony ${tag} on mpv ${mpvver}"
}

case "$track" in
    stable) sync_stable ;;
    development) sync_development ;;
    optional) sync_optional ;;
    all) sync_stable; sync_development; sync_optional ;;
esac
