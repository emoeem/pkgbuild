#!/usr/bin/env bash
set -Eeuo pipefail

# Force the C locale: the checks below parse tool output (readelf, pacman,
# ldd, ...) whose labels are localized, and a translated label silently
# turns the check into a no-op instead of failing loudly.
export LC_ALL=C

repository_dir="${1:?usage: verify-repository-elf.sh <repository-dir>}"
[[ -d "$repository_dir" ]] || exit 2

failures=0
declare -A soname_owner=()
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
      fi
    done < <(
      readelf -d "$elf" 2>/dev/null |
        awk '/SONAME/ {gsub(/[\\[\\]]/, "", $NF); print $NF}'
    )
  done < <(
    find "$tmpdir" -type f -print0 |
      while IFS= read -r -d '' f; do
        magic=''
        LC_ALL=C IFS= read -r -N 4 magic < "$f" 2>/dev/null || true
        [[ "$magic" == $'\x7fELF' ]] && printf '%s\0' "$f"
      done
  )
  rm -rf "$tmpdir"
done

# 旧实现还有第二遍完整解包检查「NEEDED 的私有 SONAME 没有主人」；由于
# private_sonames 与 soname_owner 总是同时写入，其失败条件恒为假（死代码）。
# 已发布包对外的 NEEDED 漂移（openvino 这类外部提供者换 SONAME）由
# maintenance.yml / ABI watch 的 soname 扫描负责，这里只保留 SONAME 唯一性
# （含互斥替代豁免）检查，并把两遍解包合并为一遍。

printf 'Verified ELF ABI metadata for %d package asset(s).\n' "${#package_files[@]}"
if (( failures > 0 )); then
  printf 'ELF repository verification found %d failure(s).\n' "$failures"
  exit 1
fi
printf 'ELF repository verification passed.\n'
