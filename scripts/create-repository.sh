#!/usr/bin/env bash

set -Eeuo pipefail

readonly incoming_dir="${INCOMING_DIR:-/incoming}"
readonly repository_dir="${REPOSITORY_DIR:-/repository}"
readonly repository_name="${REPOSITORY_NAME:-emoeem}"
readonly repository_key="${REPOSITORY_KEY:-/run/secrets/repository-key.asc}"
readonly removal_file="${REMOVE_PACKAGES_FILE:-/remove-packages}"
readonly repository_server="${REPOSITORY_SERVER:-file:///absolute/path/to/private-repo/x86_64}"

mkdir -p "$repository_dir"
rm -f "${repository_dir}/.gitkeep"

package_name_from_archive() {
    bsdtar -xOf "$1" .PKGINFO |
        awk -F ' = ' '$1 == "pkgname" { print $2; exit }'
}

remove_repository_package() {
    local target_name="$1"
    local package_file package_name
    local removed=0

    while IFS= read -r -d '' package_file; do
        package_name="$(package_name_from_archive "$package_file")"
        if [[ "$package_name" == "$target_name" ]]; then
            printf 'Removing %s from the repository.\n' \
                "$(basename "$package_file")"
            rm -f "$package_file" "${package_file}.sig"
            removed=1
        fi
    done < <(
        find "$repository_dir" -maxdepth 1 -type f \
            -name '*.pkg.tar.zst' \
            -print0 |
            sort -z
    )

    if (( removed == 0 )); then
        printf '%s is already absent from the repository.\n' "$target_name"
    fi
}

mapfile -d '' incoming_packages < <(
    find "$incoming_dir" -type f -name '*.pkg.tar.zst' -print0 | sort -z
)

removal_packages=()
if [[ -f "$removal_file" ]]; then
    mapfile -t removal_packages < <(
        sed '/^[[:space:]]*$/d' "$removal_file" | sort -u
    )
fi

if (( ${#incoming_packages[@]} == 0 && ${#removal_packages[@]} == 0 )); then
    printf 'No package files or removals were provided.\n' >&2
    exit 1
fi

for package_name in "${removal_packages[@]}"; do
    if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
        printf 'Invalid package name in %s: %s\n' \
            "$removal_file" "$package_name" >&2
        exit 1
    fi
    remove_repository_package "$package_name"
done

for package_file in "${incoming_packages[@]}"; do
    package_name="$(package_name_from_archive "$package_file")"
    if [[ -z "$package_name" ]]; then
        printf 'Unable to read pkgname from %s.\n' "$package_file" >&2
        exit 1
    fi

    remove_repository_package "$package_name"
    destination="${repository_dir}/$(basename "$package_file")"
    cp "$package_file" "$destination"
done

mapfile -d '' repository_packages < <(
    find "$repository_dir" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' \
        -print0 |
        sort -z
)

signing_key=""
if [[ -s "$repository_key" ]]; then
    export GNUPGHOME=/tmp/repository-gnupg
    install -d -m0700 "$GNUPGHOME"
    gpg --batch --import "$repository_key"
    signing_key="$(
        gpg --batch --with-colons --list-secret-keys |
            awk -F: '$1 == "fpr" { print $10; exit }'
    )"

    if [[ -z "$signing_key" ]]; then
        printf 'No secret signing key was found in %s.\n' "$repository_key" >&2
        exit 1
    fi

    for package_file in "${repository_packages[@]}"; do
        rm -f "${package_file}.sig"
        gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${REPOSITORY_KEY_PASSPHRASE:-}" \
            --local-user "$signing_key" \
            --detach-sign "$package_file"
    done

    gpg --batch --armor --export "$signing_key" \
        > "${repository_dir}/${repository_name}-key.asc"
else
    rm -f "${repository_dir}"/*.pkg.tar.zst.sig
    rm -f "${repository_dir}/${repository_name}-key.asc"
fi

database="${repository_dir}/${repository_name}.db.tar.zst"
rm -f \
    "${repository_dir}/${repository_name}.db" \
    "${repository_dir}/${repository_name}.db.tar.zst" \
    "${repository_dir}/${repository_name}.db.tar.zst.old" \
    "${repository_dir}/${repository_name}.db.sig" \
    "${repository_dir}/${repository_name}.db.tar.zst.sig" \
    "${repository_dir}/${repository_name}.files" \
    "${repository_dir}/${repository_name}.files.tar.zst" \
    "${repository_dir}/${repository_name}.files.tar.zst.old" \
    "${repository_dir}/${repository_name}.files.sig" \
    "${repository_dir}/${repository_name}.files.tar.zst.sig"

if (( ${#repository_packages[@]} > 0 )); then
    repo-add --include-sigs "$database" "${repository_packages[@]}"
else
    for archive in \
        "${repository_dir}/${repository_name}.db.tar.zst" \
        "${repository_dir}/${repository_name}.files.tar.zst"; do
        bsdtar --create --file - --format ustar --files-from /dev/null |
            zstd --quiet --stdout > "$archive"
    done
    ln -sfn \
        "${repository_name}.db.tar.zst" \
        "${repository_dir}/${repository_name}.db"
    ln -sfn \
        "${repository_name}.files.tar.zst" \
        "${repository_dir}/${repository_name}.files"
fi

if [[ -n "$signing_key" ]]; then
    for archive in \
        "${repository_dir}/${repository_name}.db.tar.zst" \
        "${repository_dir}/${repository_name}.files.tar.zst"; do
        gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${REPOSITORY_KEY_PASSPHRASE:-}" \
            --local-user "$signing_key" \
            --detach-sign "$archive"
    done

    ln -sfn \
        "${repository_name}.db.tar.zst.sig" \
        "${repository_dir}/${repository_name}.db.sig"
    ln -sfn \
        "${repository_name}.files.tar.zst.sig" \
        "${repository_dir}/${repository_name}.files.sig"

    signature_level="Required DatabaseRequired"
else
    signature_level="Never"
fi

# pacman 直接下载 <repo>.db / <repo>.files，而 GitHub Release 资产不支持
# 符号链接，因此把仓库发布为不带 .tar.zst 后缀的常规文件。
rm -f \
    "${repository_dir}/${repository_name}.db" \
    "${repository_dir}/${repository_name}.files" \
    "${repository_dir}/${repository_name}.db.sig" \
    "${repository_dir}/${repository_name}.files.sig"
mv -f \
    "${repository_dir}/${repository_name}.db.tar.zst" \
    "${repository_dir}/${repository_name}.db"
mv -f \
    "${repository_dir}/${repository_name}.files.tar.zst" \
    "${repository_dir}/${repository_name}.files"
if [[ -n "$signing_key" ]]; then
    mv -f \
        "${repository_dir}/${repository_name}.db.tar.zst.sig" \
        "${repository_dir}/${repository_name}.db.sig"
    mv -f \
        "${repository_dir}/${repository_name}.files.tar.zst.sig" \
        "${repository_dir}/${repository_name}.files.sig"
fi
rm -f \
    "${repository_dir}/${repository_name}.db.tar.zst.old" \
    "${repository_dir}/${repository_name}.files.tar.zst.old"

cat > "${repository_dir}/${repository_name}.conf" <<EOF
[${repository_name}]
SigLevel = ${signature_level}
Server = ${repository_server}
EOF

(
    cd "$repository_dir"
    if (( ${#repository_packages[@]} > 0 )); then
        sha256sum ./*.pkg.tar.zst > SHA256SUMS
    else
        : > SHA256SUMS
    fi
)

printf 'Repository %s now contains:\n' "$repository_name"
ls -lh "$repository_dir"
