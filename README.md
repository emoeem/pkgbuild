# 私人 Arch Linux 软件仓库

这个项目把 `packages/*/PKGBUILD` 自动构建成 Arch Linux `x86_64`
软件包，并在私有 `repo` 分支维护标准 pacman 仓库数据库。

当前维护 14 个 package base，其中 mpv-Emo 维护 Stable / Development 两条构建轨道；核心 Patch（当前为 Omniphony mpv-side integration）直接进入 mpv-Emo 核心构建。

## Features

- 使用真实 Arch Linux `base-devel` 容器运行 `makepkg`。
- Pull Request 和 Push 自动执行 Bash 语法、`.SRCINFO`、ShellCheck 与 namcap 检查。
- 只构建发生变化的包；依赖通过 `.SRCINFO` 的 `pkgname` / `provides` 图递归传播。
- `scripts/overlays/<package>.sh` 变化只触发对应包；构建基础设施变化触发全量重建。
- CI 使用可复用 Arch builder image，预装仓库配置、namcap 和 yay，减少重复 bootstrap。
- Repository integration tests 在真实 Arch 容器中验证 `repo-add`、删除和 epoch 文件名处理。
- 成功产物通过 `repo-add` 更新 `repo` 分支中的 pacman 仓库。

## Packages

| Package | Arch | 说明 |
| --- | --- | --- |
| `ffmpeg-full` | `x86_64` | 启用大量编解码器、CUDA 和 Whisper 支持的 FFmpeg |
| `mpv-emo` | `x86_64` | Stable：mpv-full 级 Linux 全功能构建 + 已验证核心 Patch（当前含 Omniphony mpv-side integration） |
| `mpv-emo-git` | `x86_64` | Development：upstream master + 对应核心 Patch series，固定具体 commit |
| `ggml-cuda-git` | `x86_64`, `aarch64` | CUDA 优化的 GGML |
| `linuxqq-clipsync-git` | `x86_64` | Linux QQ Wayland 剪贴板同步 |
| `llama.cpp-cuda` | `x86_64` | CUDA 优化的 llama.cpp stable 构建 |
| `llama.cpp-cuda-git` | `x86_64` | CUDA 优化的 llama.cpp development 构建 |
| `scx-scheds-git` | `x86_64` | sched_ext 调度器集合 |
| `vapoursynth-plugin-mlrt-ncnn-runtime` | `x86_64` | VapourSynth MLRT NCNN runtime |
| `mpeghdec` | `x86_64` | Fraunhofer MPEG-H 解码器 |
| `quirc` | `i686`, `x86_64` | QR 解码库 |
| `svt-jpeg-xs-git` | `x86_64` | JPEG XS 编解码器 |
| `whisper-cpp-cuda-git` | `x86_64`, `aarch64` | CUDA 优化的 Whisper |
| `xclip-git` | `x86_64` | X11 剪贴板命令行工具 |

版本以各目录中的 `PKGBUILD` 和 `.SRCINFO` 为准。

## Build and CI

`check.yml` 在 Arch 容器中运行 `makepkg --printsrcinfo`、ShellCheck 和
namcap，同时运行 build-graph 与 repository integration tests；`build.yml`
独立负责只构建变更包及其递归依赖，并优先使用 GHCR 中的可复用 builder image。
Artifact 保存。构建成功后发布为滚动 GitHub Release（固定 tag `repo`），
pacman 直接从 Release 资产下载仓库数据库和软件包。AUR 同步只提交源
文件，提交本身会触发一次构建，不会重复 dispatch 同一个构建。
个别软件包构建失败不会阻塞其他成功构建的软件包发布。

构建环境按以下优先级使用依赖：

1. CachyOS 仓库（`cachyos-v3`、`cachyos-extra-v3`、`cachyos-core-v3`、
   `cachyos`，使用官方 mirrorlist，容器同时接受 `x86_64_v3` 架构）
2. Arch Linux 官方仓库
3. archlinuxcn
4. coderkun-aur
5. Chaotic-AUR
6. 仍未满足的依赖由 `yay` 从 AUR 构建并安装

CachyOS 仓库排在 Arch 官方仓库之前，与目标系统的仓库优先级一致：构建
链接到的是本机 CachyOS 系统实际运行的库版本。若把 CachyOS 排在后面，
Arch 会在同名包冲突时胜出，当 CachyOS 先行替换了某个库（例如 openvino
的小版本更新带来的 soname 变化）时，构建出的包在本机就会出现共享库
找不到的问题。

构建容器保留 Arch 官方仓库的签名校验；未签名的第三方仓库仅在各自的
repository 段落中设置 `SigLevel = Never`。目标包本身仍由本项目保存的
PKGBUILD 重新构建，不会直接安装同名预编译包。


## 自动更新

mpv-Emo 不再依赖 AUR 同步来决定 mpv 的版本，而是由独立的轨道控制器维护：

1. **Stable**：发现新的 mpv 正式 release，更新 `packages/mpv-emo`，并保持
   当前经过验证的核心 Patch series。
2. **Development**：读取 upstream `master` 的最新 commit，更新
   `packages/mpv-emo-git`；只有对应 Patch series 能完整应用时才允许发布。
3. **Core Patch**：Omniphony 等真正修改 mpv 核心的扩展进入 `src/patches/`，
   不再作为第二个 mpv 软件包安装。
4. 每次更新先验证 Patch 顺序、重新生成 `.SRCINFO` 并运行 package checks。
5. CI 构建成功后才更新 `repo` Release；任何补丁冲突或构建失败都会阻止
   对应轨道发布。

`Sync mpv-Emo tracks` 工作流每天 `02:47 UTC` 检查 Stable / Development，
也可以在 Actions 页面手动选择轨道。

原有 **Sync AUR package sources** 继续负责其他 AUR-managed 软件包；它
不会覆盖 mpv-Emo 的核心 Patch。**Maintenance** 工作流继续负责 Artifact
清理和 soname 依赖检查。

## 添加 AUR 软件包

在日常使用的目录克隆 `main` 源码分支：

```bash
git clone --single-branch --branch main \
  https://github.com/emoeem/pkgbuild.git \
  ~/pkgbuild-source
cd ~/pkgbuild-source
```

添加软件包只需要一条命令：

```bash
./scripts/add-aur-package.sh package-name
```

脚本会自动同步 `main`、下载并校验 AUR 构建文件、提交新包并推送。
推送后 GitHub Actions 会自动构建并更新 `repo` 分支。默认 AUR 地址是：

```text
https://aur.archlinux.org/package-name.git
```

也可以传入其他 Git PKGBUILD 仓库：

```bash
./scripts/add-aur-package.sh package-name https://example.com/package.git
```

只想生成本地提交而暂时不推送时：

```bash
./scripts/add-aur-package.sh --no-push package-name
```

完整执行流程见 `docs/add-aur-package.md`。

自维护脚本只需放入 `packages/package-name/`，并确保其中同时存在
`PKGBUILD` 和最新的 `.SRCINFO`。没有 `.aur-url` 的目录不会被自动覆盖。

## 删除软件包

从源码和二进制仓库删除一个 package base：

```bash
./scripts/remove-package.sh package-name
```

脚本从 `.SRCINFO` 记录该 package base 产生的所有子包，删除源码目录并
推送。GitHub Actions 随后从 `repo` 分支删除相应软件包并重建 pacman
数据库。只创建本地提交时使用 `--no-push`。

仓库删除不会自动卸载电脑上已经安装的软件包。删除发布完成后，可以运行
`emoeem-update` 立即同步本地仓库。

## fzf 管理界面

安装 `fzf` 和 GitHub CLI 后，可以通过一个菜单完成添加、删除、同步、
构建、本地仓库更新和安装：

```bash
sudo pacman -S fzf github-cli
./manage.sh
```

多选软件包时使用 `Tab`。完整说明见 `docs/package-management.md`。

构建依赖图、CI builder 和 repository integration tests 的设计见 `docs/build-pipeline.md`。

## 构建产物

每个包会生成独立的私有 Actions Artifact。Artifact 使用 tar 作为传输
容器，以便保留 Arch `epoch` 产生的冒号文件名；发布任务解包后，原始软件包
文件名和内容不会发生变化。所有成功产物随后被合并到 `repo` 分支的
`x86_64/`：

- `*.pkg.tar.zst`
- `emoeem.db` 与 `emoeem.db.tar.zst`
- `emoeem.files` 与 `emoeem.files.tar.zst`
- `SHA256SUMS`
- `emoeem.conf`

更新数据库时会删除同一个包的旧版本。`repo` 分支每次使用 amend 和
force-with-lease 更新，从而避免 Git 历史长期保存所有旧二进制包。

## 作为 pacman 仓库使用

GitHub 私有仓库不能直接作为匿名 HTTP pacman Server。创建普通用户可写
的目录，再使用已有的 HTTPS 凭据克隆私有 `repo` 分支：

```bash
sudo install -d -o "$USER" -g "$(id -gn)" /var/lib/emoeem-repo
git clone --depth 1 --branch repo \
  https://github.com/emoeem/pkgbuild.git \
  /var/lib/emoeem-repo
```

将下面内容加入 `/etc/pacman.conf`：

```ini
[emoeem]
SigLevel = Never
Server = file:///var/lib/emoeem-repo/x86_64
```

## 自动更新客户端

从 `main` 源码目录执行一次：

```bash
./client/install.sh
```

安装器会创建 `emoeem-update` 命令和 systemd timer。定时器每六小时：

1. 以仓库所有者身份读取私人 GitHub 凭据。
2. 强制同步最新的单提交 `repo` 快照。
3. 清理 reflog 和旧 Git 对象，避免 `.git` 随构建次数累计。
4. 校验软件包 SHA256。
5. 只更新 pacman 的 `emoeem.db` 和 `emoeem.files` 缓存。

也可以随时手动更新：

```bash
emoeem-update
```

查看定时器：

```bash
systemctl list-timers emoeem-repo-update.timer
```

如果把 `repo/x86_64` 同步到自己的私有 HTTP 服务器，只需把 `Server`
改成服务器地址，就可以像普通 Arch 仓库一样使用。

## 仓库签名

默认生成未签名的私人仓库。需要包和数据库签名时，在 GitHub 仓库
Actions Secrets 中设置：

- `REPOSITORY_PRIVATE_KEY`：ASCII armored GPG 私钥。
- `REPOSITORY_KEY_PASSPHRASE`：私钥密码；无密码时留空。

工作流会签名每个软件包、数据库和 files 数据库，并将公钥导出为
`x86_64/emoeem-key.asc`。客户端导入并本地信任该密钥后，可改用：

```ini
SigLevel = Required DatabaseRequired
```

建议为 CI 单独创建仅用于仓库签名的 GPG 子密钥。

## 资源与许可

`ffmpeg-full` 会下载 CUDA，完整构建仍可能消耗较多时间和磁盘。可以在
仓库的 Actions Variables 中设置 `BUILD_RUNNER=self-hosted`，改用带
Docker 的 Linux 自托管 runner。

`ffmpeg-full` 的许可标识是
`LicenseRef-nonfree-and-unredistributable`。仓库必须保持私有，产物仅供
最终用户本人构建和使用，不要公开发布或用于商业用途。
