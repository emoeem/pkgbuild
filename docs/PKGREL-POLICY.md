# pkgrel 政策

仓库里的版本号只允许前进。pacman 只按版本号判断"要不要升级"，repo-add 不做版本比较（按 pkgname 覆盖），所以一次同版本重发或倒退发布会让装了旧版本的机器永远收不到更新——ffmpeg-full 9.0.2-2.11 → 2.6、mpeghdec 4.0.1-2 → 1 就是历史事故。机制的单一实现在 `scripts/lib/pkgrel-policy.sh`。

## pkgrel 形状

- 合法形状：整数（`5`）或一段小数（`2.6`）。小数段记录本仓库在同一上游版本上的重建次数。
- 其余形状（三段、字母后缀、空值）：递增入口必须明确报错（`Cannot auto-bump unsupported pkgrel`），不允许猜测。
- 行尾注释保留：`pkgrel=5  # emoeem overlay: quirc pkgrel bump` 的注释是本地定制文档，所有写回只替换数字、保留注释。

## 比较 / 递增规则

- 点分段按整数比较：`2.10 > 2.9`、`2.11 > 2.6`、`3 == 3.0`。不是浮点、不是字典序。
- 递增保持段数：`5 → 6`、`2.6 → 2.7`、`2.11 → 2.12`。
- 闸门（发布 / 回写）"宁可漏拦不能误拦"：非数字段判不了时方向交给 pacman 的 vercmp。

## 会改动 pkgrel 的入口

| 入口 | 触发 | 语义 |
|---|---|---|
| E1 `pkgrel-floor.sh --against-pkgbuild` | AUR 同步（`sync-aur-packages.sh`） | 防同步把 pkgrel 拉回上游基线；同 pkgver 时取高值不是 +1 |
| E2 `pkgrel-floor.sh --against-repository` | 构建前对齐（`build-in-arch.sh`，`LOCAL_REPO_DIR` 在场时） | 构建产物必须严格新于已发布版本；少一档就抬一档 |
| E3 `prepare-build-source.sh`（`BUMP_PKGREL=true`） | ABI 重建 dispatch（build.yml input） | 构建副本 +1；`.pkgrel-floor-skip` 在场时不做任何事 |
| E4 `auto-repair.sh` bump_pkgrel | 构建失败自动修复（SONAMEError/RuntimeDependencyError，Level 3） | 源码树 +1；skip 包改判 report-only，apply 层双保险 |
| E5 `write-back-pkgrel.sh` | 发布成功后 | 以构建产物为准回写源码树；只允许前进；`[skip ci]` 提交 |
| E6 `overlays/ffmpeg-full.sh` | AUR 同步后 | ffmpeg-full 的 `.6` 下限，只升不降 |
| E7 更新器重置 | dsh/filee/sing-box-ebpf 上游新版本 | `pkgrel=1`（dsh 上游资产内嵌 `-1`，版本前进靠 pkgver） |

执行顺序：`build-in-arch.sh` 里 E3 先于 E2；`BUMP_PKGREL=true` 时先 +1 再对齐下限，所以 E2 的 skip 分支不需要"撤销"。

## `.pkgrel-floor-skip`

repack 包（payload 是上游预构建产物，本仓库不做编译链接）的显式退出标记。判据只有一个：文件存在（`pkgrel_policy_skip`）。

- 作用范围：**一切 pkgrel 递增入口**（E1–E4 全部识别；E1/E2 是原生支持，E3/E4 是 2026-11-15 Phase 1 修复的）。
- 语义：payload 与已发布版本逐字节相同时，抬高 pkgrel 只会发布一次"上游没动、版本号自己变了"的假升级。跳过时同版本重建走发布闸门的 already_published 路径（WARNING 或 SKIP no-op），不静默。
- 与 `.build-strategy` 独立（见 [BUILD-STRATEGY.md](BUILD-STRATEGY.md)）。

## 写回（write-back）

ABI 重建把 +1 做在构建副本里；发布成功后 `write-back-pkgrel.sh` 以产物版本回写源码树并提交。方向只前进：产物 pkgrel 不高于源码树时原地不动。`.PKGINFO` 的版本是单个 `pkgver = <ver>-<rel>` 字段（makepkg 不写独立 pkgrel 行），回写从该字段解析。

## 闸门链

1. 构建前：E1/E2 对齐 + `.SRCINFO` diff（`build-in-arch.sh`）；
2. 发布前：`verify-publish-inputs.sh` —— 拒绝降级（硬失败）、拒绝撞车 bump（硬失败）、same-version 静态包 WARNING、VCS 解析版本例外、bumped-pkgrel 例外；
3. 发布后：`create-repository.sh` 前删后拷 + write-back。

## 测试

`tests/test-pkgrel-floor.sh`（12+ 用例）、`tests/test-pkgrel-policy.sh`（lib 单元 + E1–E4 跨入口一致性）、`tests/test_prepare_build_source.sh`（9 用例）、`tests/test_publish_inputs.sh`、`tests/test_write_back_pkgrel.sh`、`tests/test_auto_repair.sh`。
