#!/usr/bin/env bash
# 验证 scripts/find-uninstallable-dependencies.sh 只报出"仓库源提供不了、只能从
# AUR 装"的那个名字：仓库里有同名包但闭包装不上时才去读 pacman 的报错，纯 AUR
# 依赖、能正常安装的仓库依赖、组名和 soname 依赖都必须原样跳过。
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

# 假 pacman：
#   shadowed-dep  仓库里有，但事务算不出来，报错里点名 aur-leaf；
#   aur-leaf      仓库里根本没有（只能来自 AUR）；
#   fine-dep      仓库里有且事务可算；
#   base-devel    当成组名（-Si 也失败）。
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
    Sp:shadowed-dep)
        printf ':: unable to satisfy dependency %s required by shadowed-dep\n' "'aur-leaf'" >&2
        exit 1
        ;;
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
if [[ "$output" == "aur-leaf" ]]; then
    printf 'ok: the dependency the repositories cannot provide is reported\n'
else
    fail "expected only aur-leaf, got: ${output:-<empty>}"
fi

# 仓库副本装不上、但报错里没有可识别的缺件名时不能乱报（调用方据此跳出重试）。
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
    *) printf 'error: failed to prepare transaction (could not satisfy dependencies)\n' >&2; exit 1 ;;
esac
EOF
chmod +x "${work}/bin/pacman"
output="$(PATH="${work}/bin:${PATH}" bash "$script" "${work}/.SRCINFO")"
if [[ -z "$output" ]]; then
    printf 'ok: an unparsable failure reports nothing\n'
else
    fail "expected no output for an unparsable failure, got: ${output}"
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
