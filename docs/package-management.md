# 软件包管理与 fzf TUI

仓库提供添加、删除、同步、构建和本地安装的一体化管理脚本。

## 启动管理界面

安装依赖：

```bash
sudo pacman -S fzf github-cli
```

在源码仓库运行：

```bash
cd ~/pkgbuild-source
./manage.sh
```

主菜单支持：

- 从 AUR 添加 package base。
- 从自定义 Git 地址添加 PKGBUILD。
- 从源码和二进制仓库删除 package base。
- 手动触发全部或指定 AUR 脚本同步。
- 多选软件包并指定编译并行数。
- 同步本地 `emoeem` pacman 仓库。
- 从 `emoeem` 选择并安装软件包。
- 查看最近的 GitHub Actions 状态。
- 拉取最新 `main`。
- 打开或关闭添加、删除操作的自动推送。

多选界面使用 `Tab` 切换选择，`Ctrl-A` 全选，`Ctrl-D` 取消全选。
按 `Esc` 可以取消当前菜单。

默认情况下，添加和删除会立即提交并推送。以下方式启动时默认只创建本地
提交：

```bash
./manage.sh --no-push
```

可以通过环境变量调整默认配置：

```bash
PKGBUILD_GITHUB_REPOSITORY=emoeem/pkgbuild
PKGBUILD_PACMAN_REPOSITORY=emoeem
PKGBUILD_DEFAULT_MAKE_JOBS=2
```

- `PKGBUILD_GITHUB_REPOSITORY`：GitHub 的 `owner/repository`。
- `PKGBUILD_PACMAN_REPOSITORY`：`pacman.conf` 中的仓库名称。
- `PKGBUILD_DEFAULT_MAKE_JOBS`：构建菜单默认显示的并行编译数。

## 删除软件包

不使用 TUI 时，可以直接运行：

```bash
./scripts/remove-package.sh package-base
```

只创建本地提交：

```bash
./scripts/remove-package.sh --no-push package-base
```

脚本会：

1. 拉取最新 `main`。
2. 拒绝删除包含未提交修改的软件包目录。
3. 从 `.SRCINFO` 读取 package base 产生的所有 `pkgname`。
4. 删除 `packages/package-base/`。
5. 写入 `removals/package-base` 删除记录。
6. 提交并默认推送到 GitHub。

`Remove packages from private repository` 工作流随后会：

1. 读取新增的删除记录。
2. 从 `repo/x86_64` 删除匹配 `pkgname` 的所有当前版本及签名。
3. 从剩余软件包重新生成 `emoeem.db` 和 `emoeem.files`。
4. 更新 SHA256、签名和单提交 `repo` 快照。

删除完成后，本地客户端会在下次定时更新时同步。也可以立即执行：

```bash
emoeem-update
pacman -Sl emoeem
```

从仓库删除不会卸载电脑上已经安装的软件包。如需卸载：

```bash
sudo pacman -Rns package-name
```

## 重新添加

重新添加同一个 package base 时：

```bash
./scripts/add-aur-package.sh package-base
```

添加脚本会自动删除对应的 `removals/package-base` 记录，随后正常触发构建
和发布。
