# 构建策略（Build Strategy）

每个软件包声明一份 `.build-strategy`，自动重建调度据此决定"这个包的漂移该重建、该等上游、还是该忽略"。机制与判据的单一实现在 `scripts/lib/build-strategy.sh`。

## 四类策略

| 策略 | 含义 | 重建触发 |
|---|---|---|
| `source` | 从源码编译（含 AUR 镜像 + overlay）。payload 由本仓库构建 | 依赖 pkgver 漂移 → 重建；SONAME 断裂 → 重建（urgent，绕过冷却） |
| `vcs` | 从 Git 构建，`pkgver()` 在 makepkg 时解析版本 | 同 `source`；发布闸门对解析出的 pkgver 有放行例外（`verify-publish-inputs.sh`） |
| `binary-repack` | 原样重打包上游预编译产物（Arch 资产 / tarball / AppImage / 预编译 zip）。本仓库不编译、不重链任何字节 | 版本漂移与 SONAME 断裂都只报告（NOTE / UPSTREAM），等上游新资产，不 dispatch |
| `data` | 纯数据 / 规则集 / 静态资产（`arch=('any')`，不受系统 ABI 影响） | 同 `binary-repack` |

## 文件格式

`packages/<name>/.build-strategy`：第一个非空、非 `#` 行是策略值，其余行是注释。

```
binary-repack
# Repacks upstream's prebuilt Arch asset verbatim; drift waits for a new
# upstream asset.
```

## 15 包归类

| 策略 | 包 |
|---|---|
| `source` | ffmpeg-full, mpeghdec, quirc, sing-box-ebpf, sing-box-panel |
| `vcs` | linuxqq-wayland-fix-git, scx-scheds-git, svt-jpeg-xs-git, xclip-git |
| `binary-repack` | dsh-desktop-linux, filee-bin, trae-cn-appimage, vapoursynth-plugin-mlrt-ncnn-runtime |
| `data` | dracpanel, sing-box-rule-sets |

`dracpanel` 归 `data` 的依据：`arch=('any')`、tarball 携带预构建 Vite dist、`package()` 只拷静态文件、`check()` 强制 dist 与源码同 commit。

## 消费点（三层）

1. **依赖版本漂移**（`check-dependency-drift.sh`）：`binary-repack`/`data` 的 pkgver 漂移降级为 `NOTE`（SUMMARY 计数 `repack_only=`），不进 stale.txt；
2. **SONAME 断裂**（`check-repository-sonames.sh`）：同类包降级为 `UPSTREAM` 标签，不进 stale.txt、不作为 urgent 绕过冷却；
3. **dispatch**（`dispatch-stale-rebuilds.sh`）：防御性第二道——即使 stale 列表被其它路径塞入，`binary-repack`/`data` 也被 `IGNORE`。

## Fail-safe 方向（重要）

只有**明确声明**的 `binary-repack`/`data` 才降级为"等上游"。策略文件缺失、非法或未知时一律按**可本地重建**处理——宁可多一次重建，不可漏一次真实修复。判据集中在 `build_strategy_defers_to_upstream`，三个消费点共用。

"策略文件必须存在且合法"由 `check-package-manifests.py` 在合并前强制（pre-commit + check.yml），因此运行时的 fail-safe 分支只防御外部路径，不防仓库内遗漏。

## 校验规则

`check-package-manifests.py::check_build_strategy`：

- 每包必须存在 `.build-strategy`；
- 值必须是四者之一；
- 与 PKGBUILD 特征交叉验证：`vcs` ⇒ 必须有 `pkgver()`；`binary-repack` ⇒ 必须没有 `pkgver()`。

## 与 `.pkgrel-floor-skip` 的关系

两个声明独立：`binary-repack` 描述调度行为，`.pkgrel-floor-skip` 描述 pkgrel 抬档豁免。当前二者在 dsh-desktop-linux 上同时存在；`filee-bin` 等未声明 skip 的 repack 包本地 pkgrel 仍可抬档。

## 测试

`tests/test-build-strategy.sh`（lib 解析、fail-safe 判据、真实树 15/15、成员集合）、`tests/test_package_manifests.py` 的 build-strategy 契约 5 用例、`tests/test-dispatch-stale-rebuilds.sh` 的 IGNORE 与 dispatch 列表断言。
