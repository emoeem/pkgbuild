#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mpv_repo='https://github.com/mpv-player/mpv.git'
track="${1:-all}"
[[ "$track" =~ ^(stable|development|all)$ ]] || { echo 'Usage: sync-mpv-tracks.sh [stable|development|all]' >&2; exit 2; }

regen_srcinfo() {
    local dir="$1"
    (cd "$dir" && makepkg --printsrcinfo > .SRCINFO)
}

fetch() {
    local url="$1" out="$2"
    if command -v aria2c >/dev/null 2>&1; then
        aria2c -q -x 4 -s 4 --file-allocation=none --max-tries=8 --retry-wait=3 -o "$(basename "$out")" -d "$(dirname "$out")" "$url"
    else
        curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 -o "$out" "$url"
    fi
}

latest_omniphony_release() {
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
        https://api.github.com/repos/mgth/mpv-omniphony/releases/latest |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

sync_patch_sources() {
    local tag="$1" work="$2" d="$3"
    fetch "https://github.com/mgth/mpv-omniphony/archive/refs/tags/${tag}.tar.gz" "$work/omniphony.tar.gz"
    tar -xzf "$work/omniphony.tar.gz" -C "$work"
    d="$work/mpv-omniphony-${tag#v}"
    test -d "$d/patches" && test -d "$d/patches-master"
    rm -f "$root"/packages/mpv-emo/patches/*.patch
    rm -f "$root"/packages/mpv-emo-git/patches/*.patch
    cp "$d"/patches/*.patch "$root"/packages/mpv-emo/patches/
    cp "$d"/patches-master/*.patch "$root"/packages/mpv-emo-git/patches/
}

verify_patches() {
    local src="$1" patch_dir="$2"; shift 2
    cd "$src"
    for p in "$patch_dir"/*.patch; do
        patch -Np1 < "$p" >/dev/null || return 1
    done
}

sync_stable() {
    local tag pkg work checksum
    tag="$(git ls-remote --tags --refs "$mpv_repo" 'refs/tags/v*' | awk -F/ '$NF ~ /^v[0-9]+\.[0-9]+(\.[0-9]+)?$/ {print $NF}' | sort -V | tail -n1)"
    pkg="${tag#v}"
    work="$(mktemp -d)"
    fetch "https://github.com/mpv-player/mpv/archive/refs/tags/${tag}.tar.gz" "$work/mpv.tar.gz"
    checksum="$(sha256sum "$work/mpv.tar.gz" | awk '{print $1}')"
    local omni_tag omni_mpv
    omni_tag="$(latest_omniphony_release)"
    omni_mpv="$(curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 \
        "https://raw.githubusercontent.com/mgth/mpv-omniphony/${omni_tag}/packaging/PKGBUILD" |
        sed -nE 's/^_mpvver=([^[:space:]]+).*/\1/p' | head -n1)"
    if [[ "$omni_mpv" != "$pkg" ]]; then
        echo "Stable: Omniphony ${omni_tag} targets mpv ${omni_mpv}, not ${pkg}; keep current Stable." >&2
        return 0
    fi
    sync_patch_sources "$omni_tag" "$work" ''
    sed -i -E "s/^pkgver=.*/pkgver=${pkg}/" "$root/packages/mpv-emo/PKGBUILD"
    sed -i -E "s/^sha256sums=.*/sha256sums=('${checksum}')/" "$root/packages/mpv-emo/PKGBUILD"
    printf 'MPV_STABLE_TAG=%s\nMPV_STABLE_SHA256=%s\nOMNIPHONY_PATCH_TAG=%s\n' "$tag" "$checksum" "$omni_tag" > "$root/tracks/mpv/stable.env"
    regen_srcinfo "$root/packages/mpv-emo"
    echo "Stable: ${tag}; core patches: ${omni_tag}"
}

sync_development() {
    local commit short work
    commit="$(git ls-remote "$mpv_repo" refs/heads/master | awk '{print $1}')"
    short="${commit:0:9}"
    work="$(mktemp -d)"
    git clone -q --depth 1 "$mpv_repo" "$work/mpv"
    if ! verify_patches "$work/mpv" "$root/packages/mpv-emo-git/patches"; then
        echo "Development: current mpv master ${commit} is not compatible with the tracked core Patch series; skip publication." >&2
        return 0
    fi
    sed -i -E "s/#commit=[0-9a-f]+\x27\)/#commit=${commit}')/" "$root/packages/mpv-emo-git/PKGBUILD"
    sed -i -E "s/^pkgver=.*/pkgver=0.0.0.r0.g${short}/" "$root/packages/mpv-emo-git/PKGBUILD"
    printf 'MPV_DEVELOPMENT_COMMIT=%s\nMPV_DEVELOPMENT_FULL_COMMIT=%s\n' "$short" "$commit" > "$root/tracks/mpv/development.env"
    regen_srcinfo "$root/packages/mpv-emo-git"
    echo "Development: master ${commit}; core patches compatible"
}

case "$track" in
    stable) sync_stable ;;
    development) sync_development ;;
    all) sync_stable; sync_development ;;
esac
