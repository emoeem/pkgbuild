# Phase 0 审计 — pkgrel 管理全链路（2026-11-15）

## 1. 入口清单（谁会改动 pkgrel）

| # | 入口 | 触发链 | 识别 `.pkgrel-floor-skip` | 改的是哪份树 |
|---|---|---|---|---|
| E1 | `scripts/pkgrel-floor.sh --against-pkgbuild` | `sync.yml` → `sync-aur-packages.sh:173`（AUR 同步，防 pkgrel 拉回上游基线） | ✅（`pkgrel-floor.sh:47-50`） | staged 副本，成功后替换 `packages/<pkg>/` |
| E2 | `scripts/pkgrel-floor.sh --against-repository` | `build-in-arch.sh:192-194`（构建前对齐已发布版本下限；`LOCAL_REPO_DIR` 由 build.yml:322-324、dsh/filee/sing-box 更新器的候选构建注入） | ✅（同上） | 构建副本 `$BUILD_ROOT/<pkg>` |
| E3 | `scripts/prepare-build-source.sh`（`BUMP_PKGREL=true`） | `dependency-drift.yml` → `dispatch-stale-rebuilds.sh:196-200`（**固定 `-f bump_pkgrel=true`**）→ `build.yml`（input `bump_pkgrel`，:29-33/:146/:330）→ `build-in-arch.sh:152,186` | ❌ **不识别** | 构建副本（随后被 write-back 回写源码树） |
| E4 | `scripts/auto-repair.sh` bump_pkgrel 策略 | build 失败 → repair job（`build.yml:518-739`）→ `auto-repair.sh:323-326`（SONAMEError/RuntimeDependencyError，Level 3）→ `:619-634` 直接 +1 | ❌ **不识别** | **源码树本身**，并由 repair job 提交推送 main |
| E5 | `scripts/write-back-pkgrel.sh` | build.yml publish 成功后（:925-932），以产物版本回写源码树并 `[skip ci]` 提交 | ❌（不检查，但方向只前进：`write-back-pkgrel.sh:94-98`） | 源码树（跟随 E2/E3 的结果） |
| E6 | `scripts/overlays/ffmpeg-full.sh:59-66` | AUR 同步后重放本地定制（.6 下限，只升不降） | —（包特有逻辑） | staged 副本 |
| E7 | `scripts/update-dsh-desktop-linux.py:210,221` | 上游新版本时 `pkgrel=1` 重置 | —（语义正确：上游资产内嵌 -1，版本前进靠 pkgver） | 源码树（经候选构建验证后提交） |

执行顺序注意：`build-in-arch.sh` 里 E3（:186）先于 E2（:193）执行。`BUMP_PKGREL=true` 的构建中，+1 先发生，E2 的 skip 分支随后只是"不再抬档"，**无法撤销 E3 已做的修改**。

## 2. 问题

### 2.1 【P0】E3 不识别 `.pkgrel-floor-skip`

- **问题描述**：`prepare-build-source.sh:7-9` 只判断 `BUMP_PKGREL`，拿到 true 就无条件 +1（:13-25），从不检查 `$package_dir/.pkgrel-floor-skip`。`7c1dff2` 只修了 `pkgrel-floor.sh`（E1/E2），ABI 重建入口被漏掉。
- **位置**：`scripts/prepare-build-source.sh:7-25`；对照 `scripts/pkgrel-floor.sh:42-50`。
- **复现条件**（完整链条，当前代码即成立）：
  1. `check-dependency-drift.sh:133-157` 遍历**所有**已发布包的 depends（dsh-desktop-linux depends gtk3/nss/… 共 12 个仓库依赖，无任何豁免路径）；
  2. 任一依赖 pkgver 前进（如 gtk3）→ `check-dependency-drift.sh:101-104` 判 STALE，写入 stale.txt；
  3. `dispatch-stale-rebuilds.sh:196-200` 以 `bump_pkgrel=true` dispatch dsh-desktop-linux；
  4. `prepare-build-source.sh` 把 pkgrel 1→2（payload 与已发布版本逐字节相同）；
  5. E2 因 skip 退出，`verify-publish-inputs.sh` 看到 `0.2.2rc3-2 > 0.2.2rc3-1`，属合法前进 → 发布一次假升级；
  6. `write-back-pkgrel.sh:99-102` 把 pkgrel=2 回写源码树并提交——`.pkgrel-floor-skip` 想防止的事情全部发生。
- **影响范围**：当前唯一带 skip 标记的 dsh-desktop-linux（357 MiB 资产的无意义重下载 + 重打包 + 假升级发布）；未来任何 repack 包想用该标记同样失效。
- **推荐修复**（Phase 1.1，改底层脚本，不动 workflow）：
  1. 抽 `scripts/lib/pkgrel-policy.sh`：`pkgrel_skip_floor <package-dir>`、`parse_pkgrel`（含行尾注释剥离）、`dotted_cmp`、`next_pkgrel`、`apply_pkgrel`（PKGBUILD+.SRCINFO 同步改写）——现在这五件事分散在 `pkgrel-floor.sh:52-108`、`prepare-build-source.sh:13-25`、`verify-publish-inputs.sh:34-81`、`write-back-pkgrel.sh:21-36`、`auto-repair.sh:619-631` 五处实现；
  2. `prepare-build-source.sh` 在 BUMP 判定前调用 `pkgrel_skip_floor`：命中则打印与 E2 同口径的日志并 exit 0；
  3. `auto-repair.sh` 的 bump_pkgrel 策略对 skip 包直接拒绝（策略改为 report-only，理由写明 repack 语义）。
- **验证方式**：新增 `tests/test_prepare_build_source.sh` 场景：`touch .pkgrel-floor-skip` + `BUMP_PKGREL=true` → pkgrel 不变、日志含 `opts out`；`tests/test_auto_repair.sh` 同型断言；跨入口一致性测试（同一 fixture 依次过 E1/E2/E3，pkgrel 终值一致）。

### 2.2 【P0】E4 不识别且直接改源码树

- **问题描述**：`auto-repair.sh:619-634` 的 bump_pkgrel 在**源码树**上 +1 并重生成 .SRCINFO，repair job（build.yml:726-739）随后 `git add packages … && git commit && push`。它既不识别 skip，也不经过 E2/E5 的方向校验路径。
- **位置**：`scripts/auto-repair.sh:323-326`（策略选择）、`:619-634`（执行）。
- **复现条件**：dsh-desktop-linux 构建被归类为 `SONAMEError` 或 `RuntimeDependencyError`（Level 3 才生效，当前 CI `AUTO_FIX_LEVEL=1`，故现为潜伏路径；`vars.AUTO_FIX_LEVEL` 调高即触发）。repack 包 payload 自带 ABI 变体（`.runtime-verify-ignore` 记录的 koffi musl 变体等）正是容易被误分类的场景。
- **影响范围**：与 2.1 相同的假升级后果，且这次直接污染 main（自动提交推送）。
- **推荐修复**：并入 2.1 的共享策略函数；skip 包命中该策略时状态置 `blocked`（repair job 已有完整的 blocked 可见性管道，build.yml:668-694）。
- **验证方式**：`tests/test_auto_repair.sh` 增加 skip fixture，断言输出 `status != applied` 且 PKGBUILD 未变。

### 2.3 【P1】同一条规则有四份实现，已经出现过真实漂移

- **问题描述**：点分段 pkgrel 比较/递增有四份独立实现：`pkgrel-floor.sh:63-93`（`dotted_cmp`+`next_pkgrel`）、`write-back-pkgrel.sh:21-36`（`pkgrel_at_most`）、`verify-publish-inputs.sh:34-81`（`pkgrel_at_most`+`next_pkgrel`）、`prepare-build-source.sh:13-21`（正则）。注释剥离又有三处（`prepare-build-source.sh:13`、`verify-publish-inputs.sh:131-134`、`pkgrel-floor.sh:52-61` 的 `field()`）。历史上 `quirc` 行尾注释（CURRENT-STATUS.md:17）与 `.PKGINFO` 无 pkgrel 字段（:13）两次事故都是"多份实现不同步"的直接后果。
- **位置**：见上行号。
- **复现条件**：静态可见；任一入口的解析规则单独演化（如未来支持 `pkgrel=1.2.3` 或新的注释风格）即产生入口间行为分叉。
- **影响范围**：维护成本 + 回归风险；Phase 1.2 的"多入口一致性"验收无法用单点修改满足。
- **推荐修复**：2.1-1 的 `scripts/lib/pkgrel-policy.sh` 单一实现，四个脚本 source 它；保持各调用方现有输出文本不变（测试有断言）。
- **验证方式**：现有 `test-pkgrel-floor.sh`、`test_prepare_build_source.sh`、`test_publish_inputs.sh`、`test_write_back_pkgrel.sh` 全绿；新增一致性矩阵测试（见 §3）。

### 2.4 【P2】次要问题

1. `pkgrel-floor.sh:103-107` `apply_pkgrel`：目录无 `.SRCINFO` 且 PATH 无 makepkg 时，**只改 PKGBUILD 且不报错**——AUR 同步路径必然有 .SRCINFO，但该函数是共享路径，静默半修改违背 Phase 1.2 "不留半修改状态"的要求。建议：无 .SRCINFO 可写时输出 WARNING。
2. `check-dependency-drift.sh:122-131`：计数器初始化写了两遍（第二段还引入了从未使用的 `unresolved=0`），纯卫生问题，随 Phase 5 顺手清理。
3. `prepare-build-source.sh:23-25`：sed 改 PKGBUILD 成功、`makepkg --printsrcinfo` 失败时构建副本处于半修改状态——`build-in-arch.sh:210-213` 的 .SRCINFO diff 会将其拦下（fail loudly），可接受；但共享库里做成"先算好两个文件的新内容、都写成功才落盘"更稳。

## 3. Phase 1.2 测试矩阵现状对照

| 计划场景 | 现状 | 缺口 |
|---|---|---|
| 普通源码包允许递增 | ✅ `test_prepare_build_source.sh`（整数/小数/注释三种） | — |
| 存在 `.pkgrel-floor-skip` 不递增 | ✅ 仅对 E2：`test-pkgrel-floor.sh:171-176` | ❌ E3/E4 无对应场景（修复后必须补） |
| 不存在标记用默认策略 | ✅ 同上（其余用例） | — |
| pkgrel 格式异常明确报错 | ✅ `test_prepare_build_source.sh`（`1.2.3` → exit 1）；`pkgrel-floor.sh` 各 `exit 2` 分支 | E4 的失败路径无测试 |
| 重复执行递增无意外 | 部分：每次调用 +1 属设计；无"失败不留半状态"断言 | ❌ 补 E3 失败注入测试 |
| 多入口行为一致 | ❌ 完全没有 | ❌ 新增一致性测试 |
| PKGBUILD 可被 makepkg 解析 | ✅ `check-package.sh` + build-in-arch.sh:210-213 diff | — |
| .SRCINFO 与 PKGBUILD 一致 | ✅ 同上；`apply_pkgrel` 同步改写 | — |

## 4. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
# E3 对 skip 包仍会 bump（当前缺陷的直接证明）：
tmp=$(mktemp -d) && cp -r packages/dsh-desktop-linux "$tmp/pkg" && rm -f "$tmp/pkg/.SRCINFO"
( cd "$tmp/pkg" && BUMP_PKGREL=true bash "$OLDPWD/scripts/prepare-build-source.sh" "$tmp/pkg" )
grep '^pkgrel=' "$tmp/pkg/PKGBUILD"
# 预期回显（缺陷现状）:
#   Automatic ABI rebuild: bumped pkgrel 1 -> 2.
#   pkgrel=2          <-- skip 标记存在却被递增
# 修复后预期:
#   prepare-build-source: dsh-desktop-linux opts out via .pkgrel-floor-skip; nothing to bump.
#   pkgrel=1
rm -rf "$tmp"
```
