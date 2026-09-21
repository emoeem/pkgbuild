#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
package_dir="$repo_root/packages/dae-emo"
pkgbuild="$package_dir/PKGBUILD"
tracked_file="$package_dir/.upstream-release"

command -v curl >/dev/null
command -v python >/dev/null
command -v makepkg >/dev/null

release_json="$(mktemp)"
trap 'rm -f "$release_json"' EXIT
curl --fail --silent --show-error --location \
  --retry 5 --retry-all-errors --retry-delay 2 \
  --connect-timeout 30 \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/daeuniverse/dae/releases/latest \
  -o "$release_json"

readarray -t release_meta < <(
  python - "$release_json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data.get("draft") or data.get("prerelease"):
    raise SystemExit("latest GitHub release is not a stable release")
tag = data["tag_name"]
version = tag.removeprefix("v")
asset = next(
    (a for a in data["assets"]
     if a["name"] == f"dae-linux-x86_64_v3_avx2.tar.xz"),
    None,
)
if asset is None:
    raise SystemExit("required x86-64-v3/AVX2 release asset is missing")
print(tag)
print(version)
print(asset["browser_download_url"])
PY
)

release_tag="${release_meta[0]}"
version="${release_meta[1]}"
asset_url="${release_meta[2]}"
tracked="$(cat "$tracked_file" 2>/dev/null || true)"

printf 'Tracked dae release: %s\n' "${tracked:-<none>}"
printf 'Latest dae release:  %s\n' "$release_tag"

if [[ "$tracked" == "$release_tag" ]]; then
  echo "dae-emo is already tracking $release_tag; nothing to do."
  exit 0
fi

asset_file="$(mktemp)"
trap 'rm -f "$release_json" "$asset_file"' EXIT
curl --fail --silent --show-error --location \
  --retry 5 --retry-all-errors --retry-delay 2 \
  --connect-timeout 30 \
  "$asset_url" -o "$asset_file"
sha256="$(sha256sum "$asset_file" | awk '{print $1}')"

python - "$pkgbuild" "$version" "$sha256" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]
text = path.read_text(encoding="utf-8")
text, n_version = re.subn(r"^pkgver=.*$", f"pkgver={version}", text, count=1, flags=re.M)
text, n_sum = re.subn(
    r"^sha256sums=\('[0-9a-f]+'\)$",
    f"sha256sums=('{sha256}')",
    text,
    count=1,
    flags=re.M,
)
if n_version != 1 or n_sum != 1:
    raise SystemExit("PKGBUILD version/checksum markers were not found exactly once")
path.write_text(text, encoding="utf-8")
PY

printf '%s\n' "$release_tag" > "$tracked_file"

(
  cd "$package_dir"
  makepkg --printsrcinfo > .SRCINFO
)

echo "Updated dae-emo to $release_tag ($sha256)."
