# 构建平台（Building Platform）

本文件描述 2026-10 引入的构建平台层：Build Plan、DAG 调度、分层缓存与时序、
失败分析、事务式自动修复、运行时验证与发布闸门。架构现状与差异清单见
`architecture-audit.md`。

全部入口都在 `scripts/` 下，本地与 CI 走同一套代码。

## 1. Build Plan：为什么这个包会被重建

`scripts/build-planner.py` 是唯一的构建决策点。输入 Git diff、`.SRCINFO`、
依赖图、overlay 变更、已发布仓库状态（ABI 清单）与历史耗时，输出
`build-plan/plan.json` 的 `changed / affected / rebuild / skipped` 与逐包 `reason`，
以及人类可读的 `build-plan/plan.txt`（CI 会写进 step summary）。

`./scripts/build-planner.py --selection changed --before HEAD~1 --after HEAD`
`./scripts/build-planner.py --selection all --repository-manifest published/x86_64/emoeem-abi-manifest.txt`

## 2. DAG 与资源感知调度

`scripts/build-dag.py` 由同一张图算出波次与槽位：真正互相依赖的包被串行化
（`ffmpeg-full` 必须等 `mpeghdec` / `quirc` / `svt-jpeg-xs-git`），其余按
CPU / 内存 / 磁盘 / GPU 权重打包；权重来自 `scripts/data/package-resources.yaml`，
有实测数据时以实测（CPU 时间、cgroup 峰值内存）为准。

`./scripts/build-dag.py --plan build-plan/plan.json`
`./scripts/build-dag.py --prerequisites-for ffmpeg-full`
`./scripts/parallel-build.sh --dry-run`     # 只看排期
`./scripts/parallel-build.sh --jobs 3`      # 本地波次并行构建

CI 侧 matrix 仍是一包一 job，但每个 job 会先执行
`scripts/wait-for-build-dependencies.sh`：等本 run 内自己的仓库内前置包结束。
该步骤刻意「失败开放」——API 读不到时告警并继续，宁可有排序风险，也不让监控接口阻断构建。

## 3. 分层缓存与 builder generation

| 层 | 路径 | key 依赖 |
| --- | --- | --- |
| pacman 包 | `.cache/pkgbuild/pacman` | generation + flavor + builder 定义 |
| VCS / 源码 | `.cache/pkgbuild/sources` | generation + flavor + 缓存校验脚本 |
| Cargo | `.cache/pkgbuild/cargo` | generation + builder 定义 |
| ccache | `.cache/pkgbuild/ccache` | generation + flavor |

四层各自有 `restore-keys`，key 落空时仍能从同层旧快照恢复，不会整体冷启动。

`.github/builder/generation` 是 builder 的唯一版本来源：修改它等于明确宣布
「所有派生缓存失效」，而不是改一次 Dockerfile 顺手把所有缓存扔掉的副作用。
Dockerfile 把它写成 LABEL 与 ENV，`builder.yml` 以 build-arg 传入。

## 4. 构建时序与缓存命中率

`scripts/build-in-arch.sh` 把 makepkg 输出经 `build-timing.py stamp` 打时间戳，
再用 makepkg 自己的阶段横幅（`==> Starting build()...`）切出真实分段：

`snapshot / retrieve / validate / extract / prepare / build / check / package / tidy / create`

外加编排阶段 `dependencies / verify / smoke / total`，ccache 命中率（每次构建前
`ccache --zero-stats`，因此统计只覆盖本次构建），以及资源画像（子进程 CPU 时间、
cgroup 峰值内存、源码缓存字节数、产物字节数、MAKE_JOBS）。

`./scripts/build-timing.py report --db state/timing-history.jsonl`

历史由 `publish` job 追加到 `state/timing-history.jsonl`，再反馈给 planner 的
耗时预估（`--timing-db`）。未测量的阶段显示为「未测量」，不会被当成 0。

## 5. 失败分析

`scripts/analyze-build-failure.py` 与 `scripts/data/build-errors/*.yaml`（59 条规则、
覆盖 16 类错误）把日志变成结构化结论：阶段、类别、根因、提供者、受影响包、
ABI 是否不匹配、建议动作、允许的自动修复等级与置信度。

排序刻意偏向「能行动的根因」：一个消失的 SONAME 同时会产出一个下游
`cannot find -l` 链接错误，把症状当结论正是 SONAME 漂移长期被误判为普通链接失败的原因。

每次失败都会产出 `artifacts/build-report/` 包：`summary.json`、`failure.log`、
`dependency-tree.txt`、`environment.txt`、`package-metadata.txt`、
`build-plan.json`、`timings.json`、`repair-*.json`。

## 6. 自动修复：分级 + 事务 + 预算

`scripts/auto-repair.sh` 的每次修改都走
`snapshot → apply → validate → (rebuild) → commit 或 rollback`。

| Level | 允许的内容 |
| --- | --- |
| 0 | 只报告，不碰文件 |
| 1 | `.SRCINFO` 重新生成、缓存 / 临时目录清理 |
| 2 | 校验和刷新（仅 `.aur-url` 跟踪的包）、pkgrel bump |
| 3 | 需要重建 + 验证才能信任的修复（SONAME 漂移重建） |
| 4 | 禁止自动提交，只输出建议补丁 |

`AUTO_FIX_LEVEL` 是上限（默认 2，CI 通过 repository variable 调整）。验证失败会
**逐字节回滚**工作区：`tests/test_auto_repair.sh` 用 sha256 断言「失败的修复不会留下
半改的 PKGBUILD」。`scripts/repair-budget.sh` 用 `state/repair-history.jsonl` 限制
「build → fix → build」循环（默认 24 小时窗口内最多 2 次），到顶即交给人工。

## 7. 运行时验证与发布闸门

`makepkg` 成功不等于包能用。`scripts/runtime-verify.sh` 检查未解析的共享库
（`ldd`）、SONAME 与文件名不符、断裂符号链接、缺失或不可执行的预期二进制、
`pacman -Qkk` 的文件属性、缺失运行时依赖，以及 `scripts/data/smoke-tests.yaml`
中声明的 smoke 命令（例如 `ffmpeg -version`）。

发布前还有最后一道闸门 `scripts/repository-install-test.sh`：在一次性容器里从
**刚发布的仓库**安装刚构建的包，再对安装结果跑一遍运行时验证。装不上的仓库不会被
发布；依赖闭包过大的包默认跳过，可用 `INSTALL_TEST_ALL=1` 打开。

## 8. 一键诊断

`./scripts/doctor.sh`（或 TUI 的「运行环境自检」）一次检查 Git、CI 配置
（`actionlint`）、`shellcheck`、GitHub CLI、容器运行时、pacman、makepkg、ccache、
仓库完整性、未跟踪脚本、缓存、磁盘、内存、网络，最后给出
`READY` / `READY WITH WARNINGS` / `NOT READY`；`--json` 输出机器可读结果。

## 9. 统一验证入口

`./tests/run-all.sh` 与 CI integration job 执行同一套检查：

| 组 | 内容 |
| --- | --- |
| Syntax | 全部 `.sh` 的 `bash -n` |
| Lint | `shellcheck --severity=warning`、`actionlint` |
| Python | `py_compile` + 全部 `tests/test_*.py` |
| Behaviour | 全部 `tests/test-*.sh` / `tests/test_*.sh` |

`./tests/run-all.sh --fast` 用于跳过需要容器或 root 的项。
`tests/test_workflow_references.py` 专门守「workflow 引用的脚本必须已提交」——
CI 检出的是提交而不是工作区，曾经因此让发布 job 在运行时才失败。

## 10. 优化指标

| 指标 | 观测方式 |
| --- | --- |
| 构建时长 | `state/timing-history.jsonl`、`build-timing.py report` |
| 缓存命中率 | 每次构建的 ccache 命中率（`timings.json.cache.hit_rate`） |
| 无谓重建 | Build Plan 的 `skipped` 计数与逐包 reason |
| 失败定位时间 | `build-report/summary.json` 的三个字段：category/root_cause/provider |
| 自动修复成功率 | `state/repair-history.jsonl` 中 `status=applied` 的比例 |
| 回归率 | `tests/run-all.sh` 的通过与失败计数 |
| 发布可靠性 | `verify-repository.sh` + `repository-install-test.sh` 的分步结论 |
