# Phase 0 基线 — emoeem/pkgbuild（2026-11-15）

只读审计。本报告及同目录其余五份为 Phase 0 唯一产物；未修改任何项目文件。

## 1. 仓库状态

| 项 | 值 |
|---|---|
| 分支 | `main`（与 `origin/main` 一致） |
| HEAD | `7c1dff2` fix(build): let repack packages opt out of the pkgrel floor |
| 工作区 | 一处**未暂存删除**：`packages/dracpanel/dracpanel-0.1.0.tar.zst`（git 跟踪的源码 tarball）。`CURRENT-STATUS.md:3` 声明工作区可能含有意未提交的 WIP，**不得推断为可丢弃，本次不处理** |
| 发布渠道 | GitHub release tag `repo`（pacman 仓库名 `emoeem`），builder 镜像 `ghcr.io/<owner>/pkgbuild-builder:latest`，generation 文件 `.github/builder/generation` |

近期提交方向：pkgrel floor 的 repack 豁免（`7c1dff2`）、planner 去传播（`c0c4f41`/`4ade683`）、dsh 自动跟踪上游（`30073f3`/`fe4ee7d`，当前 pin 0.2.2rc3）、ffmpeg-full 重建风暴治理（2026-11-10，见 `CURRENT-STATUS.md:38`）。

## 2. 包清单与事实上的分类（15 个 package base）

按更新来源（`config/package-updates.txt` + `packages/*/.aur-url`，由 `scripts/check-package-manifests.py` 强制每包声明恰好一个更新源）：

| 类别 | 包 | 更新机制 |
|---|---|---|
| AUR mirror（8） | ffmpeg-full, linuxqq-wayland-fix-git, mpeghdec, quirc, scx-scheds-git, svt-jpeg-xs-git, vapoursynth-plugin-mlrt-ncnn-runtime, xclip-git | `sync.yml` + `sync-aur-packages.sh`（overlay 机制） |
| workflow 自动（4） | dsh-desktop-linux, filee-bin, sing-box-ebpf, sing-box-rule-sets | 各自 `*-update.yml` / `refresh-rule-sets.yml` |
| 手动 repo-owned（3） | sing-box-panel, dracpanel, trae-cn-appimage | `manual` 登记 + 人工 bump |

注意：这是**更新来源**分类，不是**构建策略**分类。`binary-repack / vcs / data` 维度目前完全没有元数据表达（详见 `package-strategy-audit.md`）。

构建产物形态事实：
- 预编译重打包（repack）：`dsh-desktop-linux`（上游 Arch 包原样 repack）、`filee-bin`（上游预编译 tarball）、`trae-cn-appimage`（官方 tar.gz 组装 AppImage）、`vapoursynth-plugin-mlrt-ncnn-runtime`（上游 CI 预编译 zip + 模型 7z，`PKGBUILD:12-29` 注释明确说明无法从源码构建）
- VCS：`linuxqq-wayland-fix-git`、`scx-scheds-git`、`svt-jpeg-xs-git`、`xclip-git`（均带 `pkgver()`）
- 纯数据/资产：`sing-box-rule-sets`（`any`，6 个 .srs 数据源）、`dracpanel`（`any`，静态 Web UI）
- 源码构建：`ffmpeg-full`、`mpeghdec`、`quirc`、`sing-box-ebpf`（pin commit 的 Go 源码）、`sing-box-panel`

## 3. 工作流清单（.github/workflows/，13 个）

| 工作流 | 触发 | 职责 |
|---|---|---|
| build.yml | push(main, paths) / dispatch | 选择→矩阵构建→自动修复→发布→pkgrel 回写 |
| check.yml | PR / push(main) | 静态检查 + 全量测试套件 + per-package check-package.sh/namcap |
| dependency-drift.yml | cron `23 */2 * * *` | 版本漂移 + SONAME 漂移检测 → dispatch 重建（bump_pkgrel=true） |
| maintenance.yml | 每日/每周 | artifact 清理、chroot 基线失效、缓存用量 |
| upstream-check.yml | 每日 05:23 | nvchecker 上游版本检查（仅 5 个包有 `.nvchecker.toml`）→ 开 issue |
| sync.yml | cron | AUR 同步（overlay + pkgrel floor `--against-pkgbuild`） |
| dsh-desktop-linux-update.yml | cron `53 */2 * * *` | 上游 release → pin pkgver/sha256 → 候选构建 → commit + dispatch |
| filee-update.yml / sing-box-ebpf-update.yml / refresh-rule-sets.yml | cron | 同类专属更新器 |
| builder.yml | push(builder 相关) | 构建并发布 builder 镜像 |
| remove.yml / full-install-test.yml | dispatch | 包下架 / 全量安装测试 |

## 4. 本次实测验证基线（2026-11-15，本机）

```
./tests/run-all.sh --fast          → passed 126, failed 0, skipped 2
./scripts/run-static-checks.sh     → RESULT static checks passed (14/14)
```

2 个 skip 为设计内：`test-cachyos-environment.sh`（builder-only）、`test_repository.sh`（`--fast`）。与 `CURRENT-STATUS.md:36-38` 记录的 2026-11-05/11-10 基线一致。

上游核实（本次审计新增的硬证据，见 `dsh-audit.md` §1）：

```
curl -s https://api.github.com/repos/ffyfox/dsh-desktop-linux/releases?per_page=10
# v0.2.2rc2 release body: "去掉安装包里冗余的 XScreenSaver 依赖 … Arch 包不再要求安装 libxss"
curl -L -r 0-8388607 <rc3 asset> | zstd -dc | head …  # rc3 资产 .PKGINFO:
# depend = gtk3 nss libnotify libxtst xdg-utils at-spi2-core libsecret alsa-lib dbus libxcrypt-compat libdbusmenu-glib
# （无 libxss；本地 PKGBUILD 多声明了 libxss）
```

## 5. 历史问题登记的状态核对

- `OPTIMIZATION-REVIEW.md`（2026-10-03）：其中 P0/P1 项绝大多数已在后续提交修复（verify-repository `%FILENAME%` 解析、lint 移出 matrix、concurrency、缓存分层、AUR sync 故障隔离等，现状代码可核对）；该文档保留为历史记录，**不代表当前问题清单**。
- `CURRENT-STATUS.md`：截至 2026-11-10 的运营跟进索引，与代码现状一致；其 "ffmpeg-full rebuild storm" 行描述的三个放大器修复（pkgrel-only 只报 NOTE、24h 成功冷却、planner 漂移仅 all 选择应用）在 `check-dependency-drift.sh` / `dispatch-stale-rebuilds.sh` / `build-planner.py:176-196` 均已确认落地。

## 6. Phase 0 发现汇总（详见分报告）

| # | 问题 | 严重度 | 报告 |
|---|---|---|---|
| A1 | `prepare-build-source.sh` BUMP_PKGREL 路径不识别 `.pkgrel-floor-skip` | P0 | pkgrel-flow §2.1 |
| A2 | `auto-repair.sh` bump_pkgrel 策略同样不识别，且直接改源码树并自动提交 | P0 | pkgrel-flow §2.2 |
| A3 | dsh-desktop-linux 声明上游已删除的 `libxss`（rc3 资产 .PKGINFO 为证） | P0 | dsh §1 |
| A4 | dsh 更新器只 pin pkgrel/pkgver/sha256，永不同步 depends（A3 根因） | P0 | dsh §2 |
| A5 | 依赖漂移/SONAME 检测与 dispatch 对所有已发布包一视同仁，repack 包会被当作源码包做 bump_pkgrel 重建 | P0 | package-strategy §2 |
| A6 | ffmpeg-full 的 lensfun 为未固定 commit 的 `git+` 源 + `SKIP` 校验，且无上游追踪 | P0 | ffmpeg §2.1 |
| A7 | ffmpeg-full 构建后无 `-buildconf/-encoders/-hwaccels` 等功能验证，smoke 仅 `-version` | P1 | ffmpeg §4 |
| A8 | build.yml 无全局 concurrency；`linuxqq-clipsync-git` 陈旧引用使 upgrade-path 门禁实际只覆盖 sing-box-ebpf | P1/P2 | ci-workflow §3 |
| A9 | pkgrel 判断逻辑在 4 个脚本里各有一份实现（点分段比较、注释剥离、+1 规则） | P1 | pkgrel-flow §2.3 |

## 7. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
git log --oneline -1                 # 7c1dff2 fix(build): let repack packages opt out of the pkgrel floor
git status --short                   # " D packages/dracpanel/dracpanel-0.1.0.tar.zst"
./tests/run-all.sh --fast 2>&1 | tail -2   # passed 126, failed 0, skipped 2 / All local checks passed.
./scripts/run-static-checks.sh 2>&1 | tail -1  # RESULT static checks passed (14/14)
```
