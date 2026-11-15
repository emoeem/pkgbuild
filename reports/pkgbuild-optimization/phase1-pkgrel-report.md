# Phase 1 验收报告 — pkgrel 管理逻辑统一（2026-11-15）

对应计划 Phase 1.1 / 1.2；问题定位见 [pkgrel-flow-audit.md](pkgrel-flow-audit.md)。未执行任何 git commit / push；所有变更留在工作区待审。

## 1. 变更文件清单

| 文件 | 变更 | 性质 |
|---|---|---|
| `scripts/lib/pkgrel-policy.sh` | **新增**。pkgrel 策略唯一实现：`pkgrel_policy_skip` / `_field` / `_parse` / `_is_supported` / `_cmp` / `_at_most` / `_next` / `_apply` | 新文件 |
| `scripts/prepare-build-source.sh` | 重写：BUMP_PKGREL 路径接入共享库；**识别 `.pkgrel-floor-skip`**（缺陷 2.1 修复） | 行为修复 |
| `scripts/auto-repair.sh` | bump_pkgrel 策略与 apply 层**识别 `.pkgrel-floor-skip`**（缺陷 2.2 修复）；解析/递增/写回换共享实现 | 行为修复 |
| `scripts/pkgrel-floor.sh` | 删除本地 field/dotted_cmp/next_pkgrel/apply_pkgrel 四份实现，改用共享库；两种对齐模式的判据与输出文本不变 | 重构 |
| `scripts/verify-publish-inputs.sh` | 删除本地 pkgrel_at_most/next_pkgrel，改用共享库（`base_is_newer` 是 pkgver 比较，保留） | 重构 |
| `scripts/write-back-pkgrel.sh` | 删除本地 pkgrel_at_most；`src_ver/src_rel` 解析改共享库（**顺带修复行尾注释导致回写静默跳过的潜伏缺陷**）；sed 改数字模式保住行尾注释 | 重构+潜伏缺陷修复 |
| `tests/test-pkgrel-policy.sh` | **新增**。库单元 + E1/E2/E3/E4 跨入口 skip 一致性 + 递增/闸门两侧算术一致性 | 新测试 |
| `tests/test_prepare_build_source.sh` | 5→9 用例：skip 包不被 BUMP_PKGREL 递增、缺 pkgrel 行报错、.SRCINFO 在场走 sed 且不调 makepkg、makepkg 失败不留半修改/临时文件、注释保留 | 测试扩展 |
| `tests/test_auto_repair.sh` | 新增用例 6c：skip 包的 SONAME 修复改判 report-only 且文件原样 | 测试扩展 |
| `tests/test-sync-aur-packages.sh` | 三处夹具仓补拷 `scripts/lib/pkgrel-policy.sh`（夹具改动，非行为断言） | 夹具 |

共 9 个已跟踪文件修改（+189/−156）、3 个新文件。`packages/dracpanel/dracpanel-0.1.0.tar.zst` 的既有未暂存删除为 Phase 0 之前就存在的 WIP，本次未触碰。

## 2. 修复前后对比

### 2.1 缺陷 2.1：E3（prepare-build-source，ABI 重建入口）

```text
修复前（Phase 0 实测，dsh-desktop-linux fixture）:
  $ BUMP_PKGREL=true bash scripts/prepare-build-source.sh <dsh-dir>
  Automatic ABI rebuild: bumped pkgrel 1 -> 2.
  pkgrel=2                      ← skip 标记在场仍被递增 → 假升级发布 + write-back 污染源码树

修复后（本次实测）:
  $ BUMP_PKGREL=true bash scripts/prepare-build-source.sh <dsh-dir>
  prepare-build-source: pkg opts out via .pkgrel-floor-skip; nothing to bump.
  exit=0
  pkgrel=1                      ← 不动；同版本重发由发布闸门 already_published 路径兜住
```

### 2.2 缺陷 2.2：E4（auto-repair bump_pkgrel）

```text
修复前: SONAMEError/RuntimeDependencyError → 无条件 strategy=bump_pkgrel（level 3），
        escalation 开启时直接在源码树 +1 并由 repair job 提交推送 main。
修复后（本次实测，level 3 + --apply + 真实 dsh fixture）:
  status: report-only
  reason: the package opts out of pkgrel bumps via .pkgrel-floor-skip: its payload is
          upstream's prebuilt artifact, so a local rebuild cannot repair the dependency drift
  PKGBUILD 字节不变
```

策略选择处改判 + apply 层双保险（即使将来有人改回策略选择，apply 直接拒绝）。

### 2.3 缺陷 2.3：四份实现的收敛

修复前 5 处独立实现（floor 的 field/dotted_cmp/next/apply、prepare 的正则、verify 的 at_most/next、write-back 的 at_most、auto-repair 的正则 bump），其中两处互不一致：floor 的 next 接受三段 pkgrel 而 prepare/verify 拒绝；write-back 的解析不剥行尾注释。修复后唯一实现，统一政策：

- 合法形状 = 整数或一段小数；三段/空值/字母段在递增入口明确报错；
- 比较「宁可漏拦不能误拦」（非数字段 → at_most 为真，方向交给 vercmp）；
- 写回只替换数字，**行尾注释保留**（floor 原有政策，test-pkgrel-floor 用例 12 钉住；此前 prepare/write-back/auto-repair 的 `pkgrel=.*` 会吃注释，现统一保留）。

### 2.4 附带修复（审计 §2.4）

- 半修改状态：`pkgrel_policy_apply` 先在临时文件生成两份新内容、都成功才落盘；makepkg 分支从**替换后的 PKGBUILD** 在一次性子目录生成 .SRCINFO（否则 .SRCINFO 落后一档——被新测试抓出并修复）；失败路径不留临时文件（test: `a failed bump leaves PKGBUILD byte-identical with no temp files`）。
- write-back 注释解析潜伏缺陷（审计未列出，实施中发现）：

```text
修复前（端到端 fixture，pkgrel=5  # emoeem overlay: ...，产物 1.0-6）:
  （无输出，静默）→ grep pkgrel 仍为 5   ← 回写永不发生
修复后:
  WROTE BACK demo: pkgrel 5 -> 6
  pkgrel=6  # emoeem overlay: demo pkgrel bump
  \tpkgrel = 6
```

## 3. 测试报告

| 套件 | 基线（Phase 0） | 本次 |
|---|---|---|
| `./tests/run-all.sh --fast` | 126 / 0 / 2 skip | **129 / 0 / 2 skip**（+test-pkgrel-policy.sh；prepare/auto-repair 内部用例 14→20） |
| `./scripts/run-static-checks.sh` | 14/14 | **14/14**（shellcheck 覆盖新 lib 与新测试） |
| `test-pkgrel-floor.sh` / `test_prepare_build_source.sh` / `test_publish_inputs.sh` / `test_write_back_pkgrel.sh` / `test_auto_repair.sh` / `test-sync-aur-packages.sh` | 全绿 | 全绿（唯一断言更新：prepare 的注释用例从「注释被吃」改为「注释保留」，与 floor 政策对齐） |

计划 1.2 测试矩阵逐项落位：

| 场景 | 落点 |
|---|---|
| 普通源码包允许递增 | test_prepare_build_source（整数/小数/注释）+ test-pkgrel-policy §3 |
| 存在 `.pkgrel-floor-skip` 不递增 | test-pkgrel-policy §2（E1/E2/E3/E4 四入口同 fixture）+ prepare 用例 6 + auto-repair 用例 6c |
| 不存在标记用默认策略 | 同上全部默认路径 |
| pkgrel 格式异常明确报错 | prepare 用例 4（1.2.3）、用例 7（缺行）；lib 单元（cmp 非数字段、next 空值/三段） |
| 重复执行递增不产生意外修改 | prepare 用例 8（失败后字节级不变、无临时文件）；幂等性由 floor 既有用例覆盖 |
| 多个构建入口行为一致 | test-pkgrel-policy §2/§3（同一 fixture 过四入口，终值一致、互相衔接） |
| 失败不留半修改状态 | lib 双临时文件落盘 + prepare 用例 7/8 |
| PKGBUILD 可被 makepkg 解析 / .SRCINFO 一致 | 既有 build-in-arch diff 闸门不变；prepare 用例 8 验证 sed 路径产物可解析 |

## 4. 剩余风险与建议

1. **三段 pkgrel 行为变化**：`pkgrel-floor --against-repository` 对假想的 `pkgrel=x.y.z` 从「抬第三段」改为「报错退出」。仓库当前无此形状；若未来上游带来，会得到响亮失败而不是隐式递增——符合 Phase 1.1「格式异常明确报错」，但属可感知的行为变化。
2. **auto-repair 的 .SRCINFO 全量重生成保留**：bump_pkgrel 在 makepkg 可用时仍全量重生成 .SRCINFO（validation 要求全等）；CI runner 无 makepkg 时退化为行替换（validation 本就跳过该比对）。副作用修复了旧实现「runner 上 bump 必然失败回滚」的隐患。
3. **CI 全链路未实测**：本机验证覆盖脚本行为与全部本地测试；`dependency-drift.yml → build.yml → publish` 的真机链路要在下一次真实的 ABI watch 窗口观察（预期：dsh 被 STALE 时 dispatch 照旧发出，但构建内 pkgrel 不再前进，发布端走 SKIP no-op；Phase 5 将在源头掐掉这类 dispatch）。
4. **Phase 5 衔接**：skip 标记只挡「pkgrel 递增」，不挡「无意义的 rebuild dispatch 本身」。repack/data 包的 STALE 判定过滤是 Phase 3/5 的工作（package-strategy-audit §2）。

## 5. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild

# 1. 缺陷 2.1 修复现场（对照 pkgrel-flow-audit §4 的缺陷输出）：
tmp=$(mktemp -d) && cp -r packages/dsh-desktop-linux "$tmp/pkg" && rm -f "$tmp/pkg/.SRCINFO"
( cd "$tmp/pkg" && BUMP_PKGREL=true bash "$OLDPWD/scripts/prepare-build-source.sh" "$tmp/pkg" )
grep '^pkgrel=' "$tmp/pkg/PKGBUILD"; rm -rf "$tmp"
# 预期: prepare-build-source: pkg opts out via .pkgrel-floor-skip; nothing to bump.
#       pkgrel=1

# 2. 跨入口一致性：
bash tests/test-pkgrel-policy.sh
# 预期: ok: E1/E2/E3/E4 all refuse to increment when .pkgrel-floor-skip is present
#       all pkgrel-policy cases passed

# 3. 全量回归：
./tests/run-all.sh --fast 2>&1 | tail -2
# 预期: passed 129, failed 0, skipped 2 / All local checks passed.
./scripts/run-static-checks.sh 2>&1 | tail -1
# 预期: RESULT static checks passed (14/14)
```

**阶段验收结论**：1.1（所有递增入口统一策略、skip 在递增前检查、跳过时不改 pkgrel、不影响正常包、修复在底层脚本而非工作流）与 1.2（测试矩阵全覆盖、无半修改状态、.SRCINFO 同源）均满足；原构建流程兼容（127 个既有用例全绿）。可进入 Phase 2（dsh-desktop-linux 依赖修复）。
