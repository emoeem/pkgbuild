# Phase 5 验收报告 — 自动更新与 ABI 重建调度优化（2026-11-15）

对应计划 Phase 5.1–5.3。前置说明：本阶段的主要机制（策略分流、skip 全入口、冷却、批量合并）分别在 Phase 1/3/4 落地并有独立验收报告；本报告完成剩余缺口、逐项核对既有落点，并给出 5.3 concurrency 的决策论证。未执行任何 git commit / push。

## 1. 本阶段变更

| 文件 | 变更 | 对应计划项 |
|---|---|---|
| `.github/workflows/dependency-drift.yml` | ABI watch 汇总表新增 2 行（repack/data 的版本漂移数、UPSTREAM 断裂数）；UPSTREAM 条目逐行列出；**issue 语义修复**：UPSTREAM 附注进 issue body、UPSTREAM-only 轮次不误关 issue | 5.1 失败/等待状态可追踪 |
| `scripts/dispatch-stale-rebuilds.sh` | 查询窗口 50 → 100 runs；**追加时间窗过滤**（`state_window` = max(冷却, 24h) + 1h，jq `now -` 过滤，窗口内 run 保证完整） | 5.2/5.3 |
| `tests/test-dispatch-stale-rebuilds.sh` | 新增用例：3 天前的成功 run 不阻止 dispatch（窗口外判定） | 5.2 |

## 2. 计划逐项核对（机制落点）

### 5.1 依赖漂移逻辑

| 计划要求 | 状态 | 代码落点 |
|---|---|---|
| pkgrel-only 变化不误认为上游源码变化 | ✅（2026-11-10 落地，Phase 0 核对） | `check-dependency-drift.sh:105` NOTE |
| pkgver 变化触发相应检查 | ✅ | `check-dependency-drift.sh` STALE 路径 |
| ABI/SONAME 由独立逻辑处理 | ✅ | `check-repository-sonames.sh`（每 2h，独立 SUMMARY 门禁） |
| 预编译包不按源码包 ABI 规则处理 | ✅（Phase 3） | `check-repository-sonames.sh:252` UPSTREAM 分支；`check-dependency-drift.sh` suppress_stale |
| 失败状态可追踪 | ✅（本次补齐最后一项） | 检测器崩溃/零比较即 exit 3（`check-dependency-drift.sh:186-190`）；dispatch 失败重试 + workflow 红 + notify-failure issue；**UPSTREAM 类从 report-only 提升为 step summary 逐行可见**（本次） |

### 5.2 FFmpeg 重建频率

| 计划要求 | 状态 | 落点 |
|---|---|---|
| 保留成功冷却 | ✅ | `REBUILD_SUCCESS_COOLDOWN_SECONDS`（默认 86400，0 关闭） |
| 重复触发 | ✅ 三层防线（见 §3） | dispatcher 侧 |
| 合并同批依赖更新 | ✅ | dispatch_once 一次 workflow run 携带整个 stale 列表（`-f packages=<csv>`） |
| 无意义的 pkgrel 递增 | ✅（Phase 1） | skip 全入口 + write-back 只前进 |
| 高频 VCS 依赖独立冷却 | ✅（Phase 4 消除该类触发源） | lensfun/whisper.cpp pin + nvchecker 走 `[upstream]` issue 通道，不进 ABI watch 的依赖循环 |
| ABI 破坏绕过冷却 | ✅ | `STALE_URGENT_FILE`（soname 检测产出）绕过成功冷却 |

### 5.3 构建任务去重

**决策：不为 build.yml 增加顶层 `concurrency`。** 论证：

1. **重复构建的实际后果只是 runner 时长**：仓库正确性由 publish 端保证——`pacman-repository-release` 串行锁（build.yml:765-767）+ `verify-publish-inputs.sh` 的 same-version SKIP（SKIP_NOOP_PUBLISH=1）与 downgrade 硬拒绝。两个撞车的 run 无论顺序如何，最终数据库里是同一个合法版本。
2. **顶层 concurrency 是 workflow 级全有全无**：同一 ref（main）一个 group，push 全量构建与所有 dispatch 定点重建互相排队。本仓库每 2 小时至少 4 个调度源（ABI watch + 三个更新器）+ push；`cancel-in-progress: false` 下排队链条会线性拉长重建延迟，`true` 会砍掉进行中的构建——两者都比"偶发重复构建"更有害。
3. **现有的三层去重防线**（均有测试覆盖）：
   - dispatch 前 `load_build_state` 查最近 100 个 run 的 queued/in_progress job（**不限触发方式**，push 与 dispatch 都查；本次从 50 扩到 100 保证窗口覆盖）→ `SKIP <pkg>: rebuild already queued/running`（test: skip-active）；
   - dispatch 后 `rebuild_is_queued` 轮询确认，吸收 GitHub 502 的"已接受才报错"双发场景（test: queued-after-502）；
   - 成功冷却 24h 使同一漂移不会被连续窗口反复 dispatch（test: success-cooldown）。

## 3. 测试报告

| 套件 | Phase 4 | 本次 |
|---|---|---|
| `./tests/run-all.sh --fast` | 137 / 0 | **137 / 0 / 2 skip**（workflow YAML 改动由 actionlint + test_workflow_images/references 覆盖，均过） |
| `./scripts/run-static-checks.sh` | 14/14 | **14/14** |
| `actionlint .github/workflows/dependency-drift.yml` | — | 0 findings |
| `bash tests/test-dispatch-stale-rebuilds.sh` | — | 9 场景全过（skip-active/defer/ignore/dispatch-clean/retry-502/fail-502/queued-after-502/success-cooldown/urgent-bypass） |

## 4. 剩余风险

1. ~~**UPSTREAM 类仍无独立 tracking issue**~~ **已修复（2026-11-15 同日）**：`dependency-drift.yml` issue 步骤——UPSTREAM 清单附进已 dispatch 轮次的 issue body；UPSTREAM-only 轮次既有 issue **不再被关成"已一致"**（关闭分支排除 upstream 非空），summary 逐行列出。仍不开独立 issue：等上游不是本仓库待办，噪音大于收益。
2. ~~**100 runs 窗口**仍是上限而非时间窗~~ **已修复（2026-11-15 同日）**：`load_build_state` 的 jq 增加 `now - state_window` 时间过滤（窗口 = max(成功冷却, 24h) + 1h，`state_window` 全局计算）。窗口内 run 保证在响应里，数量上限只作分页防御；新增测试用例固化"窗口外（3 天前）成功 run 不阻止 dispatch"。
3. **`maintenance.yml` 的 soname-only 路径**复用同一 dispatcher（Phase 0 已核对），本次改动对其同样生效。

## 5. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild

# 1. 状态查询窗口：
grep -n 'per_page=' scripts/dispatch-stale-rebuilds.sh | head -2
# 预期: 两处 100（默认值与调用点）

# 2. UPSTREAM 汇总行存在：
grep -c 'upstream_only\|UPSTREAM ' .github/workflows/dependency-drift.yml
# 预期: >= 4

# 3. 去重链实测（mock gh；已在跑的包被 SKIP，不进 dispatch 列表）：
bash tests/test-dispatch-stale-rebuilds.sh
# 预期: dispatch-stale-rebuilds tests passed: skip-active, ..., queued-after-502, ...

# 4. 回归：
./tests/run-all.sh --fast 2>&1 | tail -2
# 预期: passed 137, failed 0, skipped 2 / All local checks passed.
```

**阶段验收结论**：构建调度能够区分源码更新（STALE→重建）、ABI 变化（SONAME→urgent 重建）、打包元数据变化（skip→不产生假升级）和无意义的重复任务（repack/data→IGNORE/UPSTREAM；活跃构建→SKIP）。无明显重复触发路径残留。可进入 Phase 6（CI 与质量门禁）。
