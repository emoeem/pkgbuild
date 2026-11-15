# Phase 0 审计 — 软件包构建策略分类（2026-11-15）

## 1. 现状：分类能力盘点

仓库**没有**任何 build_strategy 元数据。现有可挂载点：

| 机制 | 现状 | 可复用性 |
|---|---|---|
| `config/package-updates.txt` + `scripts/check-package-manifests.py` | 每包强制声明恰好一个**更新来源**（`workflow <path>` / `manual <reason>`），check.yml 静态门禁把关；`auto-repair.sh:280-317` 已消费 `workflow` 条目做 hand-off | **高**：加一个平行文件或扩展行格式即可承载策略字段，解析器/门禁/CI 链路现成 |
| `packages/<dir>/.pkgrel-floor-skip` | 仅 dsh-desktop-linux 一个包使用；只被 `pkgrel-floor.sh` 消费（E3/E4 缺口见 pkgrel-flow §2.1/2.2） | 语义是"pkgrel 抬档豁免"，不是完整策略 |
| `packages/<dir>/.rebuild-on` | 机制完备（`list-rebuild-triggers.sh` 解析 `soname`/`package` 两类声明，`check-dependency-drift.sh:141-149` 与 `check-repository-sonames.sh` 消费，格式由 check-package-manifests.py 在 check.yml 把关，`tests/test-rebuild-on-triggers.sh` 覆盖）——但 **`find packages -name .rebuild-on` 计数为 0，生产中零使用** | 表达"额外触发"，方向与策略相反（做加法不做减法） |
| `.namcap-exclude` / `.runtime-verify-ignore` | per-package 校验豁免（dsh 各一份） | 与策略无耦合，豁免清单与包形态脱节时只能人工维护 |

## 2. 【P0】核心问题：调度系统把所有包当源码包

- **问题描述**：`check-dependency-drift.sh:133-177` 遍历全部已发布包，比较 depends/makedepends 的 pkgver 漂移；`check-repository-sonames.sh` 对全部已发布包做 ELF NEEDED 检查；两者产出的 stale 列表统一交给 `dispatch-stale-rebuilds.sh:196-200` 以 `bump_pkgrel=true` 重建。**没有任何环节区分该包重建是否有意义**：
  - repack 包（dsh-desktop-linux / filee-bin / trae-cn-appimage / vapoursynth-plugin-mlrt-ncnn-runtime）：重建 = 重新下载同一上游资产再 repack 一遍，链接关系一个字节不变；payload 里的 Electron/ncnn 二进制对系统库的 NEEDED 漂移**本地重建根本修不了**（只有上游发新资产才行）。bump pkgrel 发布的是逐字节相同的"升级"。
  - 数据包（sing-box-rule-sets / dracpanel）：与系统 ABI 完全无关（`arch=('any')`），`depends=('sing-box')` 的 pkgver 漂移对纯数据文件毫无意义。sing-box-rule-sets 的 depends/makedepends 还写着 `sing-box`（`packages/sing-box-rule-sets/PKGBUILD`），sing-box 每次 pkgver 前进都会把一个 200+ MiB 的数据包标记 STALE。
- **位置**：`scripts/check-dependency-drift.sh:133-177`（无过滤）、`scripts/dispatch-stale-rebuilds.sh:125-155`（无过滤）、`.github/workflows/dependency-drift.yml:142-162`（合并去重时无过滤）。
- **复现条件**：任一 repack/数据包的任一仓库依赖 pkgver 前进 → 下一轮 ABI watch（每 2 小时）即 STALE → dispatch（受 24h 成功冷却节流，但每天仍会重建一次）。历史上 dsh/trae/filee 尚未大量出现是因为冷却与 pkgver 变化节奏，**不是因为机制正确**。
- **影响范围**：无效构建消耗 runner 时长（dsh 单次 ~20 分钟下载+repack）、假升级版本号污染、`[skip ci]` 回写提交刷屏；真正的源码包重建信号被稀释。
- **推荐修复**（Phase 3 落地建议，复用现有机制、不引新框架）：
  1. 新增 `packages/<dir>/.build-strategy`（单行小写标记 + 注释，与 `.pkgrel-floor-skip` 同风格），四值 `source | binary-repack | vcs | data`；`check-package-manifests.py` 校验：每包必填、值合法、且与客观特征交叉验证（`binary-repack` ⇒ 不得声明 `pkgver()`；`vcs` ⇒ 必须有 `pkgver()`；缺省可按这些特征自动推断并要求人工确认）。
  2. 消费点（三处，均已有 per-package 上下文）：
     - `check-dependency-drift.sh`：`binary-repack`/`data` 包的版本漂移改为 `NOTE`（与现有 pkgrel-only NOTE 同通道），不进 stale.txt；
     - `check-repository-sonames.sh`：repack 包的 SONAME 断裂同样降级为 NOTE + 开 issue 提示"等上游资产"（当前会作为 urgent 绕过冷却强行 dispatch，对 repack 包是纯浪费）；
     - `dispatch-stale-rebuilds.sh`：对策略不明的包保持现行为（fail-safe：宁可多建不可漏建）。
  3. `.pkgrel-floor-skip` 保留，语义收窄为"pkgrel 抬档豁免"；`binary-repack` 策略不自动蕴含 skip（filee-bin 等本地 pkgrel 有意义时仍可抬），由各包自行声明。
- **验证方式**：`tests/test-rebuild-on-triggers.sh` 扩展出 `.build-strategy` 解析测试；`check-dependency-drift.sh` fixture：data 包依赖漂移 → 输出 NOTE、stale.txt 为空；源码包行为不变（现有测试回归）。

## 3. 15 包策略归类建议（供 Phase 3 确认）

| 包 | 建议 build_strategy | 依据 |
|---|---|---|
| ffmpeg-full | source | 源码编译，pkgrel 自动递增合法（E3） |
| mpeghdec / quirc | source | AUR 源码包 |
| sing-box-ebpf | source（pin commit） | `PKGBUILD` header + `prepare()` 锁 `_commit`，`CURRENT-STATUS.md:10` 的 A 决策 |
| sing-box-panel | source | 本仓库源码 + pin 的 zashboard 归档 |
| linuxqq-wayland-fix-git / scx-scheds-git / svt-jpeg-xs-git / xclip-git | vcs | 均带 `pkgver()`；VCS 的版本语义（makepkg pkgver 重算、pkgrel 重置为 1）已被 `verify-publish-inputs.sh:146-156` 处理 |
| dsh-desktop-linux | binary-repack | repack 上游 Arch 资产（`PKGBUILD:6-12`），已有 `.pkgrel-floor-skip` |
| filee-bin | binary-repack | repack 上游预编译 tarball（`CURRENT-STATUS.md:9`） |
| trae-cn-appimage | binary-repack | 官方 Electron tar.gz 组装 AppImage（`package-updates.txt`） |
| vapoursynth-plugin-mlrt-ncnn-runtime | binary-repack | 上游 CI 预编译 zip + 模型 7z，`PKGBUILD:11-19` 明确无法源码构建 |
| sing-box-rule-sets | data | `any` 架构纯 .srs 数据，refresh 工作流自管 checksum |
| dracpanel | data（或 source，见下） | `any` 架构静态 Web UI；源 tarball 本地不编译代码（构建产物是静态资产）。若坚持"从源 tarball 产出"算 source，则其 data 特征（不受 ABI 影响）仍需表达——建议直接 data 并在文件内注释说明 |

待 Phase 3 决策点：dracpanel 归 source 还是 data；`binary-repack` 是否要求强制 `.pkgrel-floor-skip`。

## 4. 与计划 3.1–3.4 处理规则的对照缺口

| 计划规则 | 现状 |
|---|---|
| source：上游/构建依赖变化评估重建、ABI 影响分析 | 部分：版本漂移 + SONAME 检测已覆盖（无策略区分） |
| binary-repack：不做无意义源码重建、不因 ABI 变化重复打包、记录上游资产版本与哈希 | ❌ 无区分；资产 pin（sha256=digest）已有（dsh/filee 更新器） |
| vcs：记录实际 commit、不隐式换源、触发条件明确、可追溯 | 部分：`validate-source-cache.sh` 缓存校验 + `.aur-commit` pin（AUR 侧）；scx/svt 等的"更新冷却"目前仅靠 24h 成功冷却兜底，无 VCS 专属冷却 |
| data：版本变化才更新、不受 ABI 触发、数据完整性检查 | ❌ 无区分；rule-sets 的 checksum 由 refresh 工作流维护（这部分是好的） |

## 5. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
find packages -name '.rebuild-on' | wc -l        # 0（声明机制零使用）
grep -n 'stale_file' scripts/check-dependency-drift.sh | head -2
# 预期: 103: ... printf '%s\n' "$name" >> "$stale_file"   （无任何策略过滤路径）
grep -rn 'build.strategy\|build_strategy' scripts/ packages/ config/ | wc -l   # 0（无元数据）
```
