#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/verify-publish-inputs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/incoming" "$tmp/source/packages"

cat > "$tmp/bin/bsdtar" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do
    if [[ "$argument" == */published/* && -n "${MOCK_PUBLISHED_PKGINFO:-}" ]]; then
        cat "$MOCK_PUBLISHED_PKGINFO"
        exit 0
    fi
done
cat "$MOCK_PKGINFO"
MOCK
chmod +x "$tmp/bin/bsdtar"

make_case() {
    local name="$1" source_ver="$2" source_rel="$3" actual="$4" dynamic="$5"
    local package_dir="$tmp/source/packages/$name"
    mkdir -p "$package_dir"
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n' "$name" "$source_ver" "$source_rel" > "$package_dir/.SRCINFO"
    {
        printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n' "$name" "$source_ver" "$source_rel"
        if [[ "$dynamic" == yes ]]; then
            printf 'pkgver() { echo dynamic; }\n'
        fi
    } > "$package_dir/PKGBUILD"
    touch "$tmp/incoming/$name-$actual-x86_64.pkg.tar.zst"
    printf 'pkgname = %s\npkgver = %s\n' "$name" "$actual" > "$tmp/pkginfo"
}

# 仓库里已经存在的那个版本（published/x86_64 下的同名包）。
make_published() {
    local name="$1" version="$2"
    rm -rf -- "$tmp/published"
    mkdir -p "$tmp/published"
    touch "$tmp/published/$name-$version-x86_64.pkg.tar.zst"
    printf 'pkgname = %s\npkgver = %s\n' "$name" "$version" > "$tmp/published-pkginfo"
}

run_case() {
    local -a published=()
    if [[ "${1:-}" == with-published ]]; then
        published=("$tmp/published")
    fi
    PATH="$tmp/bin:$PATH" MOCK_PKGINFO="$tmp/pkginfo" MOCK_PUBLISHED_PKGINFO="$tmp/published-pkginfo" \
        bash "$script" "$tmp/incoming" "$tmp/source" ${published[@]+"${published[@]}"}
}

# A VCS package may resolve pkgver() to a newer commit than its checked-in .SRCINFO.
make_case svt-jpeg-xs-git 0.9.0.r5.ge0940ac 1 0.9.0.r123.ge5a61be-1 yes
output="$(run_case)"
grep -q 'Accepted resolved git pkgver for svt-jpeg-xs-git' <<<"$output"
echo 'ok: resolved VCS pkgver is accepted when stable prefix and pkgrel match'

# Bare rN.<hash> VCS packages (upstream has no conventional version number)
# resolve the same way; the whole version is the dynamic part.
rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r111.01bdc03 1 r117.48cebc7-1 yes
output="$(run_case)"
grep -q 'Accepted resolved git pkgver for linuxqq-wayland-fix-git' <<<"$output"
echo 'ok: bare rN.<hash> VCS pkgver is accepted when pkgrel matches'

rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r111.01bdc03 1 r117.48cebc7-2 yes
if output="$(run_case 2>&1)"; then
    echo 'expected bare rN.<hash> pkgrel mismatch to fail' >&2
    exit 1
fi
grep -q 'Publication mismatch for linuxqq-wayland-fix-git' <<<"$output"
echo 'ok: bare rN.<hash> with mismatched pkgrel is rejected'

# A VCS package whose pkgrel was bumped on purpose (ABI rebuild) still ships
# pkgrel 1: makepkg resets pkgrel the moment pkgver() resolves a new version
# (`==> Updated version: linuxqq-wayland-fix-git r119.c86286f-1` from a source
# pkgrel of 2, run 38196580120). That reset must not block publication.
rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r111.01bdc03 2 r119.c86286f-1 yes
output="$(run_case)"
grep -q 'Accepted resolved git pkgver for linuxqq-wayland-fix-git' <<<"$output"
echo 'ok: makepkg pkgrel reset to 1 is accepted for a bumped VCS package'

rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r111.01bdc03 2 r119.c86286f-3 yes
if output="$(run_case 2>&1)"; then
    echo 'expected an unexpected VCS pkgrel to fail' >&2
    exit 1
fi
grep -q 'Publication mismatch for linuxqq-wayland-fix-git' <<<"$output"
echo 'ok: a VCS pkgrel that is neither the source pkgrel nor 1 is rejected'

# A regular package still requires an exact source version (unless pkgrel is intentionally bumped).
rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-1 no
output="$(run_case)"
[[ -z "$output" ]]
echo 'ok: exact static package version is accepted'

rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.1-1 no
if output="$(run_case 2>&1)"; then
    echo 'expected static version mismatch to fail' >&2
    exit 1
fi
grep -q 'Publication mismatch for stable-demo' <<<"$output"
echo 'ok: static package version mismatch is rejected'

rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-2 no
output="$(run_case)"
grep -q 'Accepted bumped pkgrel for stable-demo' <<<"$output"
echo 'ok: intentional pkgrel bump is accepted'

# PKGBUILD 的 pkgrel 行带行尾注释时（quirc 就是这样）也要能读出 pkgrel，否则
# ABI 重建的 pkgrel+1 例外永远匹配不上，发布被闸门挡住。
rm -f "$tmp/incoming"/*
make_case quirc 1.2 5 1.2-6 no
sed -i 's/^pkgrel=5$/pkgrel=5  # emoeem overlay: quirc pkgrel bump/' "$tmp/source/packages/quirc/PKGBUILD"
output="$(run_case)"
grep -q 'Accepted bumped pkgrel for quirc' <<<"$output"
echo 'ok: a commented pkgrel line still allows the bumped-pkgrel exception'

# ABI 重建的 pkgrel+1 撞上已发布版本 = bump 根本没前进。ffmpeg-full 就是这样
# 出事的：源码树停在 2.6，重建算出 9.0.2-2.7，而仓库里已经是 2.7 —— 发出去
# 装了旧 2.7 的机器永远升不到那版修好 liboapv 的 libavcodec.so.63。
rm -f "$tmp/incoming"/*
make_case ffmpeg-full 9.0.2 2.6 9.0.2-2.7 no
make_published ffmpeg-full 9.0.2-2.7
if output="$(run_case with-published 2>&1)"; then
    echo 'expected a bumped pkgrel colliding with the published version to fail' >&2
    exit 1
fi
grep -q 'Publication would not upgrade ffmpeg-full' <<<"$output"
echo 'ok: a bumped pkgrel that collides with the published version is rejected'

# 版本真的前进了就放行（9.0.2-2.8 盖过已发布的 9.0.2-2.7）。
rm -f "$tmp/incoming"/*
make_case ffmpeg-full 9.0.2 2.8 9.0.2-2.8 no
output="$(run_case with-published)"
[[ -z "$output" ]]
echo 'ok: a newer pkgrel over the published version is accepted'

# bump 之后仍然落后于已发布版本（源码 2.8 -> bump 2.9，仓库已是 2.10）同样是
# 升不上去的发布；小数 pkgrel 按段比较，2.9 < 2.10。
rm -f "$tmp/incoming"/*
make_case ffmpeg-full 9.0.2 2.8 9.0.2-2.9 no
make_published ffmpeg-full 9.0.2-2.10
if output="$(run_case with-published 2>&1)"; then
    echo 'expected a bumped pkgrel behind the published version to fail' >&2
    exit 1
fi
grep -q 'Publication would not upgrade ffmpeg-full' <<<"$output"
echo 'ok: a bumped pkgrel behind the published version is rejected (2.9 < 2.10)'

# 普通路径下的同版本重发只 WARNING 不拦：发布是全有全无，不能因为一个静态包
# 忘了 bump pkgrel 就让整批（比如同批的 ffmpeg-full 修复）发不出去。
rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-1 no
make_published stable-demo 1.0-1
output="$(run_case with-published 2>&1)"
grep -q 'WARNING: stable-demo 1.0-1 is already published' <<<"$output"
echo 'ok: a static same-version republish warns without blocking the batch'

rm -f "$tmp/incoming"/*
make_case stable-demo 1.0 1 1.0-1 no
make_published stable-demo 1.0-2
output="$(run_case with-published 2>&1)"
grep -q 'WARNING: stable-demo 1.0-1 is already published' <<<"$output"
echo 'ok: a static publish behind the published version warns without blocking'

# VCS 包在上游没动时重建出来的版本号和已发布的一模一样，这是正常空转：既不能
# 失败，也不该刷 WARNING。
rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r117.48cebc7 1 r117.48cebc7-1 yes
make_published linuxqq-wayland-fix-git r117.48cebc7-1
output="$(run_case with-published 2>&1)"
[[ -z "$output" ]]
echo 'ok: a VCS rebuild that resolves to the published version is a silent no-op'

# 小数 pkgrel 前进时按段比较，不能当浮点：2.10 比 2.9 新。
rm -f "$tmp/incoming"/*
make_case ffmpeg-full 9.0.2 2.10 9.0.2-2.10 no
make_published ffmpeg-full 9.0.2-2.9
output="$(run_case with-published)"
[[ -z "$output" ]]
echo 'ok: decimal pkgrel 2.10 is newer than 2.9'

# 没发布过的包不受这条检查影响。
rm -f "$tmp/incoming"/*
make_case brand-new-demo 1.0 1 1.0-1 no
output="$(run_case with-published)"
[[ -z "$output" ]]
echo 'ok: a package that was never published is accepted'

# 换了 pkgver 的 VCS 包仍然走原来的放行路径（方向交给 vercmp）。
rm -f "$tmp/incoming"/*
make_case linuxqq-wayland-fix-git r111.01bdc03 2 r119.c86286f-1 yes
make_published linuxqq-wayland-fix-git r117.48cebc7-1
output="$(run_case with-published)"
grep -q 'Accepted resolved git pkgver for linuxqq-wayland-fix-git' <<<"$output"
echo 'ok: a VCS pkgver move is still accepted with a published version present'

# epoch 不同说明版本空间不同，方向不在这里判（保守放行）。
rm -f "$tmp/incoming"/*
make_case epoch-demo 9.0.2 1 9.0.2-1 no
make_published epoch-demo 1:9.0.2-1
output="$(run_case with-published)"
[[ -z "$output" ]]
echo 'ok: an epoch difference is left to vercmp'
