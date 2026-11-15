# Phase 7 验收报告 — 文档与维护体系（2026-11-15）

对应计划 Phase 7。未执行任何 git commit / push。

## 1. 新增文档（7 份，全部基于已落地机制写成，无愿景条款）

| 文档 | 内容锚点 |
|---|---|
| `docs/BUILD-STRATEGY.md` | 四类策略定义、`.build-strategy` 格式、15 包归类表（含 dracpanel→data 依据）、三层消费点、fail-safe 方向、与 `.pkgrel-floor-skip` 的关系、校验规则 |
| `docs/PKGREL-POLICY.md` | pkgrel 形状政策、E1–E7 七入口表、skip 全入口语义、write-back 方向、三段闸门链、行尾注释保留 |
| `docs/ABI-REBUILD-POLICY.md` | 两类检测器与硬性"跑不动就报错"要求、STALE/UPSTREAM/NOTE 三态、四种节流（成功冷却/urgent 豁免/失败冷却/时间窗）、repack 处理原则、ABI manifest |
| `docs/DEPENDENCY-MANAGEMENT.md` | 更新来源三通道（AUR/workflow/manual）、nvchecker 与 `__baselines__`（pin:/pkgvar:）、dsh 依赖对账、`.rebuild-on`、vendored 依赖升级流程五步 |
| `docs/FFmpeg-FEATURE-MATRIX.md` | 矩阵六类格式、覆盖范围（69 条）、GPU 三态语义、ELF 四项检查、假红修正原则、本地手动运行命令 |
| `docs/CI-QUALITY-GATES.md` | 13 行门禁表（位置/时机/失败语义）、六条执行原则、并发去重决策（含"不加顶层 concurrency"的论证）、失败通知、门禁自身的守护测试 |
| `docs/TROUBLESHOOTING.md` | 按症状索引：发布/版本类、构建类、调度/ABI 类、更新器类、本机环境类，全部对应仓库真实事故（倒退、SRCINFO mismatch、矩阵假红、CDN 404、toomanyrequests、502、UPSTALL 等待、对账失败） |

`README.md` 新增"文档索引"表（Build and CI 节内，7 行链接）。

## 2. 文档与代码的一致性约束

各文档引用的机制、脚本名、参数、默认值（冷却 86400、窗口 90000、矩阵 69 条、137 用例）均为当前代码实测值。后续改机制时同步改文档的入口：

- 策略/判据变化 → `docs/BUILD-STRATEGY.md` + `tests/test-build-strategy.sh`；
- pkgrel 政策变化 → `docs/PKGREL-POLICY.md` + `tests/test-pkgrel-policy.sh`；
- ffmpeg 矩阵条目变化 → `packages/ffmpeg-full/feature-matrix.txt`（唯一事实来源）+ `docs/FFmpeg-FEATURE-MATRIX.md` 的计数行。

## 3. 验证

```
./tests/run-all.sh --fast        → passed 137, failed 0, skipped 2
./scripts/run-static-checks.sh   → 14/14
```

## 4. 剩余风险

1. 文档是手写快照：机制演化与文档更新靠上述入口约束（测试钉住行为，文档描述行为），无自动同步机制——与仓库现有 docs（build-pipeline.md 等）同级维护。
2. `TROUBLESHOOTING.md` 中的运维命令（doctor.sh、remove-legacy-repo-update.sh）沿用现有脚本行为，未新增验证路径。

**阶段验收结论**：文档能够解释整个构建和发布体系（四份政策文档 + 功能矩阵 + 门禁清单 + 排障手册），维护者与 AI Agent 可从 README 索引单跳到达。全部七个阶段完成。
