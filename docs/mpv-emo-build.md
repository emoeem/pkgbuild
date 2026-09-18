# mpv-Emo 构建与更新体系

## 目标

mpv-Emo 不再把 AUR `mpv-full` 当作版本控制中心。仓库只把 AUR 用于其余
第三方软件包；mpv 本身由 `tracks/mpv/` 统一管理 upstream pin。

## 三条轨道

| 轨道 | 包 | 基线 | 发布原则 |
| --- | --- | --- | --- |
| Stable | `mpv-emo` | 官方 release tag | 默认使用；可长期运行 |
| Development | `mpv-emo-git` | upstream master commit | 独立测试；不阻塞 Stable |
| Optional Patch | `mpv-emo-omniphony` | Omniphony release + 指定 mpv | 独立安装；补丁失败即停止 |

Stable 当前基线为 mpv `v0.41.0`。Development 使用精确 commit，而不是
在构建时漂移到未知的 master HEAD。mpv 官方同时维护稳定 release 与
master development build，因此仓库也保持这种分离。

## 更新流水线

```text
upstream mpv release/master
        │
        ├── Stable ────────┐
        │                  │
        ├── Development ───┤──> pin → .SRCINFO → CI build → publish
        │                  │
        └── Optional Patch ┘
             Omniphony
                 │
                 └── patch dry-run / prepare gate
```

更新器是 `scripts/sync-mpv-tracks.sh`。它负责解析上游版本、下载源码并计算
SHA256、固定 Development commit、更新 `.env` pin 和重新生成 `.SRCINFO`。
`aria2c` 可用时自动使用多连接下载；否则回退到 curl。

## Optional Patch 原则

Omniphony 是独立的 mpv-side integration：它维护针对稳定基线和 master 的
独立 patch series，mpv 运行时通过 `dlopen` 加载 `liborender`。因此它不应该
通过修改 `mpv-emo` 的 PKGBUILD 来实现。

`mpv-emo-omniphony` 单独提供这个变体，并依赖 `orender`。它和 Stable、
Development 互斥，避免系统同时存在多个提供 `mpv` 的核心。
