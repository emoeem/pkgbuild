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
    # -- 防止以 - 开头的 URL 被当成 git 选项解析；timeout 防止挂死占住
    # 整个同步运行。
    [[ "$aur_url" != -* ]] || { printf 'invalid .aur-url (starts with a dash): %s\n' "$aur_url" >&2; exit 1; }
    timeout 600 git clone --depth 1 -- "$aur_url" "$checkout_dir"
    aur_commit="$(git -C "$checkout_dir" rev-parse HEAD)"

    # Stage the upstream tree separately. A failed overlay or package audit must
    # never destroy the current working package directory.
    staged_dir="$temporary_dir/staged-$package_name"
    mkdir -p "$staged_dir"
    cp -a "$checkout_dir"/. "$staged_dir"/
    rm -rf "$staged_dir/.git"

    # Preserve repository-owned files before applying overlays. PKGBUILD must
    # come from AUR and then receive its explicit overlay; .SRCINFO is regenerated
    # from that result. The source URL/commit are refreshed from AUR every run.
    # Everything else in the current package tree is local state: local-only
    # files are restored, and conflicting local files win with a warning. This
    # deliberately includes hidden metadata such as .nvchecker.toml,
    # .namcap-ignore and .gitignore, as well as local patches/assets.
    if [[ -d "$package_dir" ]]; then
        preserved_manifest="$temporary_dir/preserved-files-$package_name"
        git -C "$repo_root" ls-files --cached --others --exclude-standard -z -- \
            "packages/$package_name" > "$preserved_manifest"
        while IFS= read -r -d '' tracked_path; do
            local_path="$repo_root/$tracked_path"
            relative_path="${tracked_path#"packages/$package_name"/}"
            case "$relative_path" in
                PKGBUILD|.SRCINFO|.aur-url|.aur-commit)
                    continue
                    ;;
            esac
            staged_path="$staged_dir/$relative_path"
            if [[ -d "$local_path" && ! -L "$local_path" ]]; then
                if [[ -e "$staged_path" && ( ! -d "$staged_path" || -L "$staged_path" ) ]]; then
                    printf 'warning: %s: local directory replaces conflicting AUR path %s\n' \
                        "$package_name" "$relative_path" >&2
                    rm -rf "$staged_path"
                fi
                mkdir -p "$staged_path"
                continue
            fi

            mkdir -p "$(dirname "$staged_path")"
            if [[ -e "$staged_path" || -L "$staged_path" ]]; then
                if [[ -L "$local_path" && -L "$staged_path" ]]; then
                    if [[ "$(readlink "$local_path")" != "$(readlink "$staged_path")" ]]; then
                        printf 'warning: %s: keeping local version of conflicting file %s\n' \
                            "$package_name" "$relative_path" >&2
                    fi
                elif [[ -f "$local_path" && -f "$staged_path" ]]; then
                    if ! cmp -s -- "$local_path" "$staged_path"; then
                        printf 'warning: %s: keeping local version of conflicting file %s\n' \
                            "$package_name" "$relative_path" >&2
                    fi
                else
                    printf 'warning: %s: keeping local version of conflicting path %s\n' \
                        "$package_name" "$relative_path" >&2
                    rm -rf "$staged_path"
                fi
            fi
            rm -rf "$staged_path"
            cp -a -- "$local_path" "$staged_path"
        done < "$preserved_manifest"
    fi

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
