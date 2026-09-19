# mpv-Emo 构建与更新体系

## 目标

`mpv-Emo` 是基于 `mpv-full` 思路的自维护 Linux 全功能 mpv：upstream mpv
作为核心基线，再叠加经过验证的 Emo core patch set。它不是单纯的 UI/
Lua 配置包，也不是把 Yaozhi Windows 核心直接搬到 Linux。

## 当前包

| 包 | 作用 |
| --- | --- |
| `mpv-emo` | Stable：完整 Linux 构建 + 已验证核心 Patch，当前包含 Omniphony mpv-side integration |
| `mpv-emo-git` | Development：upstream master + 对应 Patch series；Patch 冲突时禁止发布 |

`mpv-emo-omniphony` 已删除。Omniphony 不再作为“另一个 mpv”存在，而是
作为 `mpv-Emo` 的核心 Patch 层；`orender` 只作为运行时可选依赖。

## Patch 层

当前 Stable 使用 Omniphony v0.4.2 的完整 24-commit mpv-side series。该
series 包含 ad_orender、动态输出声道协商、内置 spatial overlay、DTS/AC-3
路由、对象元数据和 ABI 兼容等改动。Windows 专用改动虽然随上游 series
保留，但 Linux 构建不会启用 ASIO/WASAPI 路径。

Omniphony 的 mpv-side 项目明确采用“Patch mpv + runtime `liborender`”架构，
mpv 本身不需要在编译期链接 `liborender`，运行时再通过 ABI 加载它。

## 构建链

```text
upstream mpv release/master
        ↓
mpv-full Linux feature policy
        ↓
Emo core patch set
        ↓
mpv-emo / mpv-emo-git
        ↓
Arch CI tests
        ↓
private pacman repo
```

Patch application 是硬门槛：任意一个 Patch 无法应用，构建直接失败，不发布。

## 更新原则

1. Stable 只跟随 mpv 正式 release。
2. Development 固定精确 upstream commit。
3. 每次 mpv 更新都必须重新验证 Patch series。
4. Patch 已进入 upstream 后，从 Emo Patch set 删除，避免重复维护。
5. Windows-only 能力不作为 Linux 功能目标；只有核心逻辑确实服务 Linux 时才保留。
6. `orender` 不进入 mpv 编译期依赖；需要空间音频时再安装对应运行时。

## 当前验证

Stable `v0.41.0` 的 24 个 Omniphony Patch 已在干净 mpv `v0.41.0` 源码树中
按顺序全部应用成功。Development 的 master Patch series 必须以其对应的
upstream 基线重新生成；当前若发生 drift，CI 应保持失败而不是强行发布。

## mpv-full 基线与 PipeWire JACK 策略

`mpv-Emo` 的功能策略以当前 AUR `mpv-full` 为基线：尽量开启 Linux 可用的
mpv 功能，再叠加 Emo Patch；平台专属的 macOS/Windows/Android 路径继续按
Linux 构建目标禁用。JavaScript/MuJS、VapourSynth、CUDA、VA-API、Vulkan、
Wayland、X11、Sixel、CACA、SDL2、OpenAL、sndio、PipeWire、PulseAudio 等
功能均显式管理，避免依赖环境变化导致功能静默缺失。

JACK 是唯一的特殊依赖策略：`mpv-Emo` 编译时启用 `-Djack=enabled`，运行时直接声明
`pipewire-jack`，不引入 JACK2。Arch 的 `pipewire-jack` 提供 `jack`、`libjack.so`
等兼容接口，因此仍满足 mpv 的 JACK 构建需求，同时明确保持 PipeWire 音频栈。
