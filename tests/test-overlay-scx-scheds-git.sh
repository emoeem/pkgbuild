#!/usr/bin/env bash
# scx-scheds-git overlay 的判据。
#
# 背景（2026-11-05，runs #103/#104）：overlay 原来用「整段字面量模板精确匹配
# 一次」的方式注入 scxtui 排除，AUR 上游 b4d44e7 重构 package()（新增 xtask
# install 步骤、find 加了 ! -name 'xtask'、scx-tools 降为 optdepends）后模板
# 落空，整个 sync 连红两天。新策略按「含 -executable 与 ! -name '*.so' 的那一
# 行」注入。这个测试把新旧两代上游 package() 和失败路径全部钉住，上游下次再
# 改 package() 时，坏的应该是这里而不是四天后的 sync。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/overlays/scx-scheds-git.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

failures=0
ok() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

marker='# emoeem overlay: scxtui belongs to scx-tools'
installed="! -name 'scxtui'"

make_package() { # <name>; PKGBUILD 从 stdin 读入
    local dir="$tmp/packages/$1"
    mkdir -p "$dir"
    cat > "$dir/PKGBUILD"
    printf '%s\n' "$dir"
}

# 上游 AUR 4e4c401（2026-10-20 本地基线）的 package()：纯 find + install。
old_upstream=$(make_package old <<'EOF'
pkgname=scx-scheds-git
pkgver=1.1.4.r18.ge9cd670d9
pkgrel=2

build() {
  cd $_gitname
  cargo build --release --frozen --workspace --exclude xtask
}

package() {
  cd $_gitname

  # Install all built executables (skip .so and .d files)
  find target/release \
    -maxdepth 1 -type f -executable ! -name '*.so' \
    -exec install -Dm755 -t "$pkgdir/usr/bin/" {} +
}
EOF
)

# 上游 AUR b4d44e7（2026-11-02）的 package()：xtask install 步骤、
# ! -name 'xtask' 谓词、scx-tools 降为 optdepends——曾让旧 overlay 落空。
new_upstream=$(make_package new <<'EOF'
pkgname=scx-scheds-git
pkgver=1.1.4.r208.gb19726e95
pkgrel=1

package() {
  cd $_gitname

  # Install all built executables (skip .so and .d files)
  find target/release \
    -maxdepth 1 -type f -executable ! -name '*.so' ! -name 'xtask' \
    -exec install -Dm755 -t "$pkgdir/usr/bin/" {} +

  # Runtime data via xtask: scx.service, /etc/default/scx,
  # /usr/share/scx/catalog.json, the scxcli polkit policy.
  # --source-dir keeps cargo out of package().
  ./target/release/xtask install --source-dir . --destdir "$pkgdir"
}
EOF
)

assert_applied() { # <dir> <label>
    grep -qF "$marker" "$1/PKGBUILD" \
        && grep -qF "$installed" "$1/PKGBUILD" \
        && ok "$2: marker and scxtui exclusion are present" \
        || fail "$2: marker or scxtui exclusion missing"
}

assert_intact() { # <dir> <label>
    grep -qF '-exec install -Dm755 -t "$pkgdir/usr/bin/" {} +' "$1/PKGBUILD" \
        && ok "$2: the find install rule itself survived" \
        || fail "$2: find install rule damaged"
    bash -n "$1/PKGBUILD" \
        && ok "$2: PKGBUILD still parses" \
        || fail "$2: PKGBUILD no longer parses"
}

# 1. 旧上游：注入成功且规则本体完好。
bash "$script" "$old_upstream"
assert_applied "$old_upstream" 'old upstream'
assert_intact "$old_upstream" 'old upstream'

# 2. 新上游（b4d44e7，曾让旧 overlay 落空）：同样注入成功。
bash "$script" "$new_upstream"
assert_applied "$new_upstream" 'new upstream'
assert_intact "$new_upstream" 'new upstream'
grep -qF "! -name '*.so' ! -name 'scxtui' ! -name 'xtask'" "$new_upstream/PKGBUILD" \
    && ok 'new upstream: scxtui sits alongside the upstream xtask predicate' \
    || fail 'new upstream: scxtui exclusion not adjacent to the other predicates'
grep -qF 'xtask install --source-dir' "$new_upstream/PKGBUILD" \
    && ok 'new upstream: the xtask install step is untouched' \
    || fail 'new upstream: xtask install step damaged'

# 3. marker 必须在反斜杠续行之外（续行中间的 # 会被当成 find 的参数）。
line="$(grep -nF "$marker" "$new_upstream/PKGBUILD" | cut -d: -f1)"
next="$(sed -n "$((line + 1))p" "$new_upstream/PKGBUILD")"
printf '%s\n' "$next" | grep -qF 'find target/release \' \
    && ok 'the marker sits directly above the find statement start' \
    || fail "marker is followed by: $next"

# 4. 幂等：重复运行一字不动。
before="$(md5sum "$new_upstream/PKGBUILD")"
bash "$script" "$new_upstream"
after="$(md5sum "$new_upstream/PKGBUILD")"
[[ "$before" == "$after" ]] \
    && ok 'a repeated run leaves the file untouched' \
    || fail 'the overlay is not idempotent'

# 5. 已排除但丢了 marker：拒绝静默通过。
no_marker=$(make_package no-marker <<'EOF'
package() {
  cd $_gitname
  find target/release \
    -maxdepth 1 -type f -executable ! -name '*.so' ! -name 'scxtui' \
    -exec install -Dm755 -t "$pkgdir/usr/bin/" {} +
}
EOF
)
if bash "$script" "$no_marker" > "$tmp/log" 2>&1; then
    fail 'expected a missing overlay marker to fail'
else
    grep -q 'carries no overlay marker' "$tmp/log" \
        && ok 'an applied exclusion without the marker is rejected' \
        || fail 'missing-marker refusal reason missing'
fi

# 6. 未知结构：fail-closed，而不是把 scxtui 漏进包里。
restructured=$(make_package restructured <<'EOF'
package() {
  cd $_gitname
  install -Dm755 target/release/scx_ctl "$pkgdir/usr/bin/scx_ctl"
}
EOF
)
if bash "$script" "$restructured" > "$tmp/log" 2>&1; then
    fail 'expected an unrecognised package() to fail'
else
    grep -q 'restructured package()' "$tmp/log" \
        && ok 'an unrecognised package() fails closed' \
        || fail 'fail-closed reason missing'
fi

# 7. 缺 PKGBUILD。
if bash "$script" "$tmp/packages/absent" > /dev/null 2>&1; then
    fail 'expected a missing PKGBUILD to fail'
else
    ok 'a missing PKGBUILD is rejected'
fi

if (( failures > 0 )); then
    printf '%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'all scx-scheds-git overlay cases passed\n'
