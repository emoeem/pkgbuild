#!/usr/bin/env bash
# Workspace transactions for automatic repairs.
#
# Every automated change goes through:
#
#   txn_init <root> <path...>   declare the files a repair may touch
#   txn_snapshot                copy them aside, record digests
#   txn_digest                  print "sha256  path" for the current state
#   txn_rollback                restore the snapshot exactly (including deletions)
#   txn_commit                  discard the snapshot
#
# The point is that a repair which fails validation can never leave a
# half-modified PKGBUILD behind for the next build to trip over.

# shellcheck shell=bash

TXN_ROOT=""
TXN_DIR=""
TXN_ACTIVE=0
TXN_PATHS=()

txn_init() {
    TXN_ROOT="$1"
    shift
    TXN_PATHS=("$@")
    TXN_DIR="$(mktemp -d)"
    TXN_ACTIVE=1
    mkdir -p "$TXN_DIR/backup"
    : >"$TXN_DIR/missing.txt"
}

txn_snapshot() {
    (( TXN_ACTIVE == 1 )) || return 0
    local path destination
    for path in "${TXN_PATHS[@]}"; do
        destination="$TXN_DIR/backup/$path"
        if [[ -e "$TXN_ROOT/$path" ]]; then
            mkdir -p "$(dirname "$destination")"
            cp -a "$TXN_ROOT/$path" "$destination"
        else
            printf '%s\n' "$path" >>"$TXN_DIR/missing.txt"
        fi
    done
}

# txn_digest [path...] - defaults to the transaction paths.
# shellcheck disable=SC2120  # the optional paths argument is part of the API
txn_digest() {
    local -a paths=("$@")
    (( ${#paths[@]} > 0 )) || paths=("${TXN_PATHS[@]}")
    local path
    for path in "${paths[@]}"; do
        if [[ -f "$TXN_ROOT/$path" ]]; then
            printf '%s  %s\n' "$(sha256sum "$TXN_ROOT/$path" | awk '{ print $1 }')" "$path"
        elif [[ -d "$TXN_ROOT/$path" ]]; then
            printf 'directory  %s\n' "$path"
        else
            printf 'missing    %s\n' "$path"
        fi
    done
}

# txn_rollback: restore every path to its pre-snapshot state.
txn_rollback() {
    (( TXN_ACTIVE == 1 )) || return 0
    local path
    for path in "${TXN_PATHS[@]}"; do
        if [[ -e "$TXN_DIR/backup/$path" ]]; then
            rm -rf "${TXN_ROOT:?}/$path"
            mkdir -p "$(dirname "$TXN_ROOT/$path")"
            cp -a "$TXN_DIR/backup/$path" "$TXN_ROOT/$path"
        elif grep -qxF -- "$path" "$TXN_DIR/missing.txt" 2>/dev/null; then
            # The repair created this file; rollback removes it again.
            rm -rf "${TXN_ROOT:?}/$path"
        fi
    done
}

# txn_diff: unified diff of the changed paths (empty when nothing changed).
txn_diff() {
    (( TXN_ACTIVE == 1 )) || return 0
    local path
    for path in "${TXN_PATHS[@]}"; do
        [[ -f "$TXN_DIR/backup/$path" && -f "$TXN_ROOT/$path" ]] || continue
        diff -u --label "a/$path" --label "b/$path" \
            "$TXN_DIR/backup/$path" "$TXN_ROOT/$path" || true
    done
}

txn_record_before() {
    (( TXN_ACTIVE == 1 )) || return 0
    txn_digest >"$TXN_DIR/before.txt"
}

# txn_restored: true when the current tree matches the recorded pre-state.
txn_restored() {
    (( TXN_ACTIVE == 1 )) || return 1
    local current
    current="$(txn_digest)"
    [[ "$current" == "$(cat "$TXN_DIR/before.txt")" ]]
}

txn_commit() {
    (( TXN_ACTIVE == 1 )) || return 0
    TXN_ACTIVE=0
    rm -rf "$TXN_DIR"
}

txn_cleanup() {
    (( TXN_ACTIVE == 1 )) || return 0
    txn_rollback >/dev/null 2>&1 || true
    TXN_ACTIVE=0
    rm -rf "$TXN_DIR"
}
