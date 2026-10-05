#!/usr/bin/env bash
# Repository install test: the last gate before publishing.
#
# Everything up to here has only proven that a package *file* is consistent.
# This installs the freshly built packages from the repository into a throwaway
# container, resolving their dependencies from that same repository, and then
# runs runtime verification against the installed result.
#
# A repository that cannot satisfy its own packages is not published.
#
# Runs inside the CachyOS/Arch container. Inputs are paths so it can also be
# exercised by hand:
#
#   /repository   the repository directory (db + files db + packages)
#   /incoming     freshly built packages, one directory per package base
#
# Environment:
#   REPOSITORY_NAME      pacman repository name (default: emoeem)
#   INSTALL_TEST_ALL=1   also install packages that pull a very large closure
#   INSTALL_TEST_SKIP    comma separated package names to skip
set -Eeuo pipefail

# Tool output (pacman, ldd, readelf) is parsed below; a localized label would
# turn a check into a silent no-op.
export LC_ALL=C

repository_dir="${REPOSITORY_DIR:-/repository}"
incoming_dir="${INCOMING_DIR:-/incoming}"
repository_name="${REPOSITORY_NAME:-emoeem}"
workspace_dir="${WORKSPACE_DIR:-/workspace}"
install_all="${INSTALL_TEST_ALL:-0}"
skip_list="${INSTALL_TEST_SKIP:-}"

# Packages whose install closure is too large for the publication window; they
# are still covered by the per-package runtime verification in the build job.
heavy_default="ffmpeg-full daed-emo sing-box-ebpf scx-scheds-git vapoursynth-plugin-mlrt-ncnn-runtime"

[[ -d "$repository_dir" ]] || { printf 'no repository directory: %s\n' "$repository_dir" >&2; exit 2; }
[[ -d "$incoming_dir" ]] || { printf 'no incoming directory: %s\n' "$incoming_dir" >&2; exit 2; }

if [[ ! -f "$repository_dir/$repository_name.db" ]]; then
    printf 'repository database is missing: %s/%s.db\n' "$repository_dir" "$repository_name" >&2
    exit 1
fi

# --- wire the repository into pacman so dependencies resolve from it --------
if ! grep -qx "[$repository_name]" /etc/pacman.conf; then
    trimmed="$(mktemp)"
    awk -v name="$repository_name" '
        $0 == "[" name "]" {skip=1; next}
        skip && /^\[/ {skip=0}
        !skip {print}
    ' /etc/pacman.conf >"$trimmed"
    {
        printf '\n[%s]\nSigLevel = Never\nServer = file://%s\n' "$repository_name" "$repository_dir"
        cat "$trimmed"
    } >/etc/pacman.conf
    rm -f "$trimmed"
fi

printf 'Refreshing package databases...\n'
pacman -Syu --noconfirm >/dev/null

mapfile -t package_files < <(find "$incoming_dir" -type f -name '*.pkg.tar.zst' | sort)
if (( ${#package_files[@]} == 0 )); then
    printf 'no incoming package files found under %s\n' "$incoming_dir" >&2
    exit 1
fi

# Newest version wins when the same package name appears twice.
declare -A chosen_path=()
for package_file in "${package_files[@]}"; do
    info="$(bsdtar -xOf "$package_file" .PKGINFO 2>/dev/null || true)"
    name="$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$info")"
    [[ -n "$name" ]] || continue
    chosen_path["$name"]="$package_file"
done

selected=()
skipped=()
for name in "${!chosen_path[*]}"; do
    [[ -n "$name" ]] || continue
    if [[ ",${skip_list}," == *",$name,"* ]]; then
        skipped+=("$name (explicitly skipped)")
        continue
    fi
    if [[ "$install_all" != "1" && " $heavy_default " == *" $name "* ]]; then
        skipped+=("$name (heavy install closure; set INSTALL_TEST_ALL=1 to include)")
        continue
    fi
    selected+=("${chosen_path[$name]}")
done

if (( ${#selected[@]} == 0 )); then
    printf 'Nothing to install-test.\n'
    for entry in "${skipped[@]}"; do
        printf '  skipped: %s\n' "$entry"
    done
    exit 0
fi

printf 'Install test for %d package(s):\n' "${#selected[@]}"
printf '  %s\n' "${selected[@]}"
for entry in "${skipped[@]}"; do
    printf '  skipped: %s\n' "$entry"
done

printf 'Installing from the repository...\n'
if ! pacman -U --noconfirm --needed --overwrite '*' "${selected[@]}"; then
    printf 'FAIL: the repository could not install its own packages.\n' >&2
    exit 1
fi

# --- runtime verification against the installed result ----------------------
names=()
for package_file in "${selected[@]}"; do
    info="$(bsdtar -xOf "$package_file" .PKGINFO)"
    name="$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<<"$info")"
    [[ -n "$name" ]] && names+=("$name")
done

status=0
for name in "${names[@]}"; do
    if ! bash "$workspace_dir/scripts/runtime-verify.sh" --package "$name"; then
        status=1
    fi
done

if (( status != 0 )); then
    printf 'FAIL: runtime verification failed for an installed package.\n' >&2
    exit 1
fi

printf 'Repository install test passed for %d package(s).\n' "${#names[@]}"
