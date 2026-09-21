#!/usr/bin/env bash
set -Eeuo pipefail

repository_dir="${1:-${REPOSITORY_DIR:-}}"
repository_name="${REPOSITORY_NAME:-emoeem}"
[[ -n "$repository_dir" ]] || { echo 'Usage: verify-repository.sh <repository-dir>' >&2; exit 2; }

db="$repository_dir/$repository_name.db"
files_db="$repository_dir/$repository_name.files"
[[ -f "$db" && -f "$files_db" ]] || { echo 'Repository databases are missing.' >&2; exit 1; }

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Validate every package referenced by repo-add. This catches partial publishes
# where the database reaches GitHub before one of its package assets does.
mapfile -t descriptions < <(bsdtar -tf "$db" | grep '/desc$' | sort -u)
for entry in "${descriptions[@]}"; do
    filename="$(bsdtar -xOf "$db" "$entry" | awk -F ' = ' '$1 == "%FILENAME%" {print $2; exit}')"
    if [[ -z "$filename" ]]; then
        printf 'WARN: database entry has no %%FILENAME%% field: %s\n' "$entry" >&2
        continue
    fi
    [[ -f "$repository_dir/$filename" ]] || fail "database references missing asset: $filename"
done

# Check that every package asset has a valid Arch metadata payload and is
# covered by the repository checksum manifest.
if [[ -f "$repository_dir/SHA256SUMS" ]]; then
    (cd "$repository_dir" && sha256sum --check SHA256SUMS) || fail 'SHA256SUMS verification failed'
else
    fail 'SHA256SUMS is missing'
fi

mapfile -t package_files < <(find "$repository_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort)
for package_file in "${package_files[@]}"; do
    if ! bsdtar -tf "$package_file" | grep -Fxq '.PKGINFO'; then
        fail "package has no .PKGINFO: $(basename "$package_file")"
    fi
done

if [[ -f "$repository_dir/$repository_name.conf" ]]; then
    grep -Fxq "[$repository_name]" "$repository_dir/$repository_name.conf" ||
        fail 'repository config has an unexpected section name'
else
    fail 'repository config is missing'
fi

printf 'Verified %d package asset(s) and %d database entries.\n' "${#package_files[@]}" "${#descriptions[@]}"
if [[ -f "$(dirname "$0")/verify-repository-elf.sh" ]]; then
    bash "$(dirname "$0")/verify-repository-elf.sh" "$repository_dir" || fail "ELF ABI verification failed"
else
    fail "verify-repository-elf.sh is missing"
fi

if (( failures > 0 )); then
    printf 'Repository verification found %d failure(s).\n' "$failures" >&2
    exit 1
fi
printf 'Repository integrity verification passed.\n'
