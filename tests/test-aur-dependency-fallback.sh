#!/usr/bin/env bash
# 验证 scripts/find-uninstallable-dependencies.sh 只挑出"仓库里有同名包、但依赖
# 闭包装不上"的依赖；纯 AUR 依赖、能正常安装的仓库依赖、组名和 soname 依赖都
# 必须原样跳过。
set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 &&
        pwd
)"
readonly repo_root
readonly script="${repo_root}/scripts/find-uninstallable-dependencies.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# 假 pacman：shadowed-dep 在仓库里存在但事务算不出来，fine-dep 两样都行，
# aur-dep 根本不在仓库里（-Si 失败），base-devel 当成组名（同样 -Si 失败）。
mkdir -p "${work}/bin"
cat > "${work}/bin/pacman" <<'EOF'
#!/usr/bin/env bash
mode=""
name=""
for argument in "$@"; do
    case "$argument" in
        -Si) mode=Si ;;
        -Sp) mode=Sp ;;
        -*) ;;
        *) name="$argument" ;;
    esac
done
[[ -n "$mode" && -n "$name" ]] || exit 1
case "${mode}:${name}" in
    Si:shadowed-dep | Si:fine-dep | Sp:fine-dep) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${work}/bin/pacman"

printf '%s\n' \
    'pkgbase = fixture' \
    'pkgver = 1' \
    'pkgrel = 1' \
    $'\tdepends = shadowed-dep' \
    $'\tdepends = fine-dep>=2' \
    $'\tdepends = aur-dep' \
    $'\tdepends = libfoo.so=3-64' \
    $'\tmakedepends = base-devel' \
    >"${work}/.SRCINFO"

if ! output="$(PATH="${work}/bin:${PATH}" bash "$script" "${work}/.SRCINFO")"; then
    fail 'detection script failed on a valid .SRCINFO'
fi
if [[ "$output" == "shadowed-dep" ]]; then
    printf 'ok: uninstallable repository dependency is reported\n'
else
    fail "expected only shadowed-dep, got: ${output:-<empty>}"
fi

if PATH="${work}/bin:${PATH}" bash "$script" >/dev/null 2>&1; then
    fail 'a missing argument should exit non-zero'
fi
if PATH="${work}/bin:${PATH}" bash "$script" "${work}/missing/.SRCINFO" >/dev/null 2>&1; then
    fail 'a missing .SRCINFO should exit non-zero'
fi

if ((failures > 0)); then
    printf '%d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'All AUR dependency fallback checks passed.\n'
