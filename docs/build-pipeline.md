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
- `makedepends` / `checkdepends` 依赖传播
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
./tests/test-build-regressions.sh
bash tests/test_repository.sh
bash tests/test-cachyos-environment.sh base
bash -n scripts/*.sh client/install.sh manage.sh tests/*.sh
python3 -m py_compile scripts/select-packages.py tests/test_select_packages.py
./scripts/check-package.sh
```


## 5. P1：CachyOS-native 构建增强

### 容器 post-transaction hook

CachyOS/pacman 在 Podman 容器中执行 `ldconfig` 和 systemd hook 时会尝试建立网络隔离，而容器默认能力不足会产生 `Operation not permitted`。Builder image 在 `[options]` 中启用 `DisableSandboxNetwork`，只关闭这类 hook 的网络隔离要求，不使用 `--privileged`，因此不会放宽整个容器的权限边界。

`namcap` 当前使用的 pyalpm 配置解析器不认识该 CachyOS pacman 选项，因此 `scripts/run-namcap.sh` 会在运行 namcap 时临时隐藏该配置项，并通过 trap 恢复原配置。

### 依赖图

`scripts/select-packages.py` 现在同时把 `depends`、`makedepends` 和 `checkdepends` 纳入 provider → consumer 图。修改一个库、编译工具或测试依赖时，相关下游 package 都会被选择重建。

### 构建缓存

`build-in-arch.sh` 支持 `CACHE_DIR`，缓存两类不会改变构建正确性的内容：

- `/cache/pacman`：pacman 软件包缓存。
- `/cache/sources/<package>`：按目标 package 隔离的 makepkg `SRCDEST`，尤其用于 VCS source。
- VCS source 使用独立的 URL 身份校验；发现同名但不同远程仓库的缓存会在构建前自动清除，避免 `xclip` 一类 basename 冲突。

GitHub Actions 使用 `actions/cache` 恢复 `.cache/pkgbuild`，缓存 key 按 CachyOS-v3、standard/CUDA builder 和 builder 定义区分。缓存失效只会增加下载时间，不会跳过依赖解析或 checksum 验证。

### CUDA Builder

`.github/builder/Dockerfile` 支持 `CUDA_BUILDER=1`，发布两个 GHCR builder：

- `pkgbuild-builder:latest`：标准 CachyOS-v3 builder。
- `pkgbuild-builder:cuda`：额外安装官方仓库 CUDA toolkit，用于 CUDA/ffmpeg-full 构建。

Builder 同时启用官方 Chaotic-AUR 二进制仓库作为 AUR 依赖的预编译补充来源。这样 `ffmpeg-full` 等大型包不需要重复编译所有 AUR 依赖；本次验证中原先会进入 AUR 构建队列的 24 个依赖收敛到仅 4 个仍需从 AUR 构建。Chaotic-AUR 仅作为依赖来源，不替代 CachyOS-v3 基线，也不替代目标 package 自身构建。

CI 根据 package 名称选择 CUDA builder；`ffmpeg-full`、`mpv-emo`、`mpv-emo-git` 和名称包含 `cuda` 的 package 使用 CUDA builder。CUDA builder 同时安装 `gcc15`，因为当前 CUDA 13.4 的 `nvcc` 会选择 GCC 15 作为 host compiler；本地验证要求 `nvcc`、`g++-15` 和 `cuda` package 可用。

### 环境一致性测试

`tests/test-cachyos-environment.sh` 检查 CachyOS、`cachyos-v3`、x86_64、makepkg、aria2、namcap，以及 builder 模式下的 yay 和 sandbox 配置。CI builder 发布流程会在推送镜像前后验证标准/CUDA 环境；本地也可以直接在 builder image 中运行。

### 下载加速

Builder 通过 `/etc/makepkg.conf.d/pkgbuild-aria2.conf` 为 HTTP/HTTPS/FTP source 使用 aria2 多连接下载，同时保留 VCS source 的 Git 路径。pacman 本身不使用 XferCommand，避免 pacman 的 sandbox 与外部 downloader 进程产生额外的容器权限问题。
