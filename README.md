# 私人 Arch Linux 软件仓库

这个项目把 `packages/*/PKGBUILD` 自动构建成 Arch Linux `x86_64`
软件包，并在私有 `repo` 分支维护标准 pacman 仓库数据库。

当前维护 8 个 package base，构建环境按以下优先级使用依赖：

## Features

- 使用真实 Arch Linux `base-devel` 容器运行 `makepkg`。
- Pull Request 和 Push 自动执行 Bash 语法、`.SRCINFO`、ShellCheck 与 namcap 检查。
- 只构建发生变化的包；被变化包直接依赖的包也会自动重建。
- 成功产物通过 `repo-add` 更新 `repo` 分支中的 pacman 仓库。

## Packages

| Package | Arch | 说明 |
| --- | --- | --- |
| `ffmpeg-full` | `x86_64` | 启用大量编解码器、CUDA 和 Whisper 支持的 FFmpeg |
| `ggml-cuda-git` | `x86_64`, `aarch64` | CUDA 优化的 GGML |
| `linuxqq-clipsync-git` | `x86_64` | Linux QQ Wayland 剪贴板同步 |
| `mpeghdec` | `x86_64` | Fraunhofer MPEG-H 解码器 |
| `quirc` | `i686`, `x86_64` | QR 解码库 |
| `svt-jpeg-xs-git` | `x86_64` | JPEG XS 编解码器 |
| `whisper-cpp-cuda-git` | `x86_64`, `aarch64` | CUDA 优化的 Whisper |
| `xclip-git` | `x86_64` | X11 剪贴板命令行工具 |

版本以各目录中的 `PKGBUILD` 和 `.SRCINFO` 为准。

## Build and CI

`check.yml` 在 Arch 容器中运行 `makepkg --printsrcinfo`、ShellCheck 和
namcap；`build.yml` 独立负责只构建变更包及其直接/间接依赖，并将包作为
Artifact 保存。构建成功后由 `repo-add` 更新 `repo` 分支。AUR 同步只提交源
文件，提交本身会触发一次构建，不会重复 dispatch 同一个构建。

构建环境按以下优先级使用依赖：

1. Arch Linux 官方仓库
2. archlinuxcn
3. coderkun-aur
4. Chaotic-AUR
5. 仍未满足的依赖由 `yay` 从 AUR 构建并安装

构建容器保留 Arch 官方仓库的签名校验；未签名的第三方仓库仅在各自的
repository 段落中设置 `SigLevel = Never`。目标包本身仍由本项目保存的
PKGBUILD 重新构建，不会直接安装同名预编译包。


## 自动更新

**Sync AUR package sources** 工作流每天 `03:17 UTC` 检查一次所有带
`.aur-url` 的包目录。AUR 脚本发生变化时，它会：

1. 更新对应的 PKGBUILD、`.SRCINFO`、补丁和其他源文件。
2. 提交变化到 `main`。
3. 只触发发生变化的软件包构建。
4. 构建成功后更新 `repo` 分支中的软件包和仓库数据库。

也可以在 Actions 页面手动运行同步或指定包构建。

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
