# Phase 3 验收报告 — 软件包构建策略分类（2026-11-15）

对应计划 Phase 3；问题定位见 [package-strategy-audit.md](package-strategy-audit.md)。未执行任何 git commit / push。

## 1. 实现方式（计划 3.5：复用现有机制，不引新框架）

采纳 Phase 0 审计推荐方案：

- **元数据**：`packages/<dir>/.build-strategy`，与 `.pkgrel-floor-skip` 同风格——第一个非空、非 `#` 行是策略值（`source | binary-repack | vcs | data`），其余为注释说明。15 个包全部写入。
- **读取**：`scripts/lib/build-strategy.sh`（唯一实现）：`build_strategy_of`（解析）+ `build_strategy_defers_to_upstream`（判据）。
- **校验**：`check-package-manifests.py` 新增 `check_build_strategy`，挂进既有静态检查链（pre-commit + check.yml + run-all），无需新工作流。

## 2. 变更文件清单

| 文件 | 变更 |
|---|---|
| `scripts/lib/build-strategy.sh` | **新增**。解析 + 判据（唯一实现） |
| `packages/*/.build-strategy` × 15 | **新增**。逐包声明 + 理由注释 |
| `scripts/check-package-manifests.py` | `check_build_strategy`：必填、四值合法、与 `pkgver()` 特征交叉验证（vcs ⇒ 必须有 pkgver()；binary-repack ⇒ 必须没有） |
| `scripts/check-dependency-drift.sh` | 消费点 1：binary-repack/data 的依赖 **pkgver** 漂移降级 NOTE（含指名 + 策略 + 原因），不写 stale.txt；SUMMARY 新增 `repack_only=%d`；顺带清理了重复的计数器初始化（审计 §2.4-2） |
| `scripts/check-repository-sonames.sh` | 消费点 2：binary-repack/data 的 SONAME 断裂降级 `UPSTREAM` 标签（报告"等上游资产，不 dispatch"），**不进 stale.txt、不再作为 urgent 绕过冷却**；source/vcs 保持 STALE + urgent |
| `scripts/dispatch-stale-rebuilds.sh` | 消费点 3（防御）：即使 stale 列表被其它路径塞入 binary-repack/data，dispatch 前直接 IGNORE |
| `tests/test-build-strategy.sh` | **新增**。lib 解析 / fail-safe 判据 / 真实树 15/15 / repack-data 成员集合与审计一致 |
| `tests/test_package_manifests.py` | +5 用例（missing / 非法值 / vcs 缺 pkgver() / binary-repack 带 pkgver() / vcs 带 pkgver() 放行）；夹具默认补 `source` |
| `tests/test-dispatch-stale-rebuilds.sh` | +IGNORE 断言与 fixture（binary-repack/data 包）；断言 dispatch 列表不含 repack/data |
| `tests/test-rebuild-on-triggers.sh` | 夹具仓补拷两个 lib（drift 脚本现在 source 它们） |

## 3. 15 包归类（与审计 §3 一致，含 dracpanel 决策）

| 策略 | 包 |
|---|---|
| `source`（5） | ffmpeg-full, mpeghdec, quirc, sing-box-ebpf, sing-box-panel |
| `vcs`（4） | linuxqq-wayland-fix-git, scx-scheds-git, svt-jpeg-xs-git, xclip-git |
| `binary-repack`（4） | dsh-desktop-linux, filee-bin, trae-cn-appimage, vapoursynth-plugin-mlrt-ncnn-runtime |
| `data`（2） | sing-box-rule-sets, **dracpanel** |

**dracpanel 决策：data。** 依据：`arch=('any')`；tarball 携带预构建 Vite dist，`package()` 只拷贝静态文件（无编译链接）；`check()` 已强制 dist 与源码同一 commit（满足计划 3.4"数据完整性检查"）。它不受系统 ABI 影响，`depends=('sing-box-panel')` 的版本漂移对静态 UI 无意义。

## 4. 关键设计决策：fail-safe 方向（实施中修正）

第一版实现曾把「策略缺失/非法」也当作 defer（dispatch 端 IGNORE），被 dispatch 测试的裸夹具当场抓出。修正并钉死为唯一方向：

> **只有明确声明的 `binary-repack`/`data` 才降级为"等上游"；策略缺失、非法、未知一律按可本地重建处理（宁可多一次重建，不可漏一次真实修复）。**

判据集中在 `build_strategy_defers_to_upstream`，三个消费点共用；`tests/test-build-strategy.sh` 用例 2 明确断言空值/garbage 不 defer。而"策略是否合法存在"由 check-package-manifests.py 在合并前强制（每包必填），两条防线分工：CI 挡住新包忘写策略，运行时对未知保持 fail-safe。

## 5. 修复前后行为对比（真实树冒烟，mock gh）

```text
修复前: stale 列表里的任何包（含 repack/data）都会被 dispatch 且 -f bump_pkgrel=true
修复后:
  stale 输入: dsh-desktop-linux, sing-box-rule-sets, ffmpeg-full
  → IGNORE dsh-desktop-linux: build strategy binary-repack cannot be repaired by a local rebuild; the payload moves upstream.
  → IGNORE sing-box-rule-sets: build strategy data cannot be repaired by a local rebuild; ...
  → Dispatching stale packages: ffmpeg-full / stale=ffmpeg-full
```

调度端到端语义（Phase 5.1 验收的前置条件）现已成立：**源码/vcs 包 → STALE + 重建；repack/data → 只报告 + 等上游；元数据变化 → Phase 1 起不再产生假升级**。

## 6. 测试报告

| 套件 | Phase 2 | 本次 |
|---|---|---|
| `./tests/run-all.sh --fast` | 131 / 0 | **134 / 0 / 2 skip**（+test-build-strategy.sh；manifests 38→43 用例；dispatch 扩展） |
| `./scripts/run-static-checks.sh` | 14/14 | **14/14** |
| `python3 scripts/check-package-manifests.py`（真实树） | — | `SUMMARY packages=15 errors=0` |

## 7. 剩余风险

1. **sonames 的 UPSTREAM 类不可见于 issue**：依赖 drift 工作流汇总只统计 `^STALE `，UPSTREAM 只进 report.txt（有 `SUMMARY` 与逐行报告，机器可读）。是否为 UPSTREAM 开 tracking issue 由 Phase 5/7 决定（避免为"等上游"制造噪音 issue）。
2. **策略与包实际行为的漂移**：校验交叉验证只覆盖 `pkgver()` 特征；例如把 source 包误标 binary-repack 无法被静态发现——依赖 review。合并后任何新包必须写策略（否则静态检查红）。
3. **`.aur-url` AUR 包均为 source/vcs**：若未来某 AUR 镜像实为 repack 性质，归类需人工判断（manifests 校验拦不住语义错误）。
4. dsh 的 `.pkgrel-floor-skip` 与 `binary-repack` 是两个独立声明（策略≠skip，filee 等未声明 skip 依旧可抬档）——语义边界已写进 lib 注释，Phase 0 审计的决策点就此落定。

## 8. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
bash tests/test-build-strategy.sh
# 预期: ok: 15/15 packages declare a legal strategy
#       ok: repack/data membership matches reports/pkgbuild-optimization/package-strategy-audit.md
#       all build-strategy cases passed

python3 scripts/check-package-manifests.py | tail -1
# 预期: SUMMARY packages=15 errors=0

# 真实树 dispatch 冒烟（mock gh）：
tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\ncase "${1:-}" in api) printf "900\\tcompleted\\tsuccess\\t1\\n";; workflow) ;; esac\n' > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
printf 'dsh-desktop-linux\nsing-box-rule-sets\nffmpeg-full\n' > "$tmp/stale.txt"
export GITHUB_REPOSITORY=emoeem/pkgbuild GITHUB_STEP_SUMMARY="$tmp/state/summary.txt" GITHUB_OUTPUT="$tmp/state/output.txt"
PATH="$tmp/bin:$PATH" bash scripts/dispatch-stale-rebuilds.sh "$tmp/stale.txt" >/dev/null
cat "$tmp/state/summary.txt" "$tmp/state/output.txt"; rm -rf "$tmp"
# 预期: IGNORE dsh-desktop-linux … / IGNORE sing-box-rule-sets … / Dispatching stale packages: ffmpeg-full / stale=ffmpeg-full

./tests/run-all.sh --fast 2>&1 | tail -2
# 预期: passed 134, failed 0, skipped 2 / All local checks passed.
```

**阶段验收结论**：每个软件包都有明确的构建策略（15/15，静态检查强制）；自动重建调度按策略执行正确操作（版本漂移、SONAME 断裂、dispatch 三层全部按策略分流，实测验证）。可进入 Phase 4（FFmpeg 构建质量优化）。
