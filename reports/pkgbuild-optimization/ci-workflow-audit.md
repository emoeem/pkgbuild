# Phase 0 审计 — CI 工作流与质量门禁（2026-11-15）

## 1. 门禁现状矩阵（计划 Phase 6 对照）

| 检查项 | 现状 | 位置 |
|---|---|---|
| PKGBUILD 语法 | ✅ `bash -n`（check-package.sh:49；本地 pre-commit + check.yml 同源 `run-static-checks.sh`） | check.yml integration |
| .SRCINFO 一致性 | ✅ makepkg --printsrcinfo 比对（check-package.sh:51-60）+ 构建期 diff（build-in-arch.sh:210-213） | 双闸门 |
| pkgrel 策略测试 | ✅/❌ E1/E2/E5 有（test-pkgrel-floor / test_write_back_pkgrel / test_publish_inputs）；E3/E4 缺 skip 与一致性场景（pkgrel-flow §3） | tests/ |
| source checksum | ✅ 构建期 makepkg validity + `validate-source-cache.sh`（git 缓存）+ ffmpeg GPG 预验 | build-in-arch.sh:217-246 |
| 上游资产校验 | ✅ dsh/filee：tag+digest+.PKGINFO 字段+候选构建；rule-sets：refresh 工作流内容校验 | 各 update workflow |
| 依赖关系检查 | ✅ verify-build-dependencies（.BUILDINFO 对账）、runtime-verify（ldd/SONAME）、repository-install-test（发布闸门真实安装）、full-install-test.yml | build.yml:420-447,892-909 |
| 构建策略检查 | ❌ 不存在（Phase 3 前置） | — |
| FFmpeg 功能检查 | ❌ 不存在（ffmpeg-audit §4） | — |
| 构建产物检查 | ✅ SHA256SUMS、2 GiB 资产上限、namcap 双通道（硬门禁+advisory issue）、空产物拒绝 | build.yml:336-357,388-407 |
| ABI 检查 | ✅ abi-manifest 生成与消费 + check-repository-sonames（2h） | build.yml:88-96；dependency-drift.yml |
| workflow 引用完整性 | ✅ `test_workflow_references.py`（未提交的脚本引用会在发布时前暴露） | check.yml |
| zizmor / actionlint / shellcheck | ✅ run-static-checks 14/14（zizmor 历史清零记录 CURRENT-STATUS.md:22） | check.yml |

静态检查在前、容器构建在后、GPU 专项不存在的分层基本符合计划"执行原则"；测试未执行处有显式 SKIP 输出（run-all.sh）。

## 2. 已确认的历史修复（对照 OPTIMIZATION-REVIEW 2026-10-03）

以下当年发现的问题在当前代码已修复，Phase 6 不需重复处理：lint 已移出 per-package matrix（check.yml integration job 注释明说）；check.yml/dependency-drift/maintenance/upstream-check 均有 `concurrency`；依赖漂移检测器强制 SUMMARY 行、比较数 0 即 exit 3（check-dependency-drift.sh:179-190）；缓存分层 + localrepo 移出缓存（build.yml:265-286）；per-package 故障隔离的 AUR 同步 + notify-failure 复合 action 接入 9 个工作流。

## 3. 问题清单

### 3.1 【P1】build.yml 无全局 concurrency，重复构建仅靠 dispatcher 侧自检

- **问题描述**：`build.yml` 顶层无 `concurrency:`（仅 publish job 有 `pacman-repository-release` 组 :765-767、repair job 有 `auto-repair` 组 :533-535）。`dispatch-stale-rebuilds.sh:16-18` 注释自认"build.yml 没有全局 concurrency 去去重"，靠 dispatch 前/后查询 run 列表抑制重复——这是**尽力而为**：ABI watch dispatch 与 dsh/filee/rule-sets 更新器的 rebuild dispatch、push 触发三者仍可能在查询窗口间同时排队同一包的两个构建。
- **位置**：`.github/workflows/build.yml:48-57`（无 concurrency）；`scripts/dispatch-stale-rebuilds.sh:157-209`。
- **复现条件**：两个 2h 周期工作流（如 dsh-update `:53` 与 dependency-drift `:23`）在同一分钟窗口各自 dispatch 同一包；或 dispatch 与 push 构建重叠。
- **影响范围**：双份 30-60 分钟构建的 runner 消耗；发布端被 `pacman-repository-release` 组串行化所以**仓库不会坏**（最坏是同版本 no-op publish 被 SKIP_NOOP_PUBLISH 挪走），属成本/噪音问题而非正确性问题。
- **推荐修复**（Phase 5.3）：给 build.yml 加顶层 `concurrency: group: build-${{ github.ref }}` + `cancel-in-progress: false` 不可行（会串行化矩阵 push 构建）——正确做法是 per-package 锁：dispatcher dispatch 前已查 active job，可再加"dispatch 后确认只有一个目标包 queued run，多个则说明撞车，告警到 tracking issue"；或把 rebuild dispatch 改走单一 `workflow_call` 入口串行排队。需 Phase 5 设计时定夺，此处只登记问题。
- **验证方式**：`tests/test-dispatch-stale-rebuilds.sh` 增加撞车场景 fixture；线上以 issue #129 类 tracking comment 频次观察。

### 3.2 【P2】upgrade-path 门禁引用已下架包名，实际只保护 sing-box-ebpf

- **问题描述**：`build.yml:384` 条件 `matrix.package == 'linuxqq-clipsync-git' || matrix.package == 'sing-box-ebpf'`——`linuxqq-clipsync-git` 已在 `removals/`（下架记录存在），包目录不存在，该条件分支永不命中。
- **位置**：`.github/workflows/build.yml:383-403`；`removals/linuxqq-clipsync-git`。
- **复现条件**：静态可见。
- **影响范围**：升级路径干跑只剩 sing-box-ebpf 一个受益包；门禁意图（防止发布破坏已装用户的升级事务）覆盖面萎缩而无任何告警。
- **推荐修复**：条件改为引用现存包（如 `linuxqq-wayland-fix-git`，其 .install/打包形态正是升级路径敏感型）或做成 per-package 声明（`.build-strategy` 落地后可顺带表达"upgrade-path: true"）。
- **验证方式**：dispatch 一次 `build.yml packages=linuxqq-wayland-fix-git` 观察 upgrade-path 步骤执行；`test_workflow_references.py` 目前只查文件被 git 跟踪、不查包名存在性——可补一条"workflow 中引用的包名必须存在于 packages/ 或 removals/ 的语义检查"。

### 3.3 【P1】依赖漂移调度无策略过滤（Phase 3/5 衔接点，本报告只登记）

详见 `package-strategy-audit.md` §2——repack/data 包会被 `bump_pkgrel=true` 无意义重建。这是 Phase 5.1 的核心改动项，CI 侧无独立新问题。

### 3.4 【P2】upstream-check 覆盖面与产物标注

- 现状：仅 5 包有 `.nvchecker.toml`（ffmpeg-full/mpeghdec/quirc/svt-jpeg-xs-git/vapoursynth-mlrt）；其余包的上游跟踪由 AUR sync（隐式：AUR 动了才动）或专属 workflow 覆盖；`sing-box-panel`/`dracpanel`/`trae-cn-appimage` 为 `manual` 且上游（zashboard 版本、dracpanel fork、Trae CDN）**完全无人检测**——`package-updates.txt` 的 manual 行是"有意的过期声明"，但没有任何机制提醒"这个 manual 已经 6 个月没动了"。
- 建议（Phase 6/7）：nvchecker 按包补源（尤其 ffmpeg 子依赖，见 ffmpeg-audit §2.1）；`manual` 包加"最后人工确认日期"字段，upstream-check 输出超期清单。

### 3.5 【P2】GPU/未执行测试的标注约定缺失

计划要求"任何测试未执行都必须明确标注"。现状：run-all.sh 有 SKIP 机制（本地/CI 同源，好），但**构建产物维度的标注**（如 ffmpeg GPU 测试 not-executed）没有任何载体。Phase 4 落地 verify-ffmpeg-features 时需一并定义 `dist/` 内的机器可读标注文件（timings.json 已有先例可循）。

### 3.6 观察项（不计问题）

- `build.yml` push 触发 `paths` 含 `scripts/**`（:39-46）：配合 planner 的"scripts 变更→无包选中"逻辑，push 后 select 出空集即 no-op run（notify 的 outcome='none' 分支 :950-953 已处理），行为正确。
- publish job 无 `timeout-minutes`（repair 45、build 360 有）——它持有 `pacman-repository-release` 锁，理论可无限挂起；OPTIMIZATION-REVIEW §4.5 当年提过，现状仍未设。随 Phase 6 顺手补 `timeout-minutes: 90`。
- `remove.yml` 的发布管线与 build.yml 仍是两份实现（当年 §3.4 的建议未完全落地），但 verify-repository 现已统一调用——影响降级，登记为技术债。
- 勘误记录：OPTIMIZATION-REVIEW §4.5 当年指出 publish job 持锁无超时——**现已修复**（build.yml:762 `timeout-minutes: 90`，本次实测核对），不列入问题。

## 4. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
grep -n 'linuxqq-clipsync-git' .github/workflows/build.yml
# 预期: 384: if: success() && (matrix.package == 'linuxqq-clipsync-git' || matrix.package == 'sing-box-ebpf')
test -d packages/linuxqq-clipsync-git && echo exists || echo gone   # gone
grep -c '^concurrency:' .github/workflows/build.yml                 # 0（无顶层 concurrency）
ls packages/*/.nvchecker.toml 2>/dev/null | wc -l                   # 5
grep -n 'timeout-minutes' .github/workflows/build.yml               # 139/526/762 三个 job 均有超时
```
