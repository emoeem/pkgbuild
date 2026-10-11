#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/repository-install-test.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/repository" "$tmp/incoming" "$tmp/workspace/scripts" "$tmp/state"
touch "$tmp/repository/emoeem.db"
printf '[options]\nArchitecture = auto\n' > "$tmp/pacman.conf"
printf 'pkgname = demo\npkgver = 1.0-1\n' > "$tmp/incoming/demo-1.0-1-x86_64.pkg.tar.zst"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/workspace/scripts/runtime-verify.sh"
chmod +x "$tmp/workspace/scripts/runtime-verify.sh"
export MOCK_LOG="$tmp/state/pacman.log"

# mock pacman:-U 无 --assume-installed 且目标是 demo 时,报外部依赖缺失失败;
# 带 --assume-installed 的重试成功。-Sl 列出仓库自己的包(不含 demo 的缺依赖)。
cat > "$tmp/bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pacman %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  -Syu) exit 0 ;;
  -Sl) printf '%s\n' 'emoeem other-pkg 2.0-1' ;;
  -U)
    if [[ "$*" != *--assume-installed* && "$MOCK_EXTERNAL_DEP_FAIL" == 1 ]]; then
      printf 'warning: cannot resolve "%s", a dependency of "demo"\n' "$MOCK_MISSING_DEP"
      printf 'error: failed to prepare transaction (could not satisfy dependencies)\n'
      exit 1
    fi
    exit 0
    ;;
esac
MOCK
cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pkgname = demo\npkgver = 1.0-1\n'
MOCK
chmod +x "$tmp/bin/pacman" "$tmp/bin/bsdtar"

run_test() {
  (
    export PATH="$tmp/bin:$PATH"
    export REPOSITORY_DIR="$tmp/repository" INCOMING_DIR="$tmp/incoming"
    export WORKSPACE_DIR="$tmp/workspace" REPOSITORY_NAME=emoeem
    export PACMAN_CONF="$tmp/pacman.conf"
    export MOCK_MISSING_DEP="$1" MOCK_EXTERNAL_DEP_FAIL="$2"
    bash "$script"
  )
}

# 外部依赖(AUR 等):首次失败 -> 按已安装假设重试 -> 通过
output="$(run_test linuxqq 1)"
grep -q 'assuming installed: linuxqq' <<<"$output"
grep -q 'Repository install test passed for 1 package' <<<"$output"
grep -q -- '--assume-installed=linuxqq' "$MOCK_LOG"
echo 'ok: external dependency is assumed installed and the install passes'

# 本仓库自己的包缺依赖:闸门必须失败(fail closed)
: > "$MOCK_LOG"
if output="$(run_test other-pkg 1 2>&1)"; then
  echo 'expected internal missing dependency to fail' >&2
  exit 1
fi
grep -q 'FAIL: unresolvable dependencies pointing at this repository: other-pkg' <<<"$output"
echo 'ok: missing dependency on a package of this repository fails the gate'

# 无可解析缺失信息时(其他原因失败):不盲目假设,直接失败
: > "$MOCK_LOG"
if output="$(run_test '' 1 2>&1)"; then
  echo 'expected unexplained install failure to fail' >&2
  exit 1
fi
grep -q 'FAIL: the repository could not install its own packages (no unresolvable dependency reported)' <<<"$output"
echo 'ok: unexplained failure still fails the gate'
