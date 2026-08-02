#!/usr/bin/env bash

set -Eeuo pipefail

readonly incoming_dir="${INCOMING_DIR:-/incoming}"
readonly repository_dir="${REPOSITORY_DIR:-/repository}"
readonly repository_name="${REPOSITORY_NAME:-emoeem}"
readonly repository_key="${REPOSITORY_KEY:-/run/secrets/repository-key.asc}"

mkdir -p "$repository_dir"
rm -f "${repository_dir}/.gitkeep"

mapfile -d '' incoming_packages < <(
    find "$incoming_dir" -type f -name '*.pkg.tar.zst' -print0 | sort -z
)

if (( ${#incoming_packages[@]} == 0 )); then
    printf 'No package files were provided to create-repository.sh.\n' >&2
    exit 1
fi

for package_file in "${incoming_packages[@]}"; do
    destination="${repository_dir}/$(basename "$package_file")"
    rm -f "$destination" "${destination}.sig"
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
repo-add -R --include-sigs "$database" "${repository_packages[@]}"

rm -f \
    "${repository_dir}/${repository_name}.db.sig" \
    "${repository_dir}/${repository_name}.db.tar.zst.sig" \
    "${repository_dir}/${repository_name}.files.sig" \
    "${repository_dir}/${repository_name}.files.tar.zst.sig"

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

cat > "${repository_dir}/${repository_name}.conf" <<EOF
[${repository_name}]
SigLevel = ${signature_level}
Server = file:///absolute/path/to/private-repo/x86_64
EOF

(
    cd "$repository_dir"
    sha256sum ./*.pkg.tar.zst > SHA256SUMS
)

printf 'Repository %s now contains:\n' "$repository_name"
ls -lh "$repository_dir"
