# mpv-Emo 构建策略

## 目标

`mpv-full` 是 mpv-Emo 的系统核心。构建优先跟随 AUR/upstream，私人仓库只保留明确、可验证的 Linux 构建策略。

当前基线：`mpv-full 0.41.0-2`，本仓库 overlay 后为 `0.41.0-2.1`。

## 当前构建层

```text
AUR mpv-full
    ↓
scripts/overlays/mpv-full.sh
    ↓
mpv-full / mpv-Emo core
    ↓
~/.config/mpv
```

overlay 当前只做两件事：

1. 将本地重构版本的 `pkgrel` 增加一个 `.1` 后缀。
2. 检查 mpv-Emo 所需的 Linux 原生特性仍保持启用。

## 已验证的 Linux 特性

- Vulkan
- Wayland
- dmabuf-wayland
- CUDA hwaccel
- CUDA interop
- VapourSynth
- PipeWire
- VA-API / DRM
- libplacebo / zimg
- Blu-ray / DVD 基础支持

这些能力不需要 Yaozhi 私有核心 patch。

## Patch 策略

暂不把 Yaozhi Windows 核心复制进私人仓库。

真正需要修改 mpv 核心时，patch 必须单独放入明确的 patch layer，并满足：

- 有明确 upstream 基线；
- 有独立的 patch 文件；
- 可以在 upstream 更新后失败即停，而不是静默失效；
- 能通过最小功能测试；
- 不影响默认 Linux 构建。

当前最值得单独研究的候选是 `ad_orender` / Omniphony 空间音频集成。

AV3A、Audio Vivid 或特殊多声道 PCM 只有在确认实际样本和 Linux 输出链路需求后再决定是否 patch。

Blu-ray `discnav` / `disc-menu` 不应作为永久私有 patch 维护；如果 upstream 已提供，应优先升级 mpv 基线。

## CI

mpv-full 使用仓库已有的 `build-in-arch.sh` 和 GitHub Actions，不需要为 mpv 再造一套容器构建系统。

AUR 同步时会自动重新应用 `scripts/overlays/mpv-full.sh`，随后由 `check-package.sh` 验证 `PKGBUILD`、`.SRCINFO` 和本地 source 文件一致。
