# Emo 本机专用高性能构建策略

目标机器：AMD Ryzen 7 7735H（Zen 3 / znver3）、16 线程、RTX 4050 Laptop（CUDA Compute Capability 8.9）。

本仓库是**本机专用仓库**，不承诺生成的二进制在其他 CPU 上运行。因此 x86_64 构建优先使用：

- `-march=znver3 -mtune=znver3`
- `-O3`
- `-pipe -fno-plt -fexceptions`
- Fortify / format / stack-clash-protection
- Rust：`-C target-cpu=znver3 -C opt-level=3`
- CUDA：固定架构 `89`，不依赖 CI 构建机 GPU 探测

## 包分类

| 包 | 策略 | 说明 |
|---|---|---|
| `ffmpeg-full` | Zen3 + O3 + full LTO | 核心媒体包，CPU/SIMD 路径很多 |
| `ggml-cuda-git` | Zen3 + O3 + GGML LTO + CUDA 89 | CPU backend + RTX 4050 CUDA |
| `llama.cpp-cuda-git` | Zen3 + O3 + GGML LTO + CUDA 89 | 本机推理核心 |
| `llama.cpp-cuda` | Zen3 + O3 + GGML LTO + CUDA 89 | 本机推理核心 |
| `whisper-cpp-cuda-git` | Zen3 + O3 + CUDA GGML | ASR CPU/CUDA 路径 |
| `scx-scheds-git` | Zen3 Rust target，保留 `!lto` | PKGBUILD 已明确禁用 makepkg LTO |
| `daed-emo` | GOAMD64=v3 | Go 优化收益主要由 Go 工具链控制 |
| C/C++/CMake 编解码库 | Zen3 + O3 | 适合本机 profile |
| `xclip-git` / 纯脚本 / `-any` 包 | 不追求 LTO | 本地机器码收益很小 |

## LTO / PGO

LTO 不全局强制。已经启用 LTO 的 CUDA/ggml 包继续使用项目自己的 LTO 开关。

ffmpeg-full 单独启用 --enable-lto=full，先以实际构建结果验证 GCC 16 + FFmpeg 9.0.2 + 当前汇编路径是否稳定。

PGO 当前不默认启用。PGO 需要稳定、代表性的真实负载；FFmpeg 应使用实际常用的解码、编码和滤镜 workload 生成 profile，而不是随便跑一次样例。后续如做 PGO，应建立独立 profile 构建流程。

## CUDA

RTX 4050 Laptop 属于 Ada Lovelace，Compute Capability 8.9。CUDA 包固定使用 CMAKE_CUDA_ARCHITECTURES=89，避免 GitHub runner 没有 NVIDIA GPU 时 native 探测失败或退回错误架构。

## 构建可重复性

“本机专用”不等于依赖构建机随机硬件探测：

- CPU 固定为 znver3
- GPU 固定为 CUDA 89
- builder 预检 GCC、Objective-C、assembler、linker
- 编译并行度由 MAKE_JOBS 控制
- LTO 按包显式选择
- PGO 保持独立，不污染普通 release 构建

这些设置只用于本仓库自己的二进制发布，不改变系统 /etc/makepkg.conf，也不会把其他 Arch/CachyOS 软件强制改成本机优化版本。
