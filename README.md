# ffmpeg-full 私有构建仓库

这个仓库使用 GitHub Actions 在官方 Arch Linux 容器中构建
`ffmpeg-full`。当前导入的 AUR 版本是 `8.1.2-2`，构建目标为
Arch Linux `x86_64`。

## 构建

1. 打开仓库的 **Actions** 页面。
2. 选择 **Build ffmpeg-full**。
3. 点击 **Run workflow**；普通 GitHub runner 建议保留 `2` 个并行任务。
4. 构建完成后，下载名为
   `ffmpeg-full-<版本>-x86_64` 的私有 Artifact。

Artifact 保留 30 天，包含：

- `ffmpeg-full-*.pkg.tar.zst`
- `SHA256SUMS`
- `PKGINFO` 与 `BUILDINFO`
- 本次实际使用的 `PKGBUILD` 和 `.SRCINFO`
- `install-built-package.sh`

`ffmpeg-full` 依赖 CUDA 和多项 AUR 软件包，首次构建会下载大量内容。
标准 runner 资源紧张时，可以在仓库的
**Settings -> Secrets and variables -> Actions -> Variables** 中设置
`BUILD_RUNNER=self-hosted`，改用带 Docker 的 Linux 自托管 runner。

## 安装

在 Arch Linux 上解压 Artifact，校验并安装：

```bash
sha256sum -c SHA256SUMS
chmod +x install-built-package.sh
./install-built-package.sh ./ffmpeg-full-*.pkg.tar.zst
```

安装脚本会使用已有的 `paru` 或 `yay` 补齐官方仓库及 AUR 运行依赖，
然后调用 `pacman -U` 安装构建好的包。

## 同步 AUR

**Sync ffmpeg-full from AUR** 工作流每周日检查一次上游。只有 AUR
内容变化时才会提交更新，并启动新的构建。也可以在 Actions 页面手动运行。

包文件保存在 `packages/ffmpeg-full/`，来源为：

```text
https://aur.archlinux.org/ffmpeg-full.git
```

## 许可提醒

这个包的许可标识是 `LicenseRef-nonfree-and-unredistributable`。仓库和
Artifact 应保持私有，仅供最终用户本人构建和使用；不要公开发布、共享
构建产物或用于商业用途。
