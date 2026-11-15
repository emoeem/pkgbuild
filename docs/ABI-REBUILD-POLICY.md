# ABI 重建政策

已发布的私有包不在 Arch / CachyOS 的 rebuild 范围内，依赖或 SONAME 一变就会"装得上、跑不起来"。ABI watch（`dependency-drift.yml`，每 2 小时）负责在尽可能短的窗口内自己发现并自动重建。

## 两类漂移，两个检测器

| 检测器 | 检测什么 | 关键性质 |
|---|---|---|
| 版本漂移 `check-dependency-drift.sh` | 已发布包 `.BUILDINFO` 记录的依赖 pkgver vs 当前仓库 | pkgrel-only 只报 NOTE（2026-11-10 修复的 ffmpeg-full 重建风暴：8 天 31 次 bump）；pkgver 前进才算 STALE |
| SONAME 漂移 `check-repository-sonames.sh` | 已发布包的 ELF NEEDED 在当前仓库是否仍有提供者 | 只有它能抓住"换了 SONAME 又不声明 provides"的提供者（openvino/liboapv 事故）；从文件清单建提供者集合，不依赖 pacman provides 拼写 |

硬性要求：两个检测器都必须"跑不动就报错"。崩溃、被跳过或比较数为 0 的检测器绝不允许被当成"没有漂移"——版本检测器比较数为 0 时 exit 3；workflow 对两边断言 `^SUMMARY ` 行存在。

## 输出三态

| 标签 | 含义 | 后续动作 |
|---|---|---|
| `STALE` | 可本地重建修复的断裂（source/vcs 包） | 进 stale.txt → dispatch 重建（`bump_pkgrel=true`） |
| `UPSTREAM` | repack/data 包的断裂（Phase 3） | 只报告：等上游资产，不 dispatch、不算 urgent；issue 不因此关闭 |
| `NOTE` | pkgrel-only 漂移 / repack/data 的版本漂移 | 只报告，不触发 |

## 重建节流

- **成功冷却**：24h 内成功重建过的包不再重建（`REBUILD_SUCCESS_COOLDOWN_SECONDS`，0 关闭）。skipped 包以 `deferred=` 输出，调用方不得把空 stale 读成"一切一致"。
- **SONAME 破坏豁免**：`STALE_URGENT_FILE`（soname 检测产出）里的包绕过冷却——"装上跑不起来"等一天不可接受。
- **失败冷却**：24h 内失败过的包 DEFER，避免无效重试循环。
- **查询窗口**：dispatch 前拉最近 100 个 build.yml run 且按时间窗过滤（窗口 = max(冷却, 24h) + 1h），保证"刚成功过"不被高频 run 挤出判定。

## repack/data 包的处理原则

payload 由上游提供的包，本地重建不会重链任何字节：

- 版本漂移与 SONAME 断裂都**不能**靠重新 repack 修复——没有新的上游二进制或可应用的本地兼容修复时，不把原样 repack 当作 ABI 重建；
- 断裂报告为 UPSTREAM（issue 附注 + step summary 逐行），等待上游资产；
- 上游资产变化由各自的更新工作流处理（dsh/filee/sing-box-ebpf/refresh-rule-sets）。

## 发布闸门与 ABI

- `generate-abi-manifest.sh` 在发布时产出 ABI 清单；`build.yml` 的 select 步骤下载它供 planner 做漂移判定（full 选择才应用，targeted 只报告）。
- `verify-repository-elf.sh` 在发布时校验仓库内 ELF 互恰。
- 跨包传播重建已于 2026-11-13 移除（`build-planner.py`）：构建只重建被要求自身，不自动拖累消费者——SONAME 断裂由 ABI watch 定点发现。

## 运维提示

- 手动触发同一套链路：`gh workflow run dependency-drift.yml`；
- dispatch 的 5xx 已带重试与"已接受确认"（`rebuild_is_queued`），整轮变红说明真的没发出去；
- UPSTREAM 类的等待清单在 step summary 的 "Waiting for upstream" 段与 tracking issue 附注里。
