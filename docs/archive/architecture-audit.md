# 架构审计与差异清单（Phase 1）

审计对象：本次「Arch Build Platform」升级开始前的仓库状态（工作区 = `main` + 尚未提交的上一轮整改）。
审计方式：逐文件阅读 `.github/workflows/`、`scripts/`、`client/`、`tests/`、`packages/`、`docs/`、`manage.sh`，
再用真实命令复核（`build-planner.py`、`build-dag.py`、`shellcheck`、`actionlint`、`tests/run-all.sh`）。
本文件只记录**实际验证过**的行为；推断会明确标注。

## 1. Current Architecture

| 层 | 组件 | 职责 | 入口 / 产物 |
| --- | --- | --- | --- |
| 触发 | `sync.yml` | 每天 03:17 UTC 同步 AUR 源并提交 `main` | `scripts/sync-aur-packages.sh` |
| 触发 | `sync-dae-release.yml` | 每天 02:17 UTC 比对 dae 上游并重建 `daed-emo` | `scripts/sync-dae-release.sh` |
| 触发 | `refresh-rule-sets.yml` | 每天 23:40 UTC 比对 4 个规则集上游 | `scripts/refresh-rule-sets.sh` |
| 触发 | `dependency-drift.yml`（ABI watch） | 每 2 小时检测版本漂移与 SONAME 漂移，自动 dispatch 重建 | `check-dependency-drift.sh`、`check-repository-sonames.sh` |
| 触发 | `maintenance.yml` | 清理过期 Artifact + soname 深度复查 | `scripts/dispatch-stale-rebuilds.sh` |
| 选择 | `build.yml:select` | 由 Git diff、逐包 rebuild 声明与可用 ABI manifest 决定构建集合 | `scripts/build-planner.py` + `scripts/lib/pkgbuild_lib.py` |
| 构建 | `build.yml:build` | 每包一个 matrix job，在 CachyOS-v3 容器中 `yay -Bi` | `scripts/build-in-arch.sh` → `dist/` |
| 构建环境 | `builder.yml` + `.github/builder/Dockerfile` | 发布 `pkgbuild-builder:latest|cuda` | GHCR 镜像 |
| 发布 | `build.yml:publish` | 组装 pacman 仓库并上传滚动 Release（tag `repo`） | `create-repository.sh`、`verify-repository.sh`、`publish-release.sh` |
| 校验 | `check.yml` | 语法 / .SRCINFO / shellcheck / namcap / 集成测试 | 无产物 |
| 客户端 | `client/install.sh` | 写入 `[emoeem]` 段、导入公钥 | `/etc/pacman.conf` |
| 管理 | `manage.sh` | fzf TUI：增删包、同步、构建、跟踪、失败排查、本地仓库 | 交互 |

## 2. Current Build Flow

1. `select` 读取 `github.event.before`..`sha` 的 diff，把 `packages/<name>/**`、`scripts/overlays/<name>.sh` 与 `config/**` 映射成 package base，再按 provider 图递归传播。
2. matrix 以 `package` 维度并行（`fail-fast: false`），每包一个 ubuntu runner。
3. `check-package.sh` → 释放磁盘 → 拉 builder 镜像 → 恢复缓存 → 下载已发布仓库包到 `localrepo/`。
4. 容器内 `build-in-arch.sh`：配置本地仓库 → 复制源码到 `/build/<pkg>` → 建裸仓库快照 → 校验 `.SRCINFO` → namcap → 校验 VCS 缓存 → （ffmpeg-full 额外验签+下载）→ `yay -Bi`。
5. 产物写 `/out`：`*.pkg.tar.zst`、`.PKGINFO`、`.BUILDINFO`、`SHA256SUMS`；宿主校验大小与校验和后打包成单包 Artifact。

**已知薄弱点**：构建阶段一旦失败，job 内没有结构化诊断；下游包（ffmpeg-full 依赖 mpeghdec/quirc/svt-jpeg-xs-git）与上游同批并行，可能链接到上一版。

## 3. Current Cache Flow

- 单一 `actions/cache` 步（`path: .cache/pkgbuild`），key 含 flavor 与 Dockerfile/build 脚本哈希，带 flavor 前缀 restore-keys。
- 容器内 `build-in-arch.sh` 把该目录挂成 `/cache`：`pacman`、`sources/<pkg>`、`cargo/`、`ccache`、`yay/<pkg>`。
- 发布仓库资产放在缓存树之外（`localrepo/`），并 `rm -rf .cache/pkgbuild/repo` 清理历史快照。
- ccache 已在 PATH（`/usr/lib/ccache/bin`）与 `CCACHE_MAXSIZE=2G`，但**没有任何命中率记录**，无法判断是否有收益。

## 4. Current Dependency Flow

- `.SRCINFO` 的 `pkgname` + `provides` 建立 provider → consumer 图；`depends`、`makedepends`、`checkdepends` 都参与。
- 版本约束 `foo>=1.2` 归一化为 `foo`。
- 实测（本次）：`libfoo.so=2-64` 这类 SONAME 关系会被截断成 `libfoo.so`，**与 provider 的 `provides` 拼写不匹配**，共享库依赖在图上一直是断的（本次已修）。
- 仓库内真实依赖边：`ffmpeg-full → mpeghdec, quirc, svt-jpeg-xs-git`；`linuxqq-clipsync-git → linuxqq-wayland-fix-git`；`sing-box-panel|sing-box-rule-sets → sing-box-ebpf`。

## 5. Current Failure Flow

1. `build-in-arch.sh` 无包产物时，只能 `tail -n 200` 打印 `ffbuild/config.log`；没有分类、没有根因、没有结构化报告。
2. `yay` 非零退出但已产出包时降级继续（`yay_status != 0` 分支）。
3. Artifact 只包含 `dist/` 目录，失败 job 什么都不上传 → 日志随 run 过期消失，只能人肉翻 CI 日志。
4. 自动重建路径只有 ABI watch / maintenance 的 SONAME 与版本漂移扫描；它们只会 dispatch 重建，不会修复。

## 6. Current Repository Release Flow

1. `publish` 下载所有 `built-*` Artifact（tar 保留 epoch 冒号）→ 解包 → `verify-publish-inputs.sh` 校验产物与源码版本一致（含 ABI 重建的 pkgrel+1 豁免）。
2. `fetch-repository-state.sh` 取回现有 release 资产 → `create-repository.sh` 在 archlinux 容器中重命名 GitHub 资产名、`repo-add`、可选 GPG 签名、生成 `.conf`/`SHA256SUMS`。
3. `verify-repository.sh` + `verify-repository-elf.sh`（数据库引用、SHA256、SONAME 唯一性）→ `generate-abi-manifest.sh` → `publish-release.sh`（先包后库，按 sha256 跳过未变资产，删除过期资产）。
4. `write-back-pkgrel.sh` 在 `bump_pkgrel=true` 时把 pkgrel 回写 `main`。
5. 发布前运行 `repository-install-test.sh`，在一次性 Arch/CachyOS 容器内安装选定的新包并运行已安装态 runtime verification；默认跳过大型安装闭包，必须查看日志中的 skipped 清单，不能将其写成全量安装覆盖。

## 7. 文档与代码不一致（审计发现）

| # | 发现 | 证据 | 状态 |
| --- | --- | --- | --- |
| 1 | `build.yml` / `remove.yml` 调用 `scripts/generate-abi-manifest.sh` 与 `scripts/write-back-pkgrel.sh`，但两个文件此前**未被 git 跟踪**，CI 检出后不存在 → 发布 job 必失败 | `git ls-files` 为空；两文件仅存在于工作区 | 已修：纳入索引，并新增 `tests/test_workflow_references.py` 守门 |
| 2 | `docs/build-pipeline.md` 称“`scripts/build-in-arch.sh` 和 `config/` 变化仍会触发完整重建”，而 `select-packages.py` 只把 `config/` 当基础设施；`tests/test_select_packages.py` 明确断言 build 脚本变化**不**重建 | 三处互相矛盾 | 已修：以代码与测试为准，文档更正 |
| 3 | README 的自动化清单漏了 `sync-dae-release.yml`（02:17 UTC） | README 全文无 `sync-dae` 命中 | 已修：README 补全 |
| 4 | `.gitignore` 没有 `.cache/` 规则，而 `docs/build-pipeline.md` 与 workflow 都在用 `.cache/pkgbuild` | `git check-ignore` 未命中 | 已修：补充忽略规则 |
| 5 | 包声明 `arch=('x86_64')` 却用 `GOAMD64=v3` / `-march=x86-64-v3`（daed-emo、ffmpeg-full、sing-box-ebpf） | PKGBUILD 实测 | **未修（有意）**：改为 `x86_64_v3` 会改变用户依赖行为，需要单独决策 |
| 6 | 仓库内 `scripts/` 的 sing-box 运维脚本与本机 `~/.local/bin` 副本已分叉 | 上一轮评审 §3.1 实测 | **未修**：属另一条工作线，不在本次构建平台范围 |
| 7 | 校验和 `'SKIP'` 仍出现在 6 个包，但都对应 `git+` 源 | PKGBUILD 实测 | 可接受 |

## 8. 本次升级新增的模块

| 模块 | 作用 |
| --- | --- |
| `scripts/lib/pkgbuild_lib.py` | 图语义唯一实现（provider、SONAME 关系、基础设施路径、拓扑序） |
| `scripts/build-planner.py` | Building Plan：changed / affected / rebuild / skipped + 逐包 reason |
| `scripts/build-dag.py` | 依赖波次 + 资源权重 + 槽位调度，输出 `--prerequisites-for` 供 CI 排序 |
| `scripts/build-timing.py` + `scripts/lib/timing.sh` | 分阶段计时（makepkg banner）、ccache 命中率、资源画像、历史聚合 |
| `scripts/analyze-build-failure.py` + `scripts/lib/errorrules.py` + `scripts/data/build-errors/*.yaml` | 失败分类 → 根因 → 提供者 → 受影响包 → 修复建议（59 条规则覆盖 16 类） |
| `scripts/auto-repair.sh` + `scripts/lib/transaction.sh` + `scripts/repair-budget.sh` | 事务式自动修复（Level 0-3 + 禁止 4）、字节级回滚、修复预算、审计 |
| `scripts/runtime-verify.sh` + `scripts/data/smoke-tests.yaml` | ldd / SONAME / 符号链接 / 权限 / 缺失依赖 / smoke 命令 |
| `scripts/repository-install-test.sh` | 发布闸门：把刚发布的包装回容器再验证 |
| `scripts/parallel-build.sh` + `scripts/wait-for-build-dependencies.sh` | 本地波次并行构建；CI 内下游等待上游 |
| `scripts/doctor.sh` | 一键环境自检（Git / CI / 工具链 / 仓库 / 缓存 / 磁盘 / 内存 / 网络） |
| `tests/run-all.sh` | 本地与 CI 共用的唯一验证入口 |
