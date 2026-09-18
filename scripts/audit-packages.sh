#!/usr/bin/env bash
set -Eeuo pipefail

root="${AUDIT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly root

failures=0
packages=()
while IFS= read -r -d '' pkgdir; do
    packages+=("$(basename "$pkgdir")")
done < <(find "$root/packages" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD -printf '%h\0' | sort -z)

[[ ${#packages[@]} -gt 0 ]] || { echo 'No package directories found.' >&2; exit 1; }

if ! command -v makepkg >/dev/null 2>&1; then
    echo 'makepkg is required for the package audit.' >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

info() { printf '  %s\n' "$*"; }

for package in "${packages[@]}"; do
    dir="$root/packages/$package"
    srcinfo="$dir/.SRCINFO"
    pkgbuild="$dir/PKGBUILD"
    if [[ ! -f "$pkgbuild" ]]; then
        fail "$package: PKGBUILD missing"
        continue
    fi
    if [[ ! -f "$srcinfo" ]]; then
        fail "$package: .SRCINFO missing"
        continue
    fi

    generated="$work/$package.SRCINFO"
    if ! (cd "$dir" && BUILDDIR="$work/build" SRCDEST="$work/src" PKGDEST="$work/pkg" LOGDEST="$work/log" makepkg --printsrcinfo > "$generated"); then
        fail "$package: makepkg --printsrcinfo failed"
        continue
    fi
    if ! diff -q "$srcinfo" "$generated" >/dev/null; then
        fail "$package: .SRCINFO is stale"
    fi

    pkgbase="$(awk -F ' = ' '$1 == "pkgbase" {print $2; exit}' "$srcinfo")"
    mapfile -t names < <(awk -F ' = ' '$1 == "pkgname" {print $2}' "$srcinfo")
    [[ "$pkgbase" == "$package" ]] || fail "$package: pkgbase is '$pkgbase'"
    (( ${#names[@]} > 0 )) || fail "$package: no pkgname entries"

    arch_count="$(awk -F ' = ' '$1 == "\tarch" {n++} END {print n+0}' "$srcinfo")"
    (( arch_count > 0 )) || fail "$package: no architecture declared"

    if [[ -f "$dir/.aur-url" ]]; then
        url="$(<"$dir/.aur-url")"
        [[ "$url" == https://aur.archlinux.org/*.git ]] ||
            info "$package: custom AUR-compatible URL: $url"
        [[ -s "$dir/.aur-commit" ]] || fail "$package: .aur-commit missing"
    fi

done

# Build a provider map from every package base. This catches internal dependency
# mistakes without assuming that every external repository is available.
declare -A provider_owner=()
declare -A package_conflicts=()
while IFS= read -r -d '' srcinfo; do
    base="$(awk -F ' = ' '$1 == "pkgbase" {print $2; exit}' "$srcinfo")"
    while IFS= read -r conflict; do
        [[ -n "$conflict" ]] || continue
        conflict="${conflict%%[<>=]*}"
        package_conflicts["$base|$conflict"]=1
    done < <(awk -F ' = ' '$1 == "\tconflicts" {print $2}' "$srcinfo")
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -n "${provider_owner[$name]:-}" && "${provider_owner[$name]}" != "$base" ]]; then
            other="${provider_owner[$name]}"
            if [[ -z "${package_conflicts[$base|$other]:-}" && -z "${package_conflicts[$other|$base]:-}" && -z "${package_conflicts[$base|$name]:-}" && -z "${package_conflicts[$other|$name]:-}" ]]; then
                fail "provider '$name' is exported by both '$other' and '$base' without an explicit conflict"
            else
                info "provider '$name' is intentionally shared by alternatives '$other' and '$base'"
            fi
        else
            provider_owner["$name"]="$base"
        fi
    done < <(awk -F ' = ' '$1 == "pkgname" {print $2}' "$srcinfo")
    while IFS= read -r provides; do
        [[ -n "$provides" ]] || continue
        provides="${provides%%:*}"
        provides="${provides%%[<>=]*}"
        if [[ -n "${provider_owner[$provides]:-}" && "${provider_owner[$provides]}" != "$base" ]]; then
            other="${provider_owner[$provides]}"
            if [[ -z "${package_conflicts[$base|$other]:-}" && -z "${package_conflicts[$other|$base]:-}" && -z "${package_conflicts[$base|$provides]:-}" && -z "${package_conflicts[$other|$provides]:-}" ]]; then
                fail "provider '$provides' is exported by both '$other' and '$base' without an explicit conflict"
            else
                info "provider '$provides' is intentionally shared by alternatives '$other' and '$base'"
            fi
        else
            provider_owner["$provides"]="$base"
        fi
    done < <(awk -F ' = ' '$1 == "\tprovides" {print $2}' "$srcinfo")
done < <(find "$root/packages" -mindepth 2 -maxdepth 2 -type f -name .SRCINFO -print0 | sort -z)

# Detect dependencies that are accidentally self-provided through conflicts or
# malformed provider declarations. External dependencies are intentionally not
# treated as failures because they may come from CachyOS, Arch, Chaotic-AUR or AUR.
while IFS= read -r -d '' srcinfo; do
    base="$(awk -F ' = ' '$1 == "pkgbase" {print $2; exit}' "$srcinfo")"
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        dep="${dep%%[<>=]*}"
        if [[ -n "${provider_owner[$dep]:-}" && "${provider_owner[$dep]}" == "$base" ]]; then
            # Self-dependencies are normally a packaging error. Split packages
            # are allowed to provide each other only when the provider is another
            # pkgname in the same base; a base depending on itself is still bad.
            fail "$base: dependency '$dep' resolves to the same package base"
        fi
    done < <(awk -F ' = ' '$1 == "\tdepend" || $1 == "\tmakedepend" || $1 == "\tcheckdepend" {print $2}' "$srcinfo")
done < <(find "$root/packages" -mindepth 2 -maxdepth 2 -type f -name .SRCINFO -print0 | sort -z)

printf '\nAudited %d package directories.\n' "${#packages[@]}"
if (( failures > 0 )); then
    printf 'Package audit found %d failure(s).\n' "$failures" >&2
    exit 1
fi
printf 'Package dependency/metadata audit passed.\n'
