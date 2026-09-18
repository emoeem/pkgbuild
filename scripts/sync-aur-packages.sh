#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly repo_root

if (( $# == 0 )); then
    mapfile -t package_names < <(
        find "$repo_root/packages" -mindepth 2 -maxdepth 2 -type f -name .aur-url \
            -printf '%h\n' | xargs -r -n1 basename | sort -u
    )
else
    package_names=("$@")
fi
(( ${#package_names[@]} > 0 )) || { echo 'No AUR-managed packages selected.' >&2; exit 1; }

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

for package_name in "${package_names[@]}"; do
    if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
        printf 'Invalid package name: %s\n' "$package_name" >&2
        exit 2
    fi
    package_dir="$repo_root/packages/$package_name"
    aur_url_file="$package_dir/.aur-url"
    [[ -f "$aur_url_file" ]] || { echo "$package_name is not AUR-managed (.aur-url missing)." >&2; exit 1; }
    aur_url="$(<"$aur_url_file")"
    checkout_dir="$temporary_dir/$package_name"
    git clone --depth 1 "$aur_url" "$checkout_dir"
    aur_commit="$(git -C "$checkout_dir" rev-parse HEAD)"

    # Stage the upstream tree separately. A failed overlay or package audit must
    # never destroy the current working package directory.
    staged_dir="$temporary_dir/staged-$package_name"
    mkdir -p "$staged_dir"
    cp -a "$checkout_dir"/. "$staged_dir"/
    rm -rf "$staged_dir/.git"
    printf '%s\n' "$aur_url" > "$staged_dir/.aur-url"
    printf '%s\n' "$aur_commit" > "$staged_dir/.aur-commit"

    overlay="$repo_root/scripts/overlays/$package_name.sh"
    if [[ -f "$overlay" ]]; then
        printf 'Applying local overlay for %s...\n' "$package_name"
        bash "$overlay" "$staged_dir"
    fi
    if [[ ! -f "$staged_dir/PKGBUILD" ]]; then
        printf '%s: upstream tree has no PKGBUILD.\n' "$package_name" >&2
        exit 1
    fi
    if ! (cd "$staged_dir" && BUILDDIR="$temporary_dir/build" SRCDEST="$temporary_dir/src" \
        PKGDEST="$temporary_dir/pkg" LOGDEST="$temporary_dir/log" makepkg --printsrcinfo > .SRCINFO); then
        printf '%s: failed to generate .SRCINFO after overlay.\n' "$package_name" >&2
        exit 1
    fi
    if ! bash -n "$staged_dir/PKGBUILD"; then
        printf '%s: PKGBUILD syntax check failed after overlay.\n' "$package_name" >&2
        exit 1
    fi
    if [[ -f "$package_dir/PKGBUILD" ]]; then
        old_commit="$(cat "$package_dir/.aur-commit" 2>/dev/null || true)"
        if [[ "$old_commit" == "$aur_commit" ]]; then
            printf '%s: AUR commit unchanged; checking overlay state only.\n' "$package_name"
        else
            printf '%s: AUR updated %s -> %s.\n' "$package_name" "${old_commit:-<none>}" "$aur_commit"
        fi
    fi

    rm -rf "$package_dir"
    mkdir -p "$(dirname "$package_dir")"
    mv "$staged_dir" "$package_dir"
done

"$repo_root/scripts/check-package.sh" "${package_names[@]}"
printf 'AUR synchronization completed transactionally for %d package(s).\n' "${#package_names[@]}"
