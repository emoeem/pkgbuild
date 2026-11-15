# 排障手册

按症状索引，全部对应本仓库真实发生过的事故。环境自检先用 `./scripts/doctor.sh`。

## 发布 / 版本类

### 仓库版本倒退 / 客户端收不到更新
症状：装了高版本的机器永远升不上去。
排查：`git log --grep='write back'` 看 write-back 是否发生；对比源码树 `packages/<pkg>/PKGBUILD` 的 pkgrel 与发布产物。
机制：`verify-publish-inputs.sh` 现在对降级硬失败、对撞车 bump 硬失败；write-back 只前进。若再次发生说明闸门链被绕过——检查构建是否用了 `LOCAL_REPO_DIR`（没有它 E2 floor 不跑）。
参见 [PKGREL-POLICY.md](PKGREL-POLICY.md)。

### `Publication would not upgrade / would downgrade` 发布失败
不是 bug：源码树 pkgrel 落后于已发布版本（多半是 write-back 没跑或 AUR sync 拉回）。先让源码树追上（重跑 sync 或手动对齐），再重新构建发布。

### `SKIP no-op publish` 
同版本产物已在仓库里：发布闸门把它挪出本批。属设计行为；频繁出现说明某包在无意义重建——查它的 `.build-strategy` 是否正确。

## 构建类

### `SRCINFO mismatch`
`.SRCINFO` 与 PKGBUILD 不同源。pkgrel 类改动必须同时改两个文件（`pkgrel_policy_apply` 会同步）；手改了 PKGBUILD 就跑 `makepkg --printsrcinfo > .SRCINFO`（构建容器内）或让 check-package.sh 报错指出。

### `Cannot auto-bump unsupported pkgrel: <x>`
pkgrel 形状非法（三段/空/字母）。修 PKGBUILD 的 pkgrel 行，不要改脚本——形状政策是刻意的。

### ffmpeg-full 构建红在 `MISSING flag/hwaccel/encoder/...`
功能矩阵断言失败：configure 静默降级了某个 `--enable-*`。看 `dist/ffmpeg-features.json` 的 errors 与构建日志里 configure 的探测输出，补齐缺失依赖；若是矩阵 token 与产物实际命名不符（首次接入新 FFmpeg 版本时可能发生），对照产物 `-encoders` 等真实输出修 `feature-matrix.txt`，不要放宽脚本。

### ffmpeg-full 构建红在 `ELF RPATH/RUNPATH` 或 `leaks build-tree substring`
产物带构建树路径。查新加的 patch/构建段是否引入了 staging 安装路径；`--banned` 清单在 `build-in-arch.sh` 的调用参数里。

### 镜像 404 / `failed to commit transaction`
CDN 边不同步（mirror 404 而源站 200）。构建脚本已带 `retry_transient`；连续失败换时段重跑，不要改 pacman.conf。

### Docker Hub `toomanyrequests`
匿名拉基础镜像限流。builder 镜像用 GHCR 的本仓库镜像（workflow 已配置）；本地构建同样避免直接 `docker pull` CachyOS 源镜像。

## 调度 / ABI 类

### ABI watch 红：`produced no SUMMARY line` / `Refusing to report "no drift"`
检测器没跑完（数据库未同步、容器网络失败）。这是刻意的 fail loudly——修环境后重跑 `gh workflow run dependency-drift.yml`，不要把失败解释成"无漂移"。

### 某包被反复 dispatch
按顺序查：① 它的 `.build-strategy` 是否正确（repack/data 不该被版本漂移 dispatch）；② 是否 soname urgent（冷却豁免是设计行为，等上游资产期间会持续报告 UPSTREAM）；③ `stale.txt` 内容与 `check-dependency-drift.sh` 的 NOTE 行。

### dispatch 502 后没重建
脚本自带重试 + "已接受确认"（`rebuild_is_queued` 轮询）。三轮全失败才红——此时看 workflow 日志确认没有 queued job，手动 `gh workflow run build.yml -f packages=<pkg>`。

### UPSTREAM 等待的包什么时候动
上游发新资产时各自的更新工作流（dsh/filee/rule-sets）自动重新 pin 并 dispatch。等待清单在 ABI watch step summary 与 tracking issue 附注。不要手动 repack 相同资产来"修"它——那正是假升级。

## 更新器类

### 更新器红在 checksum/依赖对账
dsh 的 `build()` 对账失败说明上游资产的 depend 集合变了：按错误信息改本地 `depends=()`（PKGBUILD + `makepkg --printsrcinfo` 同步 `.SRCINFO`），这是唯一需要人工的语义判断点。
rule-sets/仓库管理源的 checksum stale 由 `auto-repair` hand-off 给所属更新工作流，不在本地改哈希。

### `[upstream]` issue 长期挂着
nvchecker 发现上游新版本但发布未跟进。按 [DEPENDENCY-MANAGEMENT.md](DEPENDENCY-MANAGEMENT.md) 的 vendored 依赖升级流程处理；closed 即代表已追平。

## 本机环境类

### `doctor.sh` 报 legacy 单元失败
`emoeem-repo-update` 系列是已废弃的旧客户端残留：`sudo scripts/remove-legacy-repo-update.sh --apply`。

### 本地构建要求
CachyOS 主机 + cachyos-v3 仓库启用（`build-in-arch.sh` 会检查）；Zen 3 目标由 `validate-build-policy.sh` 强制。其他主机用 CachyOS-v3 builder 镜像。

## 快速自检

```bash
./scripts/doctor.sh            # 环境/工具链/缓存/仓库/网络
./tests/run-all.sh --fast      # 137 个本地检查（2 个设计内 skip）
./scripts/run-static-checks.sh # 14 组静态门禁
```
