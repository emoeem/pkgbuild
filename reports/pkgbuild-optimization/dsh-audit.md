# Phase 0 审计 — dsh-desktop-linux（2026-11-15，pin 0.2.2rc3-1）

## 0. 包定位（现状自洽的部分，先记录以免误改）

- 本包是 **binary repack**：`build()` 只做资产校验（`PKGBUILD:57-69`），`package()` 原样解包上游 Arch 资产（`:71-81`，排除 .PKGINFO/.BUILDINFO/.MTREE/.INSTALL 由 makepkg 重生成）。
- 上游更新全自动：`dsh-desktop-linux-update.yml`（cron `53 */2 * * *`）→ `update-dsh-desktop-linux.py`（tag 正则、asset 状态、GitHub digest sha256、同版本 checksum 变化拒绝重 pin：`:194-201`）→ builder 内 `check-package.sh` + 候选构建 + runtime 验证（workflow `:94-142`）→ commit + dispatch build.yml（`bump_pkgrel` 未传，默认 false——正确）。
- 现有完整性校验（Phase 2.2 要求"保留"的清单）：
  - 下载地址 pin 到明确版本：`source=("${_asset}::${_upstream}/v${pkgver}/${_asset}")`（`PKGBUILD:48-51`），pkgver 内嵌资产文件名；
  - SHA256 = GitHub asset digest（更新器强制存在，`:123-129`）；
  - `build()` 校验 `.PKGINFO` 的 `pkgname` / `pkgver = ${pkgver}-1` / `arch`（`PKGBUILD:63-68`）——版本只编码在文件名里，这道校验是真闸门；
  - `noextract` 避免 1.1 GiB 双份落地；
  - `.namcap-exclude` 豁免 8 类结构性误报（repack 语义，其余 namcap 规则仍生效）；`.runtime-verify-ignore` 豁免 3 条（koffi musl 变体、内嵌 CPython 的 libtcl、chrome-sandbox 4755 回退），豁免理由逐条成文。
  - install 脚本（`dsh-desktop-linux.install`）：chrome-sandbox 0755/4755 条件判断照抄上游 postinst，AppArmor profile 幂等加载/卸载——逻辑审查无问题。

## 1. 【P0】depends 里的 `libxss` 已被上游删除

- **问题描述**：本地 depends 含 `libxss`（`PKGBUILD:33`、`.SRCINFO` `depends = libxss`），上游自 v0.2.2rc2 起已从 Arch 包删除该依赖。
- **证据**（本次审计取得）：
  1. v0.2.2rc2 release body（GitHub API）：「**去掉安装包里冗余的 XScreenSaver 依赖。** Electron 既不链接也不加载该库，deb / rpm / Arch 包不再要求安装 `libxss1` / `libXScrnSaver` / `libxss`（社区 PR #14）」；
  2. v0.2.2rc3 资产本体 `.PKGINFO`（HTTP Range 取前 8 MiB 解压）depend 全列表：
     `gtk3 nss libnotify libxtst xdg-utils at-spi2-core libsecret alsa-lib dbus libxcrypt-compat libdbusmenu-glib`
     —— 与本地 depends 逐项对比，**唯一差异就是本地多出 `libxss`**，其余 11 项完全一致。
- **复现条件**：静态即现；上游资产证据见 §6 复现命令。
- **影响范围**：客户端被强制安装一个 Electron 既不链接也不加载的库；依赖闭包无谓增大；与本仓库"depends 以上游 .PKGINFO 为准"的声明（`PKGBUILD:25-27` 注释）不符。
- **推荐修复**（Phase 2.1）：从 `depends` 删除 `'libxss'`（PKGBUILD:33 与 .SRCINFO 同步）；其余 11 项已与 rc3 资产逐项核对一致，无需改动。
- **验证方式**：`makepkg --printsrcinfo` diff 一致；`check-package.sh dsh-desktop-linux`；构建后 `bsdtar -xOf <产物> .PKGINFO | grep '^depend'` 与本地 depends 集合相等（见 §6 建议的新校验）。

## 2. 【P0·根因】更新器永不同步 depends

- **问题描述**：`update-dsh-desktop-linux.py:207-225` 的 bump 只改 PKGBUILD 的 `pkgver/pkgrel/sha256sums` 三行 + .SRCINFO 的 `pkgver/pkgrel/noextract/source/sha256sums` 五行。**depends/optdepends/conflicts 在上游变化时永远不会跟着动**——§1 的 libxss 正是这样漏掉的：包创建时从旧资产 .PKGINFO 抄了一份，此后三个版本没人再看。
- **位置**：`scripts/update-dsh-desktop-linux.py:207-231`（`update_files`）；`packages/dsh-desktop-linux/PKGBUILD:25-27`（注释声称 "Copied from the released package's .PKGINFO"——静态快照，非同步）。
- **复现条件**：上游任何一次依赖增删（rc2 实际发生）。
- **影响范围**：依赖声明与上游资产的系统性漂移；将来上游加依赖时会变成**缺依赖**（比多余 libxss 更严重：应用起不来）。
- **推荐修复**（Phase 2.1/2.2 合并落地）：
  1. 更新器在拿到新资产后（候选构建已在 builder 里下载了资产）增加"depends 对账"步骤：解包资产 `.PKGINFO`，与本地 depends 集合 diff；不一致时**不开静默自动改写**（依赖语义需要人判断 optdepends 归属），而是以失败退出 + 输出 diff，强制走一次人工确认——这是 dsh 更新工作流当前唯一的人工闸门，语义合适；
  2. 或最小改动：`build()` 的资产校验扩展一项——资产 .PKGINFO 的 depend 集合必须与 `${depends[@]}` 相等（本地数组在 PKGBUILD 里可见），不等则构建失败。该方案零工作流改动、每次构建都验，推荐作为 Phase 2 的落点。
- **验证方式**：`tests/` 为更新器新增 fixture（改动 .PKGINFO depend 集合 → 更新器报 diff 拒绝）；build() 校验用 `bsdtar` fixture 单测；现网验证即"下次上游 release 时工作流在依赖变化处响亮失败"。

## 3. pkgrel 策略（Phase 2.3）现状与缺口

- `.pkgrel-floor-skip` 存在且自证语义（文件内注释 + `pkgrel-floor.sh:42-50`），E1/E2 尊重它，`tests/test-pkgrel-floor.sh:171-176` 有测试。
- **缺口**：E3（`prepare-build-source.sh`）与 E4（`auto-repair.sh`）不识别——完整链条与修复方案见 `pkgrel-flow-audit.md` §2.1/2.2，此处不重复。结论：在 E3/E4 修复 + 策略分类落地前，"repack 包不被无意义 bump"这条保证不成立。
- 「ABI 监控发现系统库变化时不得原样 repack 冒充 ABI 修复」：当前 `check-repository-sonames.sh` 会把 dsh 的 payload ELF 断裂报成 STALE 并作为 **urgent 绕过 24h 冷却**强行 dispatch（`dispatch-stale-rebuilds.sh:113-121,141`）——重建结果当然还是同一资产。正确行为：降级为 NOTE/issue"等待上游资产"，属 Phase 3 策略消费点（`package-strategy-audit.md` §2）。
- 上游版本变化 → 更新器重置 `pkgrel=1`（E7）：语义正确（资产内嵌 `-1`，版本前进靠 pkgver），保持。

## 4. Phase 2.4 验证矩阵现状

| 检查项 | 现状 |
|---|---|
| PKGBUILD 解析 / .SRCINFO 一致性 | ✅ check-package.sh（bash -n + makepkg --printsrcinfo 比对）；更新器写完后 builder 内再验一次（workflow `:94-107`） |
| 上游下载 + SHA256 | ✅ 更新器 digest 校验 + makepkg validity check（候选构建） |
| .PKGINFO pkgname/pkgver/arch | ✅ build()（PKGBUILD:63-68） |
| 包内文件列表 | 部分：repack 原样保留（bsdtar -xpf 上游 modes），无独立清单 diff——上游结构变化会随资产进入包内（可接受，属上游责任），但**元数据文件意外新增**（上游加了 .INSTALL 之外的点文件）不会被注意。建议 build() 增加 `bsdtar -tf` 顶层点文件白名单断言 |
| 依赖关系 | ❌ 无对账（§2） |
| 安装/卸载行为 | ✅ repository-install-test（发布闸门）+ runtime-verify；install 脚本逻辑审查通过 |
| AppArmor 逻辑 | ✅ install 脚本 + optdepends 'apparmor'；CI 容器无 AppArmor 时静默跳过为设计内 |
| 桌面启动文件与图标 | 部分：runtime-verify 查 ELF/权限/烟测 `deepseek-harness` 二进制（smoke-tests.yaml）；.desktop/图标**未显式断言存在**。建议 smoke-tests 或 runtime-verify 增加一条 `test -f /usr/share/applications/*.desktop` 类检查 |
| 应用启动所需动态库 | ✅ runtime-verify ldd（豁免清单内的 3 条已逐条论证）；注意豁免依赖路径正则与内嵌 Python 版本（python3.12）耦合，上游换 Python 大版本时需同步（`.runtime-verify-ignore` 第 2 条） |

## 5. 残余风险

1. `.SRCINFO` 的 `noextract`/`source` 行由更新器正则替换（`:218-224`）——格式假设单一，上游若多 asset 会拒绝（`replace_once` 计数保护），安全。
2. 更新器版本序比较（`version_tuple`，rc9 < 正式版）已处理 rc 语义；tag 正则不匹配 alpha，资产规则兜底（`:150-153`），无缺口发现。
3. 工作流 dispatch 失败重试 3 次（`:175-188`）+ notify-failure 兜底——更新链路的"丢失 dispatch"风险已有防护。

## 6. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
# 证据 1：上游 rc2 release note
curl -s "https://api.github.com/repos/ffyfox/dsh-desktop-linux/releases?per_page=10" \
  | grep -o '去掉安装包里冗余的 XScreenSaver 依赖' | head -1
# 预期: 去掉安装包里冗余的 XScreenSaver 依赖

# 证据 2：rc3 资产 .PKGINFO 依赖（Range 取头部即可；GitHub CDN 偶发 SSL 抖动，带 retry）
tmp=$(mktemp -d)
for i in 1 2 3; do
  curl -sL --retry 3 --retry-all-errors -r 0-8388607 \
    "https://github.com/ffyfox/dsh-desktop-linux/releases/download/v0.2.2rc3/dsh-desktop-linux-0.2.2rc3-1-x86_64.pkg.tar.zst" \
    -o "$tmp/head.zst" && break || sleep 5
done
zstd -dc "$tmp/head.zst" 2>/dev/null | head -c 6291456 | strings | grep '^depend = '
# 预期 11 行 depend，其中没有 libxss
diff <(sed -n 's/^\tdepends = //p' packages/dsh-desktop-linux/.SRCINFO | sort) \
     <(zstd -dc "$tmp/head.zst" 2>/dev/null | head -c 6291456 | strings | sed -n 's/^depend = //p' | sort)
# 预期回显（唯一差异，2026-11-15 实测）:
#   9d8
#   < libxss
rm -rf "$tmp"
```
