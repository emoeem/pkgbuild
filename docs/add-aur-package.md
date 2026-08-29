# add-aur-package.sh 详细说明

`scripts/add-aur-package.sh` 用来把一个 AUR package base 导入 `main`
分支。它只提交 PKGBUILD、`.SRCINFO`、补丁和 AUR 版本信息，不会把
`*.pkg.tar.zst` 提交到 `main`。

## 使用方式

```bash
./scripts/add-aur-package.sh package-name
./scripts/add-aur-package.sh --no-push package-name
./scripts/add-aur-package.sh package-name https://example.com/package.git
```

默认地址为：

```text
https://aur.archlinux.org/package-name.git
```

对于 split package，应传入 AUR 页面中的 package base，也就是 Clone URL
最后的仓库名称。

## 执行流程

1. 启用 Bash 严格模式，任何命令、变量或管道错误都会停止脚本。
2. 根据脚本自身位置计算仓库根目录，不依赖当前工作目录。
3. 解析 `--no-push`、包名和可选的自定义 Git 地址。
4. 限制包名只能包含 AUR 合法名称常用的字母、数字和 `@._+-`。
5. 确认当前目录属于 Git checkout，并要求当前分支为 `main`。
6. 使用 `git pull --ff-only origin main` 快进到最新源码版本。
7. 拒绝覆盖已经存在的 `packages/package-name/`。
8. 写入 `.aur-url`，再调用 `sync-aur-packages.sh` 导入 AUR 文件。
9. 只暂存并提交新增的软件包目录，不会提交其他本地修改。
10. 默认推送到 `origin/main`；`--no-push` 只保留本地提交。

## 导入和校验

`sync-aur-packages.sh` 在临时目录浅克隆 AUR 仓库，记录当前 Git commit
到 `.aur-commit`，然后复制 PKGBUILD、`.SRCINFO`、补丁和其他顶层文件。

`check-package.sh` 随后检查：

- 包目录名称是否合法。
- `PKGBUILD` 和 `.SRCINFO` 是否存在。
- PKGBUILD 是否通过 Bash 语法检查。
- `.SRCINFO` 中声明的本地源文件是否齐全。
- `pkgbase`、`pkgver` 和 `pkgrel` 是否可读取。

## 推送后的自动流程

`packages/**` 的变化会先触发 `check.yml`，在 Arch Linux 容器中运行
`makepkg --printsrcinfo`、ShellCheck 和 namcap。随后 `build.yml` 只选择发生
变化的软件包及其依赖者，在 Arch Linux 容器中安装二进制仓库或 AUR 依赖，
然后运行 makepkg。

成功生成的 `*.pkg.tar.zst` 会封装在 tar 中作为 Actions Artifact 保存，
从而兼容 `epoch` 带来的冒号文件名。发布任务解包后再合并到 `repo` 分支，
因此软件包原始名称不会改变。`repo` 分支使用 amend 和 force-with-lease
保持单提交快照。

每天的 `sync.yml` 会检查所有带 `.aur-url` 的包。AUR commit 变化时，它
会更新文件、提交到 `main`，并只重建变化的软件包。

## 常见失败

- `current branch is not main`：切换到 `main` 后重试。
- `already managed`：该包已存在，使用 `sync-aur-packages.sh` 手动同步。
- `Missing PKGBUILD/.SRCINFO`：上游 Git 仓库不是有效的 Arch 包仓库。
- `git push` 失败：本地提交已经生成，修复认证后运行 `git push origin main`。
- 构建失败：查看 GitHub Actions 对应软件包 job 的日志。
