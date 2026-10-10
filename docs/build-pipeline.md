# 构建流水线与仓库维护

当前仓库采用四层流水线：Build Graph Correctness、CI Builder Optimization、Repository Integration Tests、Repository Management UI。

## 1. Build Graph Correctness

`scripts/build-planner.py` 是 CI 的唯一构建决策入口；它通过 `scripts/lib/pkgbuild_lib.py` 从 `.SRCINFO` 建立 provider → consumer 图，并合并逐包 `.rebuild-on` 声明与可用的已发布 ABI manifest。`scripts/build-dag.py` 只负责对最终 rebuild 集合进行依赖波次排序。

- 直接依赖会触发下游包重建。
- `provides` 虚拟包会参与依赖传播，例如 `ffmpeg-full` 提供 `ffmpeg` 时，依赖 `ffmpeg` 的包会被选中。
- `depends` 中的版本约束会先归一化为依赖名。
- Split package 的多个 `pkgname` 也被视为同一个 package base 的 provider。
- `scripts/overlays/<package>.sh` 变化只触发对应 package。
- `config/**`（构建环境与本地性能档）变化触发完整重建；`scripts/build-in-arch.sh`
  等构建脚本变化**不**触发 package 重建（它们不改变产物，只改变执行方式）。
  这一点由 `tests/test_select_packages.py` 明确断言，文档与代码以此为准。
- 共享库关系 `provides = libfoo.so=2-64` 与 `depends = libfoo.so=2-64` 按完整
  关系名匹配，并额外登记链接器拼写 `libfoo.so.2`，因此 SONAME 依赖也能连上提供者。
- `--root` 参数允许在隔离的 Git fixture 中测试选择逻辑。

构建决策不再散落在选择脚本里：`scripts/build-planner.py` 是唯一决策点，
输出 changed / affected / rebuild / skipped 与逐包 reason；`scripts/build-dag.py`
在此基础上给出波次与资源槽位。CI 的 `select` job 把两者的输出写进 step summary。

因此普通文档修改不会触发 package build，而影响依赖 ABI/API 的包会向下游传播。

## 2. CI Builder Optimization

`.github/builder/Dockerfile` 直接基于官方 CachyOS x86-64-v3 构建镜像，预装：

- CachyOS x86-64-v3 / 官方仓库
- git、gnupg、curl、jq、namcap、sudo
- builder 用户
- yay-bin

`builder.yml` 在构建器定义变化时发布 `pkgbuild-builder:latest` 到 GHCR。普通 package build 会优先拉取该镜像；镜像暂不可用时自动在 runner 上构建 fallback，因此不会因为首次发布构建器而阻塞主构建流水线。

使用预构建镜像后，package job 不再重复执行 CachyOS repository bootstrap 和 yay bootstrap。`build-in-arch.sh` 的本地路径要求宿主机本身是 CachyOS 且启用 `cachyos-v3`，不会再在 Arch 容器里临时拼装 CachyOS 仓库。

ABI watch（`dependency-drift.yml`）和 maintenance（`maintenance.yml`）里的检测容器也拉同一份镜像（`BUILDER_IMAGE`），不再从 Docker Hub 匿名拉 `docker.io/cachyos/cachyos-v3`：Docker Hub 的未认证拉取按 runner 出口 IP 限速，共享 runner 会直接拿到 `toomanyrequests`（maintenance run 37989749507 就是这么失败的，`docker run` exit 125，而检测器本身没有任何问题）。GHCR 的匿名拉取不需要凭据也不吃这个限速；builder 镜像本来就基于同一个 CachyOS-v3 镜像并已配好 chaotic-aur，检测器的 provider 集合只多不少。`setup-container-repos.sh` 因此只在容器里还没有 `[chaotic-aur]` 段时才追加配置：重复声明会让 pacman 每次都报 `could not register 'chaotic-aur' database (database already registered)`，而且生效的始终是第一段。

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

共享图实现 `scripts/lib/pkgbuild_lib.py` 将 `depends`、`makedepends`、`checkdepends` 与 `.rebuild-on` 声明统一纳入 provider → consumer 图；CI 的 planner 与 DAG 共用这一语义。修改一个库、编译工具或测试依赖时，相关下游 package 都会被选择重建。

### 构建缓存

`build-in-arch.sh` 支持 `CACHE_DIR`，缓存两类不会改变构建正确性的内容：

- `/cache/pacman`：pacman 软件包缓存。
- `/cache/sources/<package>`：按目标 package 隔离的 makepkg `SRCDEST`，尤其用于 VCS source。
- VCS source 使用独立的 URL 身份校验；发现同名但不同远程仓库的缓存会在构建前自动清除，避免 `xclip` 一类 basename 冲突。

GitHub Actions 使用 `actions/cache` 恢复 `.cache/pkgbuild`，缓存 key 按 CachyOS-v3、standard/CUDA builder 和 builder 定义区分；key 失效时 `restore-keys` 仍按 flavor 前缀恢复最近的缓存。缓存失效只会增加下载时间，不会跳过依赖解析或 checksum 验证。下载的发布仓库资产存放在缓存目录之外的 `localrepo/`，因此不会被打进缓存快照。

### CUDA Builder

`.github/builder/Dockerfile` 支持 `CUDA_BUILDER=1`，发布两个 GHCR builder：

- `pkgbuild-builder:latest`：标准 CachyOS-v3 builder。
- `pkgbuild-builder:cuda`：额外安装官方仓库 CUDA toolkit，用于 CUDA/ffmpeg-full 构建。

Builder 同时启用官方 Chaotic-AUR 二进制仓库作为 AUR 依赖的预编译补充来源。这样 `ffmpeg-full` 等大型包不需要重复编译所有 AUR 依赖；本次验证中原先会进入 AUR 构建队列的 24 个依赖收敛到仅 4 个仍需从 AUR 构建。Chaotic-AUR 仅作为依赖来源，不替代 CachyOS-v3 基线，也不替代目标 package 自身构建。

CI 根据 package 名称选择 CUDA builder；`ffmpeg-full` 和名称包含 `cuda` 的 package 使用 CUDA builder。CUDA builder 同时安装 `gcc15`，因为当前 CUDA 13.4 的 `nvcc` 会选择 GCC 15 作为 host compiler；本地验证要求 `nvcc`、`g++-15` 和 `cuda` package 可用。

### 环境一致性测试

`tests/test-cachyos-environment.sh` 检查 CachyOS、`cachyos-v3`、x86_64、makepkg、aria2、namcap，以及 builder 模式下的 yay 和 sandbox 配置。CI builder 发布流程会在推送镜像前后验证标准/CUDA 环境；本地也可以直接在 builder image 中运行。

### 下载加速

Builder 通过 `/etc/makepkg.conf.d/pkgbuild-aria2.conf` 为 HTTP/HTTPS/FTP source 使用 aria2 多连接下载，同时保留 VCS source 的 Git 路径。pacman 本身不使用 XferCommand，避免 pacman 的 sandbox 与外部 downloader 进程产生额外的容器权限问题。


## Phase 1–5 完成状态

### Phase 1：AUR / Overlay 自动维护

`sync-aur-packages.sh` 现在采用事务式同步：先在临时目录克隆 AUR、写入提交指纹、应用 overlay、重新生成 `.SRCINFO` 并通过 Bash 语法检查；全部通过后才替换工作区中的 package 目录。这样上游更新或 overlay 失败不会破坏现有可用 PKGBUILD。

`.aur-url` 与 `.aur-commit` 继续记录上游身份和同步点。

### Phase 2：全量 PKGBUILD 审计

新增 `scripts/audit-packages.sh`，对当前 13 个有效 PKGBUILD 做全量元数据、`.SRCINFO`、架构、AUR 元数据和内部 provider / dependency 检查。对于 Stable / Git、CUDA 等有意提供同一虚拟包的替代包，只有存在明确冲突关系时才允许共享 provider。

新增 `tests/test-package-audit.sh` 回归测试，并把全量审计加入 `check.yml` 的 integration job。管理 TUI 也新增「审计全部软件包」入口。

### Phase 3：构建缓存与 CI 性能

Actions cache 现在同时覆盖 pacman package cache、按 package 隔离的 VCS source cache，以及共享 Cargo registry / Git cache。构建脚本通过 `CARGO_HOME=/cache/cargo` 复用 Rust 依赖；builder 定义和构建脚本变化会自动使缓存失效，避免旧环境污染新构建。

### Phase 4：Repository / Release 完整性

新增 `scripts/verify-repository.sh`。发布前验证数据库、软件包资产、`.PKGINFO`、SHA256 manifest 和 repository config；发现数据库引用不存在的资产会阻止发布。`tests/test_repository.sh` 同时覆盖 checksum、数据库生成、epoch 文件名和完整性验证。

Release 发布脚本继续采用「先包、后数据库」的上传顺序，并只管理本项目明确生成的资产；数据库和软件包不再因为单个失败构建而被错误地清空。

### Phase 5：文档与管理工具收尾

`manage.sh` 增加全量 package audit 入口，现有状态总览、构建跟踪、失败排查、同步、构建和本地仓库操作保持不变。文档以当前实际脚本和 CI 行为为准，后续新增维护逻辑应同时更新本文件和 README。

## 6. Clean chroot, upstream tracking and build issue lifecycle (P1–P5)

### P1 — disposable CachyOS-v3 clean chroot

`build-in-arch.sh` can delegate package compilation to `scripts/build-in-clean-chroot.sh` when `CLEAN_CHROOT_BUILD=1`. The workflow's `workflow_dispatch` input selects this path only for manual shadow runs; the default and every push-triggered build remain `legacy` until three consecutive successful chroot runs are accepted. The builder image installs `devtools`; `mkarchroot` creates a reusable base under `/cache/chroot/baseline-*`, keyed by builder generation, architecture and a fingerprint of the image's pacman/makepkg configuration. The image preserves its original repository config as `/etc/pacman.conf.pkgbuild-base` before per-job repository mutation; the chroot config is derived from that image-owned file, never the host's pacman config. CachyOS sections are ordered `cachyos-v3`, `cachyos-extra-v3`, `cachyos-core-v3`, `cachyos`. No host pacman configuration is read.

Each package copies the baseline with `cp --reflink=auto -a` into a unique temporary work root and removes that root on exit. Package state is never cached. The build binds pacman downloads, per-package VCS sources, Cargo and ccache; the local repository is mounted read-only at `/run/pkgbuild-localrepo` and placed before upstream repositories so a matching Chaotic-AUR package cannot shadow a fresh DAG prerequisite. Newly built DAG prerequisites are staged beside the downloaded repository packages, and `repo-add` produces a temporary repository database before the builder runs. The working chroot can therefore install same-run prerequisite packages without modifying the base snapshot. Timings, build logs, package checksums, runtime verification and failure analysis remain in the existing pipeline.

The chroot baseline cache is separate from package work roots. Cache keys include builder generation, x86_64-v3, standard/CUDA flavor and hashes of the builder/makepkg/chroot scripts. Only `baseline-*` paths are restored by Actions cache; interrupted work roots are not cached. Arch's `makechrootpkg` contract and `mkarchroot -C` support were checked against the current devtools manual and Arch clean-chroot documentation.

For local rootless Podman validation, the unprivileged default runtime blocks nested mount namespaces. The local invocation `podman run --cap-add SYS_ADMIN --security-opt seccomp=unconfined ...` allowed a basic `unshare`, but `mkarchroot` failed when `pacstrap` tried to bind-mount `/dev` inside the nested mount namespace (`permission denied`). Only the manual `chroot` build path and the clean-chroot upgrade-test container use these two flags on the rootful GitHub Docker runner; the `legacy` build does not receive the extra capability. Neither path uses `--privileged` or mounts host-sensitive paths. When the workspace filesystem is Btrfs, the local cache stores a compressed baseline archive and expands it under the container overlay `/tmp`, avoiding devtools' automatic Btrfs-subvolume path and retaining ordinary copy/reflink work roots.

### P2 — upstream release watch

The five package-local `.nvchecker.toml` files cover quirc, mpeghdec, ffmpeg-full, svt-jpeg-xs-git and vapoursynth-plugin-mlrt-ncnn-runtime. `.github/workflows/upstream-check.yml` runs daily and on demand inside the CachyOS builder image. It seeds `oldver` from each literal PKGBUILD `pkgver`, normalizing a git package's `.g<short-sha>` suffix to the comparable short commit. A detected upstream change opens or comments on a deduplicated `[upstream]` issue; the workflow never edits a PKGBUILD or bumps checksums automatically.

### P3 — build failure issues

A failed package build uses `scripts/analyze-build-failure.py`'s category and root-cause fields to open/update an issue titled `[build-failure] <package>: <category>: <root cause>`. Identical package/root-cause failures share one issue. A successful package build closes its open build-failure issues. The workflow requires `issues: write`; failure artifacts and the original analyzer output remain available.

### P4 — upgrade path dry run

`scripts/test-upgrade-path.sh` tests `linuxqq-clipsync-git` and the official `sing-box` → `sing-box-ebpf` replacement transaction in a disposable clean chroot. For `linuxqq-clipsync-git`, it requires an older private package to be present in the downloaded repository. It stages the previous repository package set plus the newly built target artifact in a temporary local repository, installs the previous target package, then runs `pacman -Syu` against the fresh target artifact, exercising replacement/conflict/provider semantics without touching the host or publishing a repository. If no prior `linuxqq-clipsync-git` package exists, the test emits `UPGRADE_PATH=UNVERIFIABLE` and does not claim success. For `sing-box-ebpf`, it installs the explicitly qualified official `cachyos-v3/sing-box` package first, then verifies pacman removes it when installing `sing-box-ebpf`.

### P5 — check() and namcap audit trail

`makechrootpkg` runs `check()` by default. A package can opt out only by adding a reviewed `packages/<pkg>/.skip-check` file; the script then passes `--nocheck` and logs the explicit exception. Namcap output is retained as `dist/namcap.txt`. Non-empty normalized warning sets create/update a deduplicated `[namcap] <package>: <warning-hash>` issue, so distinct warning sets for one package do not collapse into one issue. A reviewed `packages/<pkg>/.namcap-ignore` can exempt exact normalized warning lines long-term. Warnings are not silently suppressed.

### Verification and local constraints

Run `./tests/run-all.sh --fast` and `./scripts/run-static-checks.sh`; ShellCheck and actionlint are included when installed. A small-package clean-chroot end-to-end test is separate from these fast/static checks because it requires nested mount namespaces and repository network access. The CI build uses the same CachyOS-v3 builder image and rootful Docker semantics; no Arch official image is used for package build or build verification.


### Historical local end-to-end validation

The 2026-10-10 rootless-container probe and its exact failure evidence are archived at [`docs/archive/build-platform-validation-2026-10-10.md`](archive/build-platform-validation-2026-10-10.md). Do not repeat `makechrootpkg` locally under rootless Podman; the supported acceptance path is a manually dispatched rootful GitHub Actions shadow run.


## 7. Shadow run acceptance: legacy vs clean chroot

### Build mode control

`build.yml` exposes `workflow_dispatch` input `build_mode=legacy|chroot`, defaulting to `legacy`. Push-triggered builds always force `legacy`, regardless of input context. `legacy` calls the existing `build-in-arch.sh` build path with `CLEAN_CHROOT_BUILD=0`; `chroot` delegates to `scripts/build-in-clean-chroot.sh`. A chroot dispatch is a true shadow run: it uploads the package artifact for comparison but skips repository publication, automatic repair/push, namcap issue mutation and success-based closure of existing build-failure issues. The workflow default is intentionally **not** switched by this change.

### Manual acceptance procedure (do not auto-dispatch)

These commands become valid only after the local workflow/action/script changes have been published to the GitHub default branch. This task deliberately does not push or dispatch anything.

1. Pick a small package with a currently published artifact, for example `quirc`, and note the source ref. Keep `bump_pkgrel=false` and `allow_partial_publish=false`.
2. Run the legacy control:
   ```bash
   gh workflow run build.yml --ref main -f packages=quirc -f build_mode=legacy -f make_jobs=2 -f bump_pkgrel=false -f allow_partial_publish=false
   gh run list --workflow build.yml --limit 5
   gh run watch <LEGACY_RUN_ID> --exit-status
   gh run download <LEGACY_RUN_ID> --name built-quirc-<LEGACY_RUN_ID> --dir shadow/legacy
   tar -xf shadow/legacy/quirc.tar -C shadow/legacy
   ```
3. Run the chroot candidate on the same source ref and package:
   ```bash
   gh workflow run build.yml --ref main -f packages=quirc -f build_mode=chroot -f make_jobs=2 -f bump_pkgrel=false -f allow_partial_publish=false
   gh run list --workflow build.yml --limit 5
   gh run watch <CHROOT_RUN_ID> --exit-status
   gh run download <CHROOT_RUN_ID> --name built-quirc-<CHROOT_RUN_ID> --dir shadow/chroot
   tar -xf shadow/chroot/quirc.tar -C shadow/chroot
   ```
4. Locate the `.pkg.tar.zst` artifact under each extracted directory, then compare:
   ```bash
   ./scripts/compare-build-artifacts.sh      shadow/legacy/path/to/quirc-LEGACY.pkg.tar.zst      shadow/chroot/path/to/quirc-CHROOT.pkg.tar.zst      shadow/quirc-diff.json
   ```
   Preserve `shadow/quirc-diff.json` and both run URLs in the acceptance notes. These commands are instructions only; this task does not dispatch builds or publish artifacts.

### Acceptance criteria and promotion gate

- Both builds complete successfully from the same source revision and package selection.
- `compare-build-artifacts.sh` emits JSON containing `.BUILDINFO` dependency-version comparisons, runtime `ldd` results, extracted file-list differences and normalized `.PKGINFO` differences.
- **Pass criterion:** every dependency version shared by both builds is not older in the chroot build, and no legacy dependency is missing from chroot `.BUILDINFO`. File-list / metadata / runtime differences must be reviewed; differences are not silently treated as equivalent.
- Repeat the same package/method for **three consecutive successful chroot runs (N=3)**, recording results, before changing the workflow default. Only then change the default input to `chroot`; keep push-triggered builds on legacy until that explicit edit is reviewed.
- **Rollback:** set `build_mode=legacy` on the next manual run. For automatic builds, restore the input default to `legacy` in `build.yml`; push already remains legacy by design. Do not delete baseline caches as a rollback action.

### Chroot permissions evidence

The local rootless Podman probe could create a basic mount namespace, but `mkarchroot` failed inside `pacstrap` while mounting `/dev` (`permission denied`). The GitHub-hosted rootful Docker runner therefore currently uses only `--cap-add SYS_ADMIN --security-opt seccomp=unconfined` for the chroot build and upgrade-test containers; `--privileged` and host-sensitive mounts are not used. This is the smallest tested capability set in the current implementation, not proof that every individual syscall needs it. A narrowed custom seccomp profile has **not** been validated; tracking it as follow-up is safer than guessing an allowlist that breaks `devtools` mount behavior.

### Baseline refresh and cache monitoring

The weekly Maintenance schedule deletes only cache entries with the existing `chroot-v1-` generation-key prefix; the next build recreates a baseline using the normal builder-generation/config fingerprint. The daily cache report uses GitHub's Actions cache usage API and lists the largest keys; it opens/updates an issue at 80% of the 10 GiB monitoring budget. GitHub cache usage is approximate and the API can lag several minutes.

### Composite builder setup and security scan

`.github/actions/setup-builder/action.yml` centralizes layered build-cache restoration and selection/pull of the standard or CUDA CachyOS-v3 builder. `check.yml`, `dependency-drift.yml`, `maintenance.yml` and the build workflow reuse the same setup entry point. Third-party actions are pinned to full commit SHAs with version comments; Dependabot tracks updates. `zizmor` results and any environment/network limitation are recorded in `docs/archive/build-platform-validation-2026-10-10.md` and this section; do not treat a missing scanner binary as a clean scan.
