#!/usr/bin/env bash
set -Eeuo pipefail

repository_dir="${1:?usage: verify-repository-elf.sh <repository-dir>}"
[[ -d "$repository_dir" ]] || exit 2

failures=0
declare -A soname_owner=()
declare -A private_sonames=()
declare -A package_provides=()
declare -A package_conflicts=()

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# Two packages in a repository may legitimately ship the same SONAME when
# pacman considers them mutually exclusive alternatives.  For example,
# llama.cpp-cuda and ggml-cuda-git both provide libggml, while llama.cpp-cuda
# explicitly conflicts with libggml.  Such pairs cannot be installed
# together, so the duplicate SONAME is not an integrity error.
relation_name() {
  printf '%s\n' "$1" | sed -E 's/[<>=].*$//'
}

package_relation_contains() {
  local relation_list="$1" wanted="$2" relation
  while IFS= read -r relation; do
    [[ -n "$relation" ]] || continue
    [[ "$(relation_name "$relation")" == "$wanted" ]] && return 0
  done <<< "$relation_list"
  return 1
}

packages_are_mutually_exclusive() {
  local left="$1" right="$2" right_relation
  if package_relation_contains "${package_conflicts[$left]:-}" "$right"; then
    return 0
  fi
  while IFS= read -r right_relation; do
    [[ -n "$right_relation" ]] || continue
    if package_relation_contains "${package_conflicts[$left]:-}" "$(relation_name "$right_relation")"; then
      return 0
    fi
  done <<< "${package_provides[$right]:-}"
  if package_relation_contains "${package_conflicts[$right]:-}" "$left"; then
    return 0
  fi
  while IFS= read -r right_relation; do
    [[ -n "$right_relation" ]] || continue
    if package_relation_contains "${package_conflicts[$right]:-}" "$(relation_name "$right_relation")"; then
      return 0
    fi
  done <<< "${package_provides[$left]:-}"
  return 1
}

mapfile -t package_files < <(
  find "$repository_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print | sort
)

for package_file in "${package_files[@]}"; do
  pkginfo="$(tar -xOf "$package_file" .PKGINFO)"
  pkgname="$(printf '%s\n' "$pkginfo" |
    awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
  [[ -n "$pkgname" ]] || { fail "missing pkgname: $package_file"; continue; }
  package_provides["$pkgname"]="$(printf '%s\n' "$pkginfo" |
    awk -F ' = ' '$1 == "provides" {print $2}')"
  package_conflicts["$pkgname"]="$(printf '%s\n' "$pkginfo" |
    awk -F ' = ' '$1 == "conflict" {print $2}')"

  tmpdir="$(mktemp -d)"
  tar -xf "$package_file" -C "$tmpdir"
  while IFS= read -r -d '' elf; do
    while IFS= read -r soname; do
      [[ -n "$soname" ]] || continue
      if [[ -n "${soname_owner[$soname]:-}" &&
            "${soname_owner[$soname]}" != "$pkgname" ]]; then
        owner="${soname_owner[$soname]}"
        if ! packages_are_mutually_exclusive "$owner" "$pkgname"; then
          fail "duplicate SONAME $soname: $owner and $pkgname"
        fi
      else
        soname_owner["$soname"]="$pkgname"
        private_sonames["$soname"]=1
      fi
    done < <(
      readelf -d "$elf" 2>/dev/null |
        awk '/SONAME/ {gsub(/[\\[\\]]/, "", $NF); print $NF}'
    )
  done < <(
    find "$tmpdir" -type f -print0 |
      while IFS= read -r -d '' f; do
        [[ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] &&
          printf '%s\0' "$f"
      done
  )
  rm -rf "$tmpdir"
done
# Re-scan NEEDED entries and only enforce providers that are part of this
# private repository. External Arch/CachyOS/AUR providers are intentionally
# outside this script's trust boundary and are checked by maintenance.yml.
for package_file in "${package_files[@]}"; do
  pkgname="$(bsdtar -xOf "$package_file" .PKGINFO |
    awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
  tmpdir="$(mktemp -d)"
  tar -xf "$package_file" -C "$tmpdir"
  while IFS= read -r -d '' elf; do
    while IFS= read -r needed; do
      [[ -n "$needed" ]] || continue
      if [[ -n "${private_sonames[$needed]:-}" &&
            -z "${soname_owner[$needed]:-}" ]]; then
        fail "$pkgname needs private SONAME $needed but no owner exists"
      fi
    done < <(
      readelf -d "$elf" 2>/dev/null |
        awk '/NEEDED/ {gsub(/[\\[\\]]/, "", $NF); print $NF}'
    )
  done < <(
    find "$tmpdir" -type f -print0 |
      while IFS= read -r -d '' f; do
        [[ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] &&
          printf '%s\0' "$f"
      done
  )
  rm -rf "$tmpdir"
done

printf 'Verified ELF ABI metadata for %d package asset(s).\n' "${#package_files[@]}"
if (( failures > 0 )); then
  printf 'ELF repository verification found %d failure(s).\n' "$failures" >&2
  exit 1
fi
printf 'ELF repository verification passed.\n'
