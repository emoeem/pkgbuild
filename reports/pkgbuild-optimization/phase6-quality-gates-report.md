# Phase 6 验收报告 — CI 与质量门禁（2026-11-15）

对应计划 Phase 6。结论先行：计划表格的 10 项检查全部有落点，其中"构建策略检查"与"FFmpeg 功能检查"两项分别由 Phase 3/4 补齐——本阶段无新增代码，交付完整映射与执行原则核对。未执行任何 git commit / push。

## 1. 门禁映射（计划表格 → 落点 → 失败语义）

| 计划检查项 | 落点 | 触发时机 | 失败语义 |
|---|---|---|---|
| PKGBUILD 语法检查 | `check-package.sh`（bash -n）+ pre-commit `run-static-checks.sh` + check.yml integration | 合并前（PR/push）+ 构建前 | 红 |
| `.SRCINFO` 一致性 | `check-package.sh`（makepkg --printsrcinfo 比对）+ `build-in-arch.sh:210-213` diff | 合并前 + 构建前 | 红 |
| pkgrel 策略测试 | `tests/test-pkgrel-floor.sh` / `test-pkgrel-policy.sh`（E1–E4 一致性）/ `test_prepare_build_source.sh` / `test_publish_inputs.sh` / `test_write_back_pkgrel.sh` | run-all（pre-commit + check.yml 容器内全量） | 红 |
| source checksum 检查 | makepkg validity check + `validate-source-cache.sh` + ffmpeg GPG 预验（`build-in-arch.sh:217-246`） | 构建期 | 构建失败 |
| 上游资产校验 | dsh/filee 更新器（tag+digest+.PKGINFO+候选构建）；dsh `build()` 依赖对账（Phase 2） | 更新工作流 + 构建期 | 更新拒绝 / 构建失败 |
| 依赖关系检查 | `verify-build-dependencies.sh`（.BUILDINFO）+ `runtime-verify.sh`（ldd/SONAME）+ `repository-install-test.sh`（发布闸门真实安装） | 构建后 + 发布前 | 红 |
| 构建策略检查 | `check-package-manifests.py::check_build_strategy`（必填/四值/pkgver() 交叉，Phase 3） | pre-commit + check.yml 静态链 | 红 |
| FFmpeg 功能检查 | `verify-ffmpeg-features.sh`（69 条矩阵 + 功能链 + ELF 检查，Phase 4），`build-in-arch.sh` verify 阶段接线 | ffmpeg-full 构建后 | 构建失败（GPU not-executed 除外） |
| 构建产物检查 | SHA256SUMS 校验、2 GiB 资产上限、空产物拒绝、namcap 双通道 | 构建后 | 红 |
| ABI 检查 | `generate-abi-manifest.sh` + `check-repository-sonames.sh`（每 2h）+ UPSTREAM 降级（Phase 3） | 发布后 + 定时 | dispatch / UPSTREAM 报告 |

## 2. 执行原则逐条核对（计划 Phase 6）

| 原则 | 现状 |
|---|---|
| 普通静态检查在构建前执行 | ✅ pre-commit = check.yml integration = `run-static-checks.sh`（同源构造，check.yml 注释明说）；静态失败先于容器拉起 |
| 高成本构建按需执行 | ✅ build.yml 的 planner（`build-planner.py`）逐包给原因；scripts-only 变更 select 空集即 no-op |
| GPU 专项放 NVIDIA 环境 | ✅ `verify-ffmpeg-features.sh` GPU 三态自动探测（passed/failed/not-executed），CI 容器无卡 → not-executed |
| 测试未执行必须明确标注 | ✅ run-all SKIP 逐条打印；GPU `not-executed` 进 SUMMARY 与 JSON detail；2 个设计内 skip（builder-only / --fast） |
| 不允许静默忽略失败 | ✅ 检测器零比较即 exit 3（drift）；soname 无 SUMMARY 即红（workflow grep 断言）；矩阵断言缺失即构建失败 |
| 保留完整日志与机器可读报告 | ✅ build-report/ artifact（failure.json + timings + 日志）、ffmpeg-features.json、runtime-*.json、drift report.txt |

## 3. 本阶段验证

```
./tests/run-all.sh --fast        → passed 137, failed 0, skipped 2
./scripts/run-static-checks.sh   → 14/14（14 组静态门禁自身全绿）
actionlint（dependency-drift.yml 改动）→ 0 findings
```

门禁自身的守护测试：`tests/test-static-checks.sh`（检查清单与 hook/CI 接线等价性）、`test_workflow_references.py`（workflow 引用的脚本必须已提交）、`test_workflow_images.py`、`test_package_manifests.py`（43 用例，含 build-strategy 契约 5 条）。

## 4. 剩余风险

1. 真实 ffmpeg-full 构建上的 69 条矩阵首跑仍待 CI 窗口验证（Phase 4 已标注的 not-executed 项，属验证时点问题而非门禁缺口）；
2. `manual` 更新源的包（sing-box-panel/dracpanel/trae-cn-appimage）无上游新鲜度提醒——`package-updates.txt` 是有意声明，超期提醒列为可选改进（不阻塞验收）。

**阶段验收结论**：常见错误在合并与构建前可被发现；10 项门禁全部存在且有失败语义；执行原则逐条满足。可进入 Phase 7（文档体系）。
