# 构建流水线与仓库维护

当前仓库采用四层流水线：Build Graph Correctness、CI Builder Optimization、Repository Integration Tests、Repository Management UI。

## 1. Build Graph Correctness

`scripts/select-packages.py` 从 `.SRCINFO` 建立 provider → consumer 图。

- 直接依赖会触发下游包重建。
- `provides` 虚拟包会参与依赖传播，例如 `ffmpeg-full` 提供 `ffmpeg` 时，依赖 `ffmpeg` 的包会被选中。
- `depends` 中的版本约束会先归一化为依赖名。
- Split package 的多个 `pkgname` 也被视为同一个 package base 的 provider。
- `scripts/overlays/<package>.sh` 变化只触发对应 package。
- `scripts/build-in-arch.sh` 和 `config/` 变化仍会触发完整重建。
- `--root` 参数允许在隔离的 Git fixture 中测试选择逻辑。

因此普通文档修改不会触发 package build，而影响依赖 ABI/API 的包会向下游传播。

## 2. CI Builder Optimization

`.github/builder/Dockerfile` 直接基于官方 CachyOS x86-64-v3 构建镜像，预装：

- CachyOS x86-64-v3 / 官方仓库
- git、gnupg、curl、jq、namcap、sudo
- builder 用户
- yay-bin

`builder.yml` 在构建器定义变化时发布 `pkgbuild-builder:latest` 到 GHCR。普通 package build 会优先拉取该镜像；镜像暂不可用时自动在 runner 上构建 fallback，因此不会因为首次发布构建器而阻塞主构建流水线。

使用预构建镜像后，package job 不再重复执行 CachyOS repository bootstrap 和 yay bootstrap。`build-in-arch.sh` 的本地路径要求宿主机本身是 CachyOS 且启用 `cachyos-v3`，不会再在 Arch 容器里临时拼装 CachyOS 仓库。

## 3. Repository Integration Tests

`tests/test_select_packages.py` 覆盖：

- `provides` 虚拟依赖传播
- 多级依赖传播
- overlay 精确触发
- 无关文档不触发构建
- build infrastructure 触发全量重建

`tests/test_repository.sh` 使用真实 `repo-add` 验证仓库生成、GitHub Release 文件名清洗和删除 package 后数据库更新。

## 4. fzf 管理界面

`manage.sh` 新增「仓库状态总览」，在不离开终端的情况下展示：

- GitHub 仓库与当前分支
- 工作区状态
- 托管 package 数量与 AUR package 数量
- mpv Stable tag 与 Development commit
- 最近一次 Actions 状态
- 当前运行中的 Actions 数量
- 最近失败的 Actions 数量

原有添加、删除、AUR 同步、构建、构建跟踪、失败构建排查、本地检查、更新检查和 pacman 安装功能保持不变。

## 验证命令

本地可运行：

```bash
python3 tests/test_select_packages.py
bash tests/test_repository.sh
bash -n scripts/*.sh client/install.sh manage.sh tests/*.sh
python3 -m py_compile scripts/select-packages.py tests/test_select_packages.py
./scripts/check-package.sh
```
