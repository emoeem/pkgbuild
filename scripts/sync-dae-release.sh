#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
marker_file="$repo_root/state/dae-upstream-release"

command -v gh >/dev/null
command -v python >/dev/null

release_json="$(mktemp)"
trap 'rm -f "$release_json"' EXIT

gh api repos/daeuniverse/dae/releases/latest \
  -H 'Accept: application/vnd.github+json' > "$release_json"

release_tag="$(python - "$release_json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
if data.get("draft") or data.get("prerelease"):
    raise SystemExit("latest GitHub release is not a stable release")
print(data["tag_name"])
PY
)"

tracked="$(cat "$marker_file" 2>/dev/null || true)"
printf 'Tracked dae release: %s\n' "${tracked:-<none>}"
printf 'Latest dae release:  %s\n' "$release_tag"

if [[ "$tracked" == "$release_tag" ]]; then
  echo "daed-emo already tracks dae $release_tag; nothing to do."
  exit 0
fi

printf '%s\n' "$release_tag" > "$marker_file"
echo "Updated daed-emo dae release marker to $release_tag."
