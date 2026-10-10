#!/usr/bin/env bash
# Test a repository package upgrade in a disposable CachyOS-v3 chroot.
set -Eeuo pipefail
package_name="${PACKAGE_NAME:?PACKAGE_NAME is required}"
new_dir="${1:?usage: test-upgrade-path.sh NEW_ARTIFACT_DIR OLD_REPOSITORY_DIR CACHE_DIR}"
old_dir="${2:?}"
cache_dir="${3:?}"
case "$package_name" in linuxqq-clipsync-git|sing-box-ebpf) ;; *) echo "Upgrade dry-run is scoped to transition-sensitive linuxqq-clipsync-git and sing-box-ebpf; skipping $package_name."; exit 0 ;; esac
new_pkg="$(find "$new_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit)"
[[ -n "$new_pkg" ]] || { echo "No newly built package in $new_dir" >&2; exit 2; }
new_name="$(bsdtar -xOf "$new_pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
[[ "$new_name" == "$package_name" ]] || { echo "Expected $package_name, got $new_name" >&2; exit 2; }
old_package_name="$package_name"
if [[ "$package_name" == sing-box-ebpf ]]; then old_package_name=sing-box; fi
old_pkg="$(find "$old_dir" -maxdepth 1 -type f -name "$old_package_name-*.pkg.tar.zst" -print -quit)"
if [[ -z "$old_pkg" && "$package_name" != sing-box-ebpf ]]; then
    echo "UPGRADE_PATH=UNVERIFIABLE: no previous $package_name package in the published repository; no upgrade success is claimed." >&2
    exit 0
fi
base_config="$cache_dir/chroot/pacman-base.conf"
[[ -f "$base_config" ]] || { echo "Clean chroot baseline config missing: $base_config" >&2; exit 2; }
work="$(mktemp -d "$cache_dir/chroot/upgrade-${package_name}.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT INT TERM
mkdir -p "$work/root"
baseline_root="$(find "$cache_dir/chroot" -mindepth 2 -maxdepth 2 -type d -path '*/baseline-*/root' -print -quit)"
if [[ -n "$baseline_root" ]]; then
    cp --reflink=auto -a "$baseline_root/." "$work/root/"
else
    baseline_archive="$(find "$cache_dir/chroot" -maxdepth 1 -type f -name 'baseline-*.tar.zst' -print -quit)"
    [[ -n "$baseline_archive" ]] || { echo 'No cached clean-chroot baseline exists for upgrade test.' >&2; exit 2; }
    mkdir -p "$work/baseline"
    tar --zstd -xf "$baseline_archive" -C "$work/baseline"
    cp --reflink=auto -a "$work/baseline/root/." "$work/root/"
fi
repo_dir="$work/root/tmp/upgrade-repo"
mkdir -p "$repo_dir"
# Include the previous repository package set so private dependencies remain
# resolvable in the disposable chroot. Replace the old target package with the
# artifact built in this run before generating the temporary database.
while IFS= read -r -d '' package; do
    cp -f -- "$package" "$repo_dir/"
done < <(find "$old_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0)
if [[ -n "$old_pkg" ]]; then cp -f -- "$old_pkg" "$work/root/tmp/old.pkg.tar.zst"; fi
new_pkgname="$(bsdtar -xOf "$new_pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
[[ -n "$new_pkgname" ]] || { echo "Missing pkgname in $new_pkg" >&2; exit 2; }
find "$repo_dir" -maxdepth 1 -type f -name "${new_pkgname}-*.pkg.tar.zst" -delete
cp -f -- "$new_pkg" "$repo_dir/"
repo-add --remove "$repo_dir/emoeem-staging.db.tar.gz" "$repo_dir/"*.pkg.tar.zst
python3 - "$work/root/etc/pacman.conf" <<'PYCONF'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
match = re.search(r'(?m)^\[cachyos-v3\]\s*$', text)
if not match:
    raise SystemExit('Upgrade chroot config lost the cachyos-v3 repository')
staging = '[emoeem-staging]\nSigLevel = Never\nServer = file:///tmp/upgrade-repo\n\n'
path.write_text(text[:match.start()] + staging + text[match.start():], encoding='utf-8')
PYCONF
arch-nspawn "$work/root" pacman -Syu --noconfirm
if [[ "$package_name" == sing-box-ebpf ]]; then
    # The transition is from an upstream package name, not an older private
    # release. Install the official package, then let pacman apply conflicts / provides.
    arch-nspawn "$work/root" pacman -S --needed --noconfirm cachyos-v3/sing-box
else
    mapfile -t dependencies < <(bsdtar -xOf "$old_pkg" .PKGINFO | awk -F ' = ' '$1 == "depend" {print $2}')
    if ((${#dependencies[@]} > 0)); then arch-nspawn "$work/root" pacman -S --needed --noconfirm "${dependencies[@]}"; fi
    # Install the old private release first to exercise the upgrade transaction.
    arch-nspawn "$work/root" pacman -U --noconfirm /tmp/old.pkg.tar.zst
fi
arch-nspawn "$work/root" pacman -Syu --noconfirm "$package_name"
installed="$(arch-nspawn "$work/root" pacman -Q "$package_name")"
if [[ "$package_name" == sing-box-ebpf ]]; then
    if arch-nspawn "$work/root" pacman -Q sing-box >/dev/null 2>&1; then
        echo 'Upgrade path failed: official sing-box remains installed after installing sing-box-ebpf.' >&2
        exit 1
    fi
    echo 'Replacement path passed: official sing-box was replaced by sing-box-ebpf.'
fi
printf 'UPGRADE_PATH=PASS: %s\n' "$installed"
