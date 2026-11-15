# CI 质量门禁

"green locally" 与 "green in CI" 是同一份清单：pre-commit 钩子（`.githooks/pre-commit`）与 check.yml integration job 跑同一个 `scripts/run-static-checks.sh`；完整测试套件 `tests/run-all.sh` 两边同源。

## 门禁清单

| 检查 | 位置 | 时机 | 失败语义 |
|---|---|---|---|
| shell 语法 + shellcheck + py_compile | `run-static-checks.sh` | pre-commit + check.yml | 红（合并前） |
| 包清单政策（update source / .build-strategy / .rebuild-on 格式） | `check-package-manifests.py` | 同上 | 红 |
| PKGBUILD 语法 / `.SRCINFO` 一致性 | `check-package.sh` + namcap | check.yml per-package + 构建前 | 红 |
| 全量本地测试套件 | `tests/run-all.sh`（builder 容器内非 root） | check.yml integration | 红 |
| workflow 引用完整性（引用的脚本必须已提交） | `tests/test_workflow_references.py` | check.yml | 红 |
| source checksum + GPG | makepkg validity + `validate-source-cache.sh` + ffmpeg key 指纹预验 | 构建期 | 构建失败 |
| 上游资产校验（tag/asset/digest/.PKGINFO 字段/依赖对账） | 各更新工作流 + dsh `build()` | 更新候选构建 | 更新拒绝 / 构建失败 |
| .BUILDINFO 依赖对账 + runtime 验证 | `verify-build-dependencies.sh` + `runtime-verify.sh` | 构建后 | 红 |
| ffmpeg 功能矩阵（69 条 + 功能链 + ELF） | `verify-ffmpeg-features.sh` | ffmpeg-full 构建后 | 构建失败 |
| 构建产物检查 | SHA256SUMS / 2 GiB 上限 / 空产物拒绝 / namcap 硬门禁 | 构建后 | 红 |
| 发布闸门 | `verify-publish-inputs.sh`（降级硬拒、撞车硬拒、same-version SKIP） + `verify-repository.sh` + `repository-install-test.sh` | 发布前 | 发布失败 |
| ABI 漂移 | `dependency-drift.yml`（版本 + SONAME，每 2h） | 定时 | 检测器崩溃即红；发现即 dispatch / UPSTREAM 报告 |

## 执行原则

1. **静态在前**：pre-commit / integration 先于任何容器构建，坏包几秒内失败；
2. **高成本按需**：`build-planner.py` 逐包输出选择原因，scripts-only 变更 → 空集 no-op run；
3. **GPU 专项在 NVIDIA 环境**：自动探测，无卡显式 `not-executed`；
4. **未执行必须标注**：run-all 的 SKIP 逐条打印；ffmpeg JSON 的 gpu.detail 写明原因；
5. **不静默忽略失败**：检测器零比较即 exit 3；`|| true` 只允许出现在"失败也要继续"且另有可见性通道的步骤（namcap 报告是 advisory issue，硬门禁在构建内）；
6. **完整日志 + 机器可读报告**：build-report/ artifact、ffmpeg-features.json、runtime-*.json、timings.jsonl、drift report.txt。

## 并发与去重

- 发布串行：`pacman-repository-release` concurrency 组（build/remove 共用）；
- 修复串行：`auto-repair` 组；
- 主分支提交互斥：`main-branch-updates` 组（sync + 三个更新器共用）；
- 重建去重：dispatch 前查 active job（跨触发方式，100 runs + 时间窗过滤）→ dispatch 后 queued 确认（吸收 502 双发）→ 24h 成功冷却。**不为 build.yml 加顶层 concurrency**：push 全量与 dispatch 定点互相排队造成的积压大于偶发重复构建的成本，且仓库正确性已由发布闸门保证。

## 失败通知

`notify-failure` 复合 action 接入 9 个工作流：每个失败工作流开/更新一个 `ci-failure` issue，恢复时自动关闭。构建失败另有 `[build-failure] <pkg>: <category>: <root_cause>` 专属 issue（59 条规则的分类器 + 修复预算 + 审计记录）。

## 变更门禁清单的方式

加检查 → `scripts/run-static-checks.sh`（静态类）或 `tests/`（行为类，命名 `test-*`/`test_*` 自动被 run-all 收录）→ `tests/test-static-checks.sh` 会核对清单接线不被破坏。
