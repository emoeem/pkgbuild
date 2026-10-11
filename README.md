# 私人 Arch Linux 软件仓库

这个项目把 `packages/*/PKGBUILD` 自动构建成 Arch Linux `x86_64`
软件包，并在私有 `repo` 分支维护标准 pacman 仓库数据库。

当前维护 11 个 package base。

## Features

- 使用真实 Arch Linux `base-devel` 容器运行 `makepkg`。
- Pull Request 和 Push 自动执行 Bash 语法、`.SRCINFO`、ShellCheck 与 namcap 检查。
- Build Plan 由 `scripts/build-planner.py` 统一生成，依赖图来自 `scripts/lib/pkgbuild_lib.py`，同时处理 `.SRCINFO` 依赖、逐包 `.rebuild-on` 声明与可用的已发布 ABI manifest。
- `scripts/overlays/<package>.sh` 变化只触发对应包；`config/**` 变化触发全量重建。
- CI 使用可复用 CachyOS-v3 builder image，预装仓库配置、namcap 和 yay，减少重复 bootstrap。
- Repository integration tests 在真实 Arch 容器中验证 `repo-add`、删除和 epoch 文件名处理。
- 成功产物通过 `repo-add` 更新 `repo` 分支中的 pacman 仓库。

构建平台（详见 `docs/build-platform.md`）：

- **Build Plan**：每次运行先输出 changed / affected / rebuild / skipped 与**逐包原因**，不再是黑箱矩阵。
- **DAG 调度**：仓库内互相依赖的包按波次排序；CI 等待本轮被选中的前置 job，并把其新构建产物 staging 到下游的本地构建仓库；本地可用 `scripts/parallel-build.sh` 波次并行。
- **分层缓存**：pacman / VCS 源 / Cargo / ccache 四层独立 key，统一由 `.github/builder/generation` 失效。
- **构建时序**：按 makepkg 阶段统计 download / prepare / build / package 耗时与每次构建的 ccache 命中率，历史归档到 `state/timing-history.jsonl`。
- **失败分析**：59 条机器可读规则归类 16 类错误，给出根因、提供者、受影响包与建议动作，并产出 `build-report/` 诊断包。
- **事务式自动修复**：分级（Level 0-3，Level 4 只出建议）、快照 + 校验 + 失败逐字节回滚，带修复预算与审计记录。
- **运行时验证**：ldd / SONAME / 符号链接 / 权限 / 缺失依赖 / smoke 命令；发布闸门会在一次性容器中安装可选的新包并验证，默认跳过大型安装闭包（查看 CI skipped 清单）。
- **一键诊断**：`./scripts/doctor.sh` 检查环境、工具链、缓存、仓库与网络并给出 READY 结论。

## Packages

| Package | Arch | 说明 |
| --- | --- | --- |
| `daed-emo` | `x86_64` | dae 的现代化 Web 仪表盘（上游主线，x86-64-v3/AVX2 构建） |
| `ffmpeg-full` | `x86_64` | 启用大量编解码器、CUDA 和 Whisper 支持的 FFmpeg |
| `linuxqq-clipsync-git` | `any` | 过渡元包（无文件），仅依赖 `linuxqq-wayland-fix-git`，安装时自动接替 |
| `linuxqq-wayland-fix-git` | `x86_64` | 修复 Linux QQ 在 Wayland 下的屏幕共享、声音共享、剪贴板和截图 |
| `mpeghdec` | `x86_64` | Fraunhofer MPEG-H 解码器 |
| `quirc` | `x86_64` | QR 解码库 |
| `scx-scheds-git` | `x86_64` | sched_ext 调度器集合 |
| `sing-box-ebpf` | `x86_64` | 带实验性 eBPF 入站的 sing-box（reF1nd 分支，`with_ebpf`，替换官方 `sing-box`） |
| `sing-box-panel` | `any` | sing-box 本地面板：服务控制、订阅/节点、分应用 eBPF 策略、配置安全管线（内嵌 zashboard） |
| `sing-box-rule-sets` | `any` | sing-box 补充规则集：anti-AD 广告表、最新 geoip/cn、mihomo 国内 IP 表、**lyc8503 增强 geosite（国内/境外分流补充）**、必须直连清单、国内广告补漏（每日自动比对上游） |
| `svt-jpeg-xs-git` | `x86_64` | JPEG XS 编解码器 |
| `vapoursynth-plugin-mlrt-ncnn-runtime` | `x86_64` | VapourSynth MLRT NCNN runtime |
| `xclip-git` | `x86_64` | X11 剪贴板命令行工具 |

版本以各目录中的 `PKGBUILD` 和 `.SRCINFO` 为准。

## Build and CI

`check.yml` 在 Arch 容器中运行 `makepkg --printsrcinfo`、ShellCheck 和
namcap，同时运行 build-graph 与 repository integration tests；`build.yml`
独立负责只构建变更包及其递归依赖，并优先使用 GHCR 中的可复用 builder image。
Artifact 保存。构建成功后发布为滚动 GitHub Release（固定 tag `repo`），
pacman 直接从 Release 资产下载仓库数据库和软件包。AUR 同步只提交源
文件，提交本身会触发一次构建，不会重复 dispatch 同一个构建。
默认采用原子发布：任一构建失败就不会发布本轮仓库更新；只有手动启用 `allow_partial_publish` 时才允许部分发布。

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

**Sync AUR package sources** 工作流每天 `03:17 UTC` 检查一次所有带
`.aur-url` 的包目录。AUR 脚本发生变化时，它会更新对应的 PKGBUILD、
`.SRCINFO`、补丁和其他源文件，提交变化到 `main`，并触发对应软件包构建。

**ABI watch** 工作流每两小时（`23 */2 * * *`）运行一次，是发现「已发布的包
和当前仓库对不上」的主力：一边比对 `.BUILDINFO` 记录的依赖版本，一边把已发布
包的 ELF `NEEDED` 与当前各仓库的库清单对照。检测器必须有 `SUMMARY` 输出，
跑不动就报错，不会把「没跑起来」当成「没有漂移」；命中后自动 dispatch 重建
（带 `bump_pkgrel=true`）并开 / 更新一个 issue。

**Maintenance** 工作流每天 `16:17 UTC` 运行：清理过期 Artifact，并用同一个
soname 扫描脚本对已发布的包再做一次深度复查，发现依赖过时就自动触发重建。

**Sync dae release** 工作流每天 `02:17 UTC` 运行 `scripts/sync-dae-release.sh`：
比对 dae 上游的发布标记，有更新时重建 `daed-emo` 并等待这次构建结束。

**Refresh sing-box rule-sets** 工作流每天 `23:40 UTC`（次日 `07:40 CST`）运行
`scripts/refresh-rule-sets.sh`：比对 `sing-box-rule-sets` 六个上游源（anti-AD /
MetaCubeX `geoip/cn` / mihomo_yamls `cncidr` / 217heidai `adblockfilters` /
lyc8503 `geosite-cn`、`geosite-geolocation-!cn`）的 sha256，**有变化才**更新 PKGBUILD
的校验和与 `pkgver`（日期）并推送，进而触发该包重建；没有变化就不产生提交。
本地可随时 `./scripts/refresh-rule-sets.sh --check` 预览。

## sing-box 运维脚本

> **单一事实来源**：本仓库 `scripts/` 下的版本是唯一权威副本。`~/code/toolbox-hub/scripts/sing-box/`
> 是带注解头（`# sing-box-*:summary=...`，供 Toolbox Hub 目录用）的**镜像**，体与仓库逐字节一致；
> `~/.local/bin/sing-box-*` 是安装副本。改脚本只改仓库，然后用 toolbox-hub 的 `install.sh` 或
> 直接 `install -m755` 重新落盘。所有脚本对非 root 调用会自动 `exec sudo` 自身（绝对路径已处理）。

`scripts/` 下有四个配合 `sing-box-ebpf` / `sing-box-rule-sets` 使用的运维脚本（都可重复执行、都走
"改配置 → `sing-box check` → 备份 → 原子替换 → 重启 → 健康检查 → 失败自动回滚" 的安全管线）：

| 脚本 | 用途 |
| --- | --- |
| `apply-audit-fixes.sh` | 审计修复：加 anti-AD 规则集、刷新 geoip/cn、清理冗余规则与 `dns-local`。可选开关：`--with-cncidr`（mihomo 国内 IP 表）、`--with-direct-list`（STUN/主机/LAN cache 直连）、`--with-extra-ads`（国内广告端点补漏）、`--with-lyc-geosite`（lyc8503 增强 geosite 并入 `geosite/cn`、`geosite/geolocation-!cn` 一起匹配）、`--with-dns-groups`（DNS 故障转移组）、`--use-package-paths`（规则集走 `/usr/share`）、`--nxdomain-ads`（把 DNS 广告拦截从 REFUSED 改成 NXDOMAIN，避免应用卡 5 秒） |
| `switch-to-ebpf.sh` | 把 TUN 入站切换为 eBPF 入站（`--shared <接口>` 可同时接管下游）。健康判据用 `sing-box api ebpf` 附件状态 + "不设代理的请求是否走代理"，失败自动回滚到 TUN |
| `switch-to-tun.sh` | 从 eBPF 切回 TUN（TUN 靠 `auto_route` 覆盖转发流量，容器/虚拟机也能被代理）。TUN 定义取自最近的 `config.*.pre-ebpf.json` 备份，当前配置里的 DNS 组/广告规则/规则集全部保留；`--from <备份>` 可指定 |
| `enable-container-proxy.sh` | 让 **rootful** podman 容器也走代理：在 podman 网桥上开启 eBPF `shared` 数据面，并用真实容器验证；`--disable` 关闭 |

> 背景：rootless podman 默认的 pasta 把容器数据包 splice 进宿主栈、不创建宿主 socket，
> 因此 eBPF 的 local cgroup 数据面看不到容器流量（容器 DNS 与国内直连正常、境外直连失败）。
>
> **实测结论（kernel 7.2.8-1-cachyos-bore-lto）**：本机内核不支持 TC 路径的 eBPF 监听器
> （`register TC eBPF TCP listener: operation not supported`），因此 `--data-plane tc` 与
> `shared`（`packet_rewrite`）**都不可用**，容器透明代理只能靠：
>
> ```bash
> podman run --rm --network=host <镜像> ...
> ```
>
> 两个脚本现在都会先跑 `sing-box tools ebpf status --mode all`，非 `passed` 时直接拦下并给出上述建议
> （`--force` 可强行尝试）。注意 `--mode local` 全 PASS **不代表** TC 可用。

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

仓库删除不会自动卸载电脑上已经安装的软件包。删除发布完成后，`sudo pacman -Sy`
刷新数据库，`pacman -Sl emoeem` 即可确认该包已从仓库消失。

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
- `emoeem-abi-manifest.txt`（每个已发布包的版本与 ELF `NEEDED` 清单，
  供依赖/SONAME 漂移检测快速比对，无需下载整个仓库）

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

## SONAME 漂移排查

私有仓库的包由自己构建，不在 Arch 官方 rebuild 范围内。第三方依赖升级换掉
SONAME（`libfoo.so.2` → `libfoo.so.1`）或 ABI 后，已发布的包会立刻变成
「装得上、跑不起来」，典型症状：

```
mpv: error while loading shared libraries: liboapv.so.2: cannot open shared object file
```

五步定位：

```bash
# 1. 缺哪个库
ldd "$(command -v mpv)" | grep 'not found'

# 2. 这个 SONAME 还有没有主人（报错 = 提供者已经换了 SONAME）
pacman -Qo /usr/lib/liboapv.so.2
pacman -Ql openapv | grep liboapv

# 3. 刚才是谁升级换掉的
grep -iE 'openapv|liboapv' /var/log/pacman.log | tail

# 4. 哪些已安装的包需要重建（AUR + 私人仓库）
LC_ALL=C checkrebuild -i emoeem

# 5. 重建：推送到 main（只重建变化的包及其依赖者），或手动触发
gh workflow run build.yml -f packages=<pkg> -f make_jobs=4 [-f bump_pkgrel=true]
```

`rebuild-detector` 自带的 hook 在本机是**失效**的，两个原因：

- 它内部用 `LANG=C stat --printf "%F"` 识别可执行文件，但 `LC_MESSAGES`
  的优先级高于 `LANG`，中文环境下 `%F` 输出「一般文件」而不是
  `regular file`，于是它扫不到任何文件，永远报告「没有需要重建的包」。
  实测：`checkrebuild -i emoeem` 无输出，写成 `LC_ALL=C checkrebuild -i emoeem`
  后立刻列出 `emoeem  ffmpeg-full`。手动调用必须带 `LC_ALL=C`。
- `checkrebuild` 默认只覆盖 AUR（foreign）包和 `file://` 仓库，私人仓库
  需要显式 `-i emoeem`。

安装仓库自带的 hook 覆盖版本，`pacman -Syu` 结束时会直接列出需要重建的包：

```bash
sudo install -Dm644 client/host/rebuild-detector.hook \
  /etc/pacman.d/hooks/rebuild-detector.hook
```

`/etc/pacman.d/hooks/` 中的同名 hook 会覆盖
`/usr/share/libalpm/hooks/rebuild-detector.hook`；卸载 `rebuild-detector`
后请同时删除该文件。该版本不使用 `NeedsTargets`，因此每次事务都会重扫全部
AUR + 私人仓库包（本机实测约 2 秒），也能发现由传递依赖引起的失效。

仓库侧的自动化：

- 推送 `packages/**` 或 `scripts/overlays/**` 时，`build.yml` 只重建变化的
  包及其依赖者。
- `dependency-drift.yml`（ABI watch）每 2 小时同时跑两件事：比对 `.BUILDINFO`
  里记录的依赖版本，以及扫描已发布包的 ELF `NEEDED`（后者才抓得住 openvino
  这类换了 SONAME 的提供者）。两个检测器都必须打印 `SUMMARY` 行；任一没跑起来
  或比较数为 0，工作流直接失败——「检测器崩了」绝不允许被当成「没有漂移」。
  命中后自动 dispatch 带 `bump_pkgrel=true` 的重建，并开 / 更新一个 issue。
  仍然只有源码树里存在的包会被 dispatch；已下架却还在发布的记为 `ORPHAN`。
- `maintenance.yml` 每天用同一个 `check-repository-sonames.sh` 再做一次深度
  复查（同时清理过期 Artifact）。来自 chaotic-aur / archlinuxcn / arch4edu /
  AUR 的库由包自己在 `packages/<包>/.rebuild-on` 里声明（`soname libshine.so.3
  shine`），声明只对该包放行——没有全局白名单，全局名单会连带掩盖别的包缺同一个
  库；声明了却不再被 NEEDED 的名字判为过期声明（`STALE-DECLARATION`，退出码 4），
  而不是继续豁免。

`dependency-drift.yml` 比对的是 `<version>-<pkgrel>`（依赖只是重打包也可能换
SONAME），对象既有当前 `.SRCINFO` 里的依赖，也有 `.rebuild-on` 里 `package <名字>`
声明的名字——依赖从 `.SRCINFO` 消失后仍然被盯住；只在容器仓库之外提供的声明名
（如 archlinuxcn 的 `shine`）留一行 `NOTE`，不算漂移。

如果依赖提供者自己没声明 `provides=('libfoo.so=N-64')`（例如 chaotic-aur 的
`openapv`、CachyOS 的 `openvino`），pacman 无法阻止不兼容升级，只能依赖上面的
自动检测及时重建。openvino `2026.4.0` → `2026.4.1` 把 `libopenvino_c.so.2640`
换成 `.2641` 就是这样打断了 `ffmpeg-full`：`openvino` 在 depends 里是普通依赖，
pacman 拦不住；本地 hook 当场报了 `emoeem  ffmpeg-full`，但真正的重建要等检测器
发现——这就是把 soname 扫描从「每天一次」提到「每两小时一次」的原因。

## 客户端配置（install.sh）

从 `main` 源码目录执行一次：

```bash
sudo ./client/install.sh
```

脚本以 root 运行，完成四步：

1. 匿名 HTTPS 预检 GitHub Release 上的 `emoeem.db` 可达（可设 `GITHUB_PROXY`
   环境变量走加速通道，通道失败自动回退直连）。
2. 尝试下载仓库签名公钥并导入本地信任；只有确认密钥不存在（404，仓库未
   启用签名）才回退 `SigLevel = Never`，网络失败会直接中止而不静默关校验。
3. 备份原 `/etc/pacman.conf` 为 `/etc/pacman.conf.emoeem-backup`。
4. 写入由标记块管理的 `[emoeem]` 仓库段（重复运行会更新该段），并执行
   `pacman -Sy`。

之后的仓库更新就是普通 pacman 操作：

```bash
sudo pacman -Syu
```

pacman 直接从 GitHub Release 下载 `emoeem.db` 与软件包，本机不需要保留
`repo` 分支克隆。如果把 `repo/x86_64` 同步到自己的私有 HTTP 服务器，只需
把 `Server` 改成服务器地址，就可以像普通 Arch 仓库一样使用。

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


## 维护工程化状态

当前仓库已完成一轮五阶段维护优化：

1. **AUR / Overlay**：AUR 同步改为事务式 staging，先验证上游、overlay、PKGBUILD 和 `.SRCINFO`，再替换工作区，避免失败同步破坏现有包。
2. **PKGBUILD 审计**：`scripts/audit-packages.sh` 对 11 个有效 package base 做元数据、架构、AUR 元数据以及 provider / dependency 一致性审计。
3. **构建缓存**：CI 复用 pacman、VCS source 和 Cargo 缓存；builder / build 脚本变化会使缓存 key 失效（按 flavor 前缀部分恢复旧缓存），下载的仓库资产存放在缓存目录之外，不进入缓存快照。
4. **Repository 完整性**：发布前运行 `scripts/verify-repository.sh`，校验数据库引用、软件包资产、SHA256 和仓库配置。
5. **管理与文档**：TUI 增加「审计全部软件包」，构建流水线文档同步记录实际维护流程。

在此之上完成的构建平台升级见 `docs/build-platform.md`，架构现状与文档/代码差异见
`docs/architecture-audit.md`；TUI 增加「构建计划与 DAG」「并行构建」「构建时序统计」
「修复中心」「运行环境自检（doctor）」。

推荐的本地维护检查（与 CI integration job 执行同一套）：

```bash
./tests/run-all.sh          # 语法 + lint + Python + 行为测试
# 静态检查统一入口（与 check.yml 的静态关卡同一份清单）；先接线一次：
# ./scripts/install-git-hooks.sh 让 pre-commit 钩子自动跑它
./scripts/run-static-checks.sh
bash tests/test-static-checks.sh
./scripts/doctor.sh         # 环境自检
./scripts/build-planner.py --selection changed --before HEAD~1 --after HEAD
./scripts/audit-packages.sh
```

## 构建平台优化（P1–P5）

- **P1 干净构建**：CachyOS-v3 `devtools` clean chroot；`workflow_dispatch` 可选 `legacy` / `chroot`（默认 legacy，push 始终 legacy）；基线按 builder generation / 架构 / 配置指纹缓存，每包工作副本用后删除；同批次 DAG 依赖通过只读临时仓库传递。切换前必须完成 3 次连续 chroot shadow-run 验收。
- **P2 上游追踪**：`packages/*/.nvchecker.toml` + 每日 workflow；新版本开/更新 issue，不自动修改 PKGBUILD。
- **P3 失败闭环**：失败分类与根因进入去重 issue，构建恢复后关闭。
- **P4 升级验证**：隔离 chroot 验证 `linuxqq-clipsync-git` 常规升级和官方 `sing-box` → `sing-box-ebpf` 替换事务；缺少旧版时明确标记不可验证。
- **P5 质量留痕**：默认执行 `check()`；仅 `.skip-check` 可显式豁免；namcap issue 按包 + 规范化警告内容去重，`.namcap-ignore` 支持逐条长期豁免。

详细设计、shadow-run 操作、回退条件、缓存监控和本地 rootless Podman 限制见 [`docs/build-pipeline.md`](docs/build-pipeline.md)。当前任务指针见 [`CURRENT-STATUS.md`](CURRENT-STATUS.md)；历史评审材料归档于 [`docs/archive/`](docs/archive/)。
