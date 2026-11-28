# 依赖管理

三类输入：**包从哪更新**（update source）、**上游有什么新版本**（nvchecker）、**依赖关系怎么传播**（`.SRCINFO` + `.rebuild-on`）。

## 更新来源（每包恰好一个，`check-package-manifests.py` 强制）

| 通道 | 声明方式 | 覆盖包 |
|---|---|---|
| AUR 镜像 | 包目录 `.aur-url` + `.aur-commit`（40 位 pin） | ffmpeg-full, linuxqq-wayland-fix-git, mpeghdec, quirc, scx-scheds-git, svt-jpeg-xs-git, vapoursynth-plugin-mlrt-ncnn-runtime, xclip-git |
| 专属更新工作流 | `config/package-updates.txt` 的 `workflow <path>` 行 | dsh-desktop-linux, filee-bin, sing-box-ebpf, sing-box-rule-sets |
| 手动 | `config/package-updates.txt` 的 `manual <reason>` 行（有意的过期声明） | emobox, trae-cn-appimage |

AUR 同步（`sync-aur-packages.sh`）是 per-package 故障隔离的：单包失败不拖累整批；本地定制写进 `scripts/overlays/<pkg>.sh`（sync 每次重放，必须幂等），不要直接改包目录文件——AUR 版本会覆盖它。

## 上游版本追踪（nvchecker）

`packages/*/.nvchecker.toml`，每文件至少一个 section；`check-upstream-versions.py` 每日汇总跑 nvchecker + nvcmp，`[upstream]` issue 通道提示（开/评论/自动关闭）。

- 普通包：基线 = PKGBUILD `pkgver`（git source 且 `use_commit` 时取 `.g<sha>` 短哈希）；
- **vendored 依赖**：`__baselines__` 表给显式基线，支持 `pin:<文件>`（如 ffmpeg-full 的 `.lensfun-pin`）与 `pkgvar:<VAR>`（如 `_whispercpp_ver`）。git source 的显式基线同样截短 7 位，否则 nvcmp 恒报更新；
- 基线优先取"已发布版本"（`emoeem.db`），PKGBUILD 只作未发布包的回退——正确的问题是"发布的东西旧不旧"。

## 运行依赖声明

- `depends` 以运行时真实需要为准；构建期头文件进 `makedepends`；可选运行时能力进 `optdepends` 并写明运行条件（如 `cuda: for NVIDIA NPP filters (...)`）。
- **repack 包的 depends 对账**：dsh-desktop-linux 的 `build()` 把资产 `.PKGINFO` 的 depend 集合与本地 `depends=()` 双向比较，任一方向不一致即构建失败（上游 rc2 删 libxss 就是这样漂移了三个版本的）。依赖语义的变更由人改数组，更新器只 pin pkgver/sha256。
- 仓库内互相依赖的包（mpeghdec/quirc/svt-jpeg-xs-git → ffmpeg-full）：构建 DAG 分波次，下游 job 等待并把上游新产物 staging 进本地仓库（`wait-for-build-dependencies.sh`）。

## 仓库外触发（`.rebuild-on`）

`packages/<dir>/.rebuild-on` 逐包声明 `.SRCINFO` 表达不了的触发：

```
soname <soname> <provider>   # 本包 NEEDS 但提供者在仓库外（如 shine）
package <name>               # 仓库解析不到版本的依赖走 AUR RPC 对账
```

格式由 `list-rebuild-triggers.sh` 解析、`check-package-manifests.py` 把关、两个漂移检测器消费。逐包声明替代了旧的全局 soname 白名单（白名单只要列了，任何包缺这个库都被掩盖）。声明了但产物实际不 NEED 的 soname 会被报 `STALE-DECLARATION`（声明必须与产物一致）。

## vendored 依赖的升级流程（ffmpeg-full 为例）

1. `[upstream]` issue 提示 lensfun/whisper.cpp 有新版；
2. 改 `.lensfun-pin`（或 PKGBUILD `_whispercpp_ver`）；
3. `makepkg --printsrcinfo` 同步 `.SRCINFO`（overlay 会在下次 sync 时自动重放 pin）；
4. 完整构建验证：`#commit=` 路径的 verifysource、补丁兼容性（070 whisper 补丁）、69 条功能矩阵；
5. 矩阵假红先核对 token 与产物实际命名，修矩阵而不是放宽脚本。

## 相关文档

[ABI-REBUILD-POLICY.md](ABI-REBUILD-POLICY.md)（漂移检测与重建）、[BUILD-STRATEGY.md](BUILD-STRATEGY.md)（哪些包不参与）、[FFmpeg-FEATURE-MATRIX.md](FFmpeg-FEATURE-MATRIX.md)（功能验证）。
