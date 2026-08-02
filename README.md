# 私人 Arch Linux 软件仓库

这个项目把 `packages/*/PKGBUILD` 自动构建成 Arch Linux `x86_64`
软件包，并在私有 `repo` 分支维护标准 pacman 仓库数据库。

当前包含 `ffmpeg-full 8.1.2-2`。构建环境按以下优先级使用依赖：

1. Arch Linux 官方仓库
2. archlinuxcn
3. coderkun-aur
4. Chaotic-AUR
5. 仍未满足的依赖由 `yay` 从 AUR 构建并安装

构建容器按你的要求使用全局 `SigLevel = Never`，因此官方仓库和这三个
第三方二进制仓库都不进行软件包或数据库签名校验。

目标包本身始终使用本项目保存的 PKGBUILD 重新构建，不会直接安装同名
预编译包。

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

## 构建产物

每个包会生成独立的私有 Actions Artifact。所有成功产物随后被合并到
`repo` 分支的 `x86_64/`：

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
