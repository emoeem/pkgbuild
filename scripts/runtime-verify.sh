#!/usr/bin/env bash
# Runtime verification of a built or installed package.
#
# makepkg succeeding is not evidence that a package works. This checks the
# artifact the way a user would hit it:
#
#   * unresolved shared libraries (ldd)
#   * wrong / missing SONAME on shipped libraries (readelf -d)
#   * broken symlinks
#   * missing or non-executable expected binaries
#   * missing runtime dependencies (pacman -T)
#   * smoke tests from scripts/data/smoke-tests.yaml
#
# Usage:
#   runtime-verify.sh --package NAME [--package NAME...]
#   runtime-verify.sh --file path.pkg.tar.zst [...]
#
# Options:
#   --json-out FILE     write the machine readable result
#   --skip-smoke        do not run smoke commands
#   --quiet             only print failures
set -Eeuo pipefail

# Parsing tool output (readelf, ldd, pacman) must never depend on the locale:
# a translated label turns a check into a silent no-op.
export LC_ALL=C

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${script_dir}/.." && pwd)"

declare -a installed_packages=() package_files=()
json_out=""
skip_smoke=0
quiet=0

while (( $# > 0 )); do
    case "$1" in
        --package) installed_packages+=("$2"); shift 2 ;;
        --file) package_files+=("$2"); shift 2 ;;
        --json-out) json_out="$2"; shift 2 ;;
        --skip-smoke) skip_smoke=1; shift ;;
        --quiet) quiet=1; shift ;;
        --help | -h) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if (( ${#installed_packages[@]} == 0 && ${#package_files[@]} == 0 )); then
    printf 'runtime-verify: give at least one --package or --file\n' >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
checked_objects=0
report="$work/report.jsonl"
: >"$report"

note_failure() {
    local package_name="$1" check="$2" detail="$3"
    failures=$(( failures + 1 ))
    printf 'FAIL: %s: %s: %s\n' "$package_name" "$check" "$detail" >&2
    python3 -c '
import json, sys
print(json.dumps({"package": sys.argv[1], "check": sys.argv[2], "detail": sys.argv[3]}))
' "$package_name" "$check" "$detail" >>"$report"
}

# --- payload discovery -----------------------------------------------------
list_payload() {
    local package_name="$1"
    pacman -Ql "$package_name" 2>/dev/null |
        awk '$2 ~ /^\// { print $2 }' |
        sort -u
}

# --- checks ----------------------------------------------------------------
check_symlinks() {
    local package_name="$1" target="$2" listing="$3"
    local link resolved
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        [[ -L "$target$link" ]] || continue
        resolved="$(readlink -f "$target$link" 2>/dev/null || true)"
        if [[ -z "$resolved" || ! -e "$resolved" ]]; then
            note_failure "$package_name" "broken-symlink" "$link -> $(readlink "$target$link" 2>/dev/null || echo '?')"
        fi
    done <<<"$listing"
}

check_elf() {
    local package_name="$1" target="$2" listing="$3"
    local file magic declared
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -f "$target$file" ]] || continue
        magic="$(head -c 4 "$target$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        [[ "$magic" == "7f454c46" ]] || continue
        checked_objects=$(( checked_objects + 1 ))

        # Unresolved runtime dependency. Read the whole input before testing:
        # grep -q exits early and pipefail would turn EPIPE into a false pass.
        if ldd "$target$file" 2>&1 | grep 'not found' >/dev/null; then
            note_failure "$package_name" "unresolved-library" \
                "$file: $(ldd "$target$file" 2>/dev/null | awk '/not found/ {print $1}' | paste -sd, -)"
        fi

        # A shared library must carry a SONAME that matches its file name;
        # a mismatch is exactly what makes dependent packages fail to load it.
        local base_name
        base_name="$(basename "$file")"
        if [[ "$base_name" =~ [.]so([.][0-9]+)*$ ]]; then
            declared="$(readelf -d "$target$file" 2>/dev/null |
                awk '/SONAME/ {gsub(/[][\\[\\]]/, "", $NF); print $NF}')"
            if [[ -n "$declared" && "$declared" != "$base_name" ]]; then
                note_failure "$package_name" "soname-mismatch" "$file declares $declared"
            elif [[ -z "$declared" && "$base_name" =~ [.]so[.][0-9] ]]; then
                note_failure "$package_name" "missing-soname" "$file has a versioned name but no SONAME"
            fi
        fi
    done <<<"$listing"
}

# Installed mode: pacman -Qkk compares the real filesystem against the
# package's mtree, which catches permission drift that a simple stat may mask.
check_permissions_installed() {
    local package_name="$1"
    local output
    if ! command -v pacman >/dev/null 2>&1; then
        return 0
    fi
    if ! output="$(pacman -Qkk "$package_name" 2>&1)"; then
        note_failure "$package_name" "file-properties" \
            "$(printf '%s\n' "$output" | sed '/^$/d' | head -n 3 | paste -sd';' -)"
    fi
}

# Archive mode: the permissions recorded in the package are the truth. Reading
# the tar header avoids the umask that an unprivileged extraction applies
# (777 extracted as 755), which is exactly what hid this check before.
check_permissions_archive() {
    local package_name="$1" package_file="$2"
    local mode path
    while read -r mode _rest; do
        [[ "$mode" == -* ]] || continue
        # 0-based positions: 0 = file type, 1-3 user, 4-6 group, 7-9 other,
        # so group-write is index 5 and other-write is index 8.
        if [[ "${mode:5:1}" == "w" || "${mode:8:1}" == "w" ]]; then
            path="$(awk '{ print $NF }' <<<"$_rest")"
            note_failure "$package_name" "world-writable" "$path ($mode)"
        fi
    done < <(bsdtar -tvf "$package_file" 2>/dev/null | awk 'NF >= 2 { print $1, $0 }')
}

check_smoke() {
    local package_name="$1" target="$2"
    local manifest="$root/scripts/data/smoke-tests.yaml"
    [[ -f "$manifest" ]] || return 0
    local payload
    # The repository's dependency-free YAML loader is reused here so the smoke
    # manifest and the error rules share one parser (and one failure mode:
    # a malformed file raises instead of silently disabling the checks).
    payload="$(python3 - "$manifest" "$package_name" "$root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[3])
sys.path.insert(0, str(root / "scripts" / "lib"))
from errorrules import load_yaml

document = load_yaml(Path(sys.argv[1]).read_text(encoding="utf-8"))
entry = (document.get("packages") or {}).get(sys.argv[2]) or {}
print(json.dumps(
    {
        "binaries": entry.get("binaries") or [],
        "libraries": entry.get("libraries") or [],
        "commands": entry.get("commands") or [],
        "timeout": entry.get("timeout_seconds") or (document.get("defaults") or {}).get("timeout_seconds") or 30,
        "allow_failure": bool(entry.get("allow_failure")),
    }
))
PY
)"

    local binary
    while IFS= read -r binary; do
        [[ -n "$binary" ]] || continue
        local path="$target/usr/bin/$binary"
        # $target is set when verifying an extracted archive and empty when
        # verifying an installed package, so the same paths work for both.
        if [[ ! -e "$path" && ! -e "$target/usr/sbin/$binary" ]]; then
            note_failure "$package_name" "missing-binary" "$binary"
        elif [[ -e "$path" && ! -x "$path" ]]; then
            note_failure "$package_name" "not-executable" "$binary"
        fi
    done < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["binaries"]))' "$payload")

    if (( skip_smoke == 1 )); then
        return 0
    fi

    local library
    while IFS= read -r library; do
        [[ -n "$library" ]] || continue
        if [[ -n "$target" ]]; then
            if ! find "$target" -name "$library*" -print -quit 2>/dev/null | grep -q .; then
                note_failure "$package_name" "missing-library" "$library"
            fi
        fi
    done < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["libraries"]))' "$payload")

    local command_line timeout
    timeout="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["timeout"])' "$payload")"
    local allow_failure
    allow_failure="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["allow_failure"]).lower())' "$payload")"
    while IFS= read -r command_line; do
        [[ -n "$command_line" ]] || continue
        if timeout "$timeout" bash -c "$command_line" >/dev/null 2>&1; then
            (( quiet == 1 )) || printf '  smoke ok: %s\n' "$command_line"
        elif [[ "$allow_failure" == "true" ]]; then
            printf '  smoke skipped (marked allow_failure): %s\n' "$command_line"
        else
            note_failure "$package_name" "smoke-test" "$command_line"
        fi
    done < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["commands"]))' "$payload")
}

verify_package() {
    local package_name="$1" target="" listing
    if command -v pacman >/dev/null 2>&1; then
        # Convert pacman -Ql failures into a structured finding rather than
        # allowing set -e to terminate before the JSON report is written.
        listing="$(list_payload "$package_name" || true)"
        target=""
        if [[ -z "$listing" ]]; then
            note_failure "$package_name" "not-installed" "pacman -Ql produced no files"
            return
        fi
        # Missing runtime dependencies.
        local missing
        missing="$(pacman -T "$package_name" 2>/dev/null || true)"
        if [[ -n "$missing" ]]; then
            note_failure "$package_name" "missing-dependency" "$(printf '%s' "$missing" | paste -sd, -)"
        fi
    else
        note_failure "$package_name" "not-installed" "pacman is unavailable"
        return
    fi
    check_symlinks "$package_name" "$target" "$listing"
    check_elf "$package_name" "$target" "$listing"
    check_permissions_installed "$package_name"
    check_smoke "$package_name" "$target"
}

verify_file() {
    local package_file="$1"
    [[ -f "$package_file" ]] || { note_failure "$(basename "$package_file")" "missing-file" "$package_file"; return; }
    local destination
    destination="$work/$(basename "$package_file" .pkg.tar.zst)"
    mkdir -p "$destination"
    bsdtar -xf "$package_file" -C "$destination"
    local package_name listing
    package_name="$(bsdtar -xOf "$package_file" .PKGINFO | awk -F ' = ' '$1 == "pkgname" { print $2; exit }')"
    listing="$(find "$destination" -type f -o -type l | sed "s|^$destination||" | sort -u)"
    check_symlinks "$package_name" "$destination" "$listing"
    check_elf "$package_name" "$destination" "$listing"
    check_permissions_archive "$package_name" "$package_file"
    check_smoke "$package_name" "$destination"
}

for package_name in "${installed_packages[@]:-}"; do
    [[ -n "$package_name" ]] || continue
    verify_package "$package_name"
done
for package_file in "${package_files[@]:-}"; do
    [[ -n "$package_file" ]] || continue
    verify_file "$package_file"
done

status="pass"
(( failures == 0 )) || status="fail"

if [[ -n "$json_out" ]]; then
    python3 - "$report" "$json_out" "$status" "$checked_objects" <<'PY'
import json, sys
report, out, status, objects = sys.argv[1:5]
findings = []
with open(report, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            findings.append(json.loads(line))
json.dump(
    {
        "schema": 1,
        "status": status,
        "checked_objects": int(objects),
        "failures": len(findings),
        "findings": findings,
    },
    open(out, "w", encoding="utf-8"),
    indent=2,
    sort_keys=True,
)
PY
fi

printf 'Runtime verification checked %d ELF object(s); %d failure(s).\n' \
    "$checked_objects" "$failures"
if (( failures > 0 )); then
    printf 'Runtime verification FAILED.\n' >&2
    exit 1
fi
printf 'Runtime verification passed.\n'
