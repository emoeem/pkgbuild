# pkgbuild 优化与质量治理 — 最终交付汇总（2026-11-15）

七个阶段全部完成并独立验收。未执行任何 git commit / push；所有变更在工作区待用户审查。

## 1. 本次修改文件清单

已跟踪修改 29 个 + 新增 22 个 + 审计报告 9 份：

| 阶段 | 修改 | 新增 |
|---|---|---|
| Phase 1（pkgrel） | `pkgrel-floor.sh` `prepare-build-source.sh` `auto-repair.sh` `verify-publish-inputs.sh` `write-back-pkgrel.sh` `test_prepare_build_source.sh` `test_auto_repair.sh` `test-sync-aur-packages.sh` | `scripts/lib/pkgrel-policy.sh` `tests/test-pkgrel-policy.sh` |
| Phase 2（dsh） | `packages/dsh-desktop-linux/PKGBUILD` `.SRCINFO` `scripts/data/smoke-tests.yaml` | `tests/test-dsh-desktop-linux.sh` |
| Phase 3（策略） | `check-package-manifests.py` `check-dependency-drift.sh` `check-repository-sonames.sh` `dispatch-stale-rebuilds.sh` `test_package_manifests.py` `test-dispatch-stale-rebuilds.sh` `test-rebuild-on-triggers.sh` | `scripts/lib/build-strategy.sh` `packages/*/.build-strategy` ×15 `tests/test-build-strategy.sh` |
| Phase 4（ffmpeg） | `packages/ffmpeg-full/PKGBUILD` `.SRCINFO` `.nvchecker.toml` `check-upstream-versions.py` `overlays/ffmpeg-full.sh` `build-in-arch.sh` `test-build-regressions.sh` `test_upstream_versions.py` | `packages/ffmpeg-full/.lensfun-pin` `feature-matrix.txt` `scripts/verify-ffmpeg-features.sh` `tests/test-ffmpeg-features.sh` |
| Phase 5/6（调度/门禁） | `dependency-drift.yml` `dispatch-stale-rebuilds.sh`（时间窗） | — |
| Phase 7（文档） | `README.md` | `docs/` 七份 |

未触碰的既有 WIP：`packages/dracpanel/dracpanel-0.1.0.tar.zst` 的删除保持原样（见 [baseline.md](baseline.md) §1）。

## 2. 修复前后对比

各阶段报告 §2 均有现场取证的前后对照：

- [Phase 1](phase1-pkgrel-report.md) §2：E3/E4 对 skip 包从"照样 bump + 回写污染"到"拒不动"；四份实现收敛 + write-back 注释解析潜伏缺陷修复；
- [Phase 2](phase2-dsh-report.md) §2：depends 与 rc3 资产 diff 从 `9d8 < libxss` 到空；更新器永不同步 depends 的根因以 build() 双向对账闸门封死；
- [Phase 3](phase3-build-strategy-report.md) §5：真实树 dispatch 冒烟（dsh/rule-sets 被 IGNORE，ffmpeg-full 正常）；
- [Phase 4](phase4-ffmpeg-report.md) §2：lensfun 从无 pin 拉 master 到 `#commit=` + nvchecker 追踪；
- [Phase 5](phase5-scheduling-report.md) §4：两个遗留风险的当日修复（UPSTREAM 不再被误关成"已一致"；时间窗过滤保证冷却判定完整）。

## 3. pkgrel 自动化测试报告

[phase1-pkgrel-report.md](phase1-pkgrel-report.md) §3：计划 1.2 矩阵 8 行全部落位；`tests/run-all.sh --fast` 126→129（新增 test-pkgrel-policy.sh 的 lib 单元 + E1–E4 跨入口一致性）。关键断言：`.pkgrel-floor-skip` 在场时 E1/E2/E3/E4 全部不动 pkgrel；失败不留半修改状态；闸门与递增两侧算术同源。

## 4. DSH 构建和安装验证报告

[phase2-dsh-report.md](phase2-dsh-report.md) §2.4：完整真实资产（357,204,579 字节，sha256 匹配）端到端——`build()` 含依赖对账 PASS、`package()` PASS、desktop/AppArmor/chrome-sandbox 三断言 PASS、`.MTREE` 33,130 项核对顶层点文件恰 4 个。安装/卸载由既有发布闸门（repository-install-test）覆盖。

## 5. FFmpeg 构建配置与功能矩阵

`packages/ffmpeg-full/feature-matrix.txt`（69 条）+ [FFmpeg-FEATURE-MATRIX.md](../../docs/FFmpeg-FEATURE-MATRIX.md)；验证脚本 `verify-ffmpeg-features.sh`（矩阵/功能链/GPU 三态/ELF）。**标注未执行项**：69 条矩阵与真实产物的最终核对、GPU 专项 passed 态，待下次完整 ffmpeg-full 构建与有 NVIDIA 的运行点执行（脚本会自动产出 JSON 报告）。

## 6. 动态库及 ABI 检查报告

构建期：ffmpeg-full 产物 ELF 四项检查（RPATH 禁止/ldd/绝对路径 NEEDED/构建树泄漏）随每次构建执行，桩测试验证全部失败语义（[phase4](phase4-ffmpeg-report.md) §3）。运行期：runtime-verify（ldd/SONAME/权限/烟测）+ 发布后 ABI manifest + 每 2h soname 检测（UPSTREAM 降级，[phase3](phase3-build-strategy-report.md)）。

## 7. CI 执行结果

最终基线（本机，2026-11-15）：

```
./tests/run-all.sh --fast        → passed 137, failed 0, skipped 2   （基线 126）
./scripts/run-static-checks.sh   → 14/14
actionlint / shellcheck / py_compile → 全绿
真实树 manifests 校验            → SUMMARY packages=15 errors=0
```

137 = 126 基线 + 11 个新测试文件/扩展（pkgrel-policy、build-strategy、dsh、ffmpeg-features、manifests +5、dispatch、regressions、upstream）。CI 真机首轮（check.yml/build.yml）待 push 后由用户触发。

## 8. 尚未解决的问题和风险

1. **【待验证】** ffmpeg-full 69 条矩阵在真实产物上的首跑（token 命名核对）；GPU 专项执行；
2. **【待验证】** `#commit=` 路径的 `makepkg --verifysource` 与 lensfun staging 构建在下一次完整构建走过；
3. **【观察】** 下一次真实上游 release 时，dsh 依赖对账闸门与更新器链路首次在 CI 走全流程；ABI watch 的 UPSTREAM 汇总/issue 语义首次实战；
4. **【已知取舍】** build.yml 无顶层 concurrency（论证见 [phase5](phase5-scheduling-report.md) §2）；UPSTREAM 类无独立 issue（等上游不是本仓库待办）；
5. **【外部依赖】** lensfun pin 基线追踪依赖 `upstream-check.yml` 的 nvchecker 运行（每日 05:23 UTC）；GitHub cron 投递延迟属已知平台行为；
6. **【既有 WIP】** dracpanel tarball 删除未处理（用户保留的意图不明，未动）。

## 9. 后续建议

1. push 后观察首轮 CI：重点看 ffmpeg-full 完整构建的矩阵首跑结果与 dsh 对账绿灯；
2. 用真实 dispatch 链路验证一次（`gh workflow run dependency-drift.yml`），核对 step summary 的新行与 issue 语义；
3. `manual` 更新源的三个包可加"最后人工确认日期"字段与超期提醒（Phase 0 审计 3.4 的可选改进）；
4. UPSTREAM 等待若长期积压（上游停更），考虑把对应包转入 `manual` 更新源并在 issue 说明——策略机制已支持，无需新代码；
5. 累积几轮真实运行后，把 `dist/ffmpeg-features.json` 与 timings 一起归档进 `state/`，形成功能漂移的历史曲线；
6. 文档与机制的同步维护入口见 [phase7](phase7-docs-report.md) §2。

## 复现（全链路）

```bash
cd /media/emo/code/pkgbuild
./tests/run-all.sh --fast 2>&1 | tail -2
# passed 137, failed 0, skipped 2 / All local checks passed.
./scripts/run-static-checks.sh 2>&1 | tail -1
# RESULT static checks passed (14/14)
bash tests/test-pkgrel-policy.sh && bash tests/test-build-strategy.sh && \
  bash tests/test-dsh-desktop-linux.sh && bash tests/test-ffmpeg-features.sh
# 四个新套件各输出 all ... cases passed
```

各阶段独立验收报告与本目录其余 9 份文件共同构成最终交付。
