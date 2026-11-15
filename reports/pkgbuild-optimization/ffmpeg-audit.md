# Phase 0 审计 — ffmpeg-full（2026-11-15，9.0.2-3.43）

## 1. 包概况与现有质量资产

- AUR 镜像包 + `scripts/overlays/ffmpeg-full.sh` 重放本地定制（libnpp 开启、cuda optdepends、pkgrel `.6` 下限只升不降、x86-64-v3 flag 块替换、vendored openapv 1.1 补丁对账）。overlay 幂等 + 锚点断言 + 失败即红，`test-sync-aur-packages.sh` 有覆盖。
- 构建（`build-in-arch.sh:223-246`）：FFmpeg GPG key 指纹预验 + 提前 `makepkg --verifysource`；CUDA 环境（`CUDA_PATH=/opt/cuda`、`NVCC_CCBIN=/usr/bin/g++-15`、PATH 注入，:171-177）；虚拟依赖预解析（sdl2-compat/libglvnd/l-smash/onetbb/tevent/tesseract-data，:295-301）。
- ABI 治理：发布后 `generate-abi-manifest.sh` 产清单 → `build.yml:88-96` 供 planner 漂移判定；`check-repository-sonames.sh` 每 2 小时对已发布包做 ELF NEEDED 检查；openvino liboapv 事故（CURRENT-STATUS.md:14-16）后发布闸门含 same-version 拒绝。
- 重建风暴已治理（2026-11-10）：pkgrel-only 只报 NOTE、dispatch 24h 成功冷却 + SONAME urgent 豁免、planner 漂移仅 `all` 选择应用（`build-planner.py:176-196`）。

## 2. 源与版本固定（Phase 4.1）

### 2.1 【P0】lensfun：未固定 commit 的 git master + SKIP 校验 + 零上游追踪

- **问题描述**：`source=('git+https://github.com/lensfun/lensfun.git')`（`PKGBUILD:167`），对应 `sha256sums` 第三项为 `'SKIP'`（`:180`）。每次构建无条件拉取 master HEAD：构建不可复现，master 一天多变，且没有任何自动化能发现"lensfun 又动了"。
- **位置**：`packages/ffmpeg-full/PKGBUILD:167,180`（.SRCINFO `source = git+…lensfun.git`，:159）；构建脚本注释 `PKGBUILD:217-220` 解释了为何 vendored 静态构建（lensfun-git 包安装路径错误 + 避免 soname bump 波及 gegl），这个决策本身合理，**问题只在没 pin**。
- **复现条件**：任意两次构建之间 lensfun master 前进 → staging 里的静态 liblensfun 字节不同；上游 API 破坏 → 构建红（正是 2026-10 系列构建失败的模式）。
- **影响范围**：可复现性（Phase 4 目标）、故障排查（失败无法归因到具体 lensfun commit）、静默功能漂移。
- **推荐修复**：
  1. `git+…lensfun.git#commit=<固定40位>`，`SKIP` 保留（VCS 源惯例）；
  2. `packages/ffmpeg-full/.nvchecker.toml` 增加 `[ffmpeg-full-lensfun]` source（github tags 或 commits），让每日 `upstream-check.yml` 开 issue 提示"该升级 pin 了"——复用现有 nvchecker 管道，不新增机制；
  3. 升级 pin 时按计划重新验证兼容性（构建即验）。
- **验证方式**：`makepkg --verifysource` 成功且 `src/lensfun` HEAD 等于 pin 值；nvchecker 报告出现新条目；`validate-source-cache.sh`（git 缓存校验）不报冲突。
- **同型缺口**：`_whispercpp_ver='1.9.5'` 已 pin（好），但同样无 nvchecker 追踪；`_svt_hevc_ver` pin 了 commit（好），无追踪。建议三者一并纳入 `.nvchecker.toml`。

### 2.2 其余源

ffmpeg tar.xz+asc（validpgpkeys pin）、8 个本地补丁（vendored，openapv 补丁由 overlay 对账 checksum）——无问题。

## 3. 依赖划分（Phase 4.2）

configure 目标功能与声明对照（`PKGBUILD:250-404`）：

| 功能 | configure | 依赖声明 | 判定 |
|---|---|---|---|
| NVENC/NVDEC/CUVID | `--enable-nvenc/nvdec/cuvid/ffnvcodec`（:391,395-396） | makedep `ffnvcodec-headers`；optdepends `nvidia-utils` | ✅ 正确：headers 编译期，驱动运行期可选 |
| CUDA/NVCC/NPP | `--enable-cuda-nvcc/cuda-llvm/libnpp`（:388-389,394） | makedep `cuda`；optdepends `cuda`（NPP 滤镜运行期） | ✅ 划分成立（overlay 注释 :24-27 有论证）；**注意 NVCC_CCBIN 锁 `/usr/bin/g++-15`（build-in-arch.sh:174）——gcc 主版本滚动后该路径消失会构建失败，需随 toolchain 更新** |
| Vulkan/libplacebo | `--enable-vulkan/libplacebo`（:321,404） | depends `vulkan-icd-loader`、`libplacebo`；makedep `vulkan-headers`、`spirv-headers`、`glslang` | ✅ loader 运行期、headers 编译期 |
| OpenCL | `--enable-opencl`（:398） | depends `ocl-icd`；makedep `opencl-headers` | ✅ loader 正确；ICD 驱动（intel-compute-runtime/rocm 等）未声明 optdepends——建议补一行说明运行条件（非缺陷） |
| OpenVINO | `--enable-libopenvino`（:319） | depends `openvino` | ✅（历史上 openapv/liboapv 事故与 openvino SONAME 无 provides 有关，检测器已覆盖） |
| OpenCV | `--enable-libopencv`（:315） | depends `opencv4` | ✅ 链接型依赖 |
| VapourSynth | `--enable-vapoursynth`（:377） | depends `vapoursynth`（dlopen，:118 注释） | ✅ |
| Whisper | `--enable-whisper`（:378） | vendored 静态 whisper.cpp 1.9.5（规避循环依赖，:228-229 注释） | ✅ 无外部运行时依赖 |
| SVT 系列 | `--enable-libsvtav1/svthevc/svtjpegxs/svtvp9` | depends `svt-av1/svt-hevc/svt-jpeg-xs/svt-vp9` | ✅（svt-hevc 补丁基线 pin commit；svt-jpeg-xs-git 为仓内包，DAG/wait-for-build-dependencies 处理同轮次序） |
| OpenGL | `--enable-opengl`（:399） | makedep `libgl`；**depends 未见 libglvnd 直接声明** | ⚠️ 待 Phase 4.4 `ldd` 闭包核实（`libGL.so.1` 由 libglvnd 提供；当前靠闭包内其它包传递满足——构建期 runtime-verify 已装包验证 ldd，故现状大概率成立，但显式声明更稳） |
| SDL2 | `--enable-sdl2`（:385） | depends `sdl2`；builder 预装 `sdl2-compat`（provides sdl2） | ✅ 由 provides 满足，行为正确（可加注释说明） |

未发现"运行时必需依赖被放进 optdepends"（计划 4.2 第 4 条）或"为过检查乱加依赖"（第 5 条）的情况。`makedepends` 与 `depends` 的分界整体正确。

## 4. 构建配置与功能验证（Phase 4.3/4.5）——当前为空白

- **问题描述**：构建后只收 namcap、.PKGINFO/.BUILDINFO、`verify-build-dependencies.sh`、runtime-verify（ldd/SONAME/符号链接/权限 + smoke `ffmpeg -version`/`ffprobe -version`，`scripts/data/smoke-tests.yaml`）。**没有任何 `-buildconf`/`-encoders`/`-decoders`/`-filters`/`-hwaccels` 采集与比对**：configure 成功 ≠ 功能在产物里（头文件缺失时 configure 会静默降级 disable 某个 `--enable-lib*`，FFmpeg 的已知行为——`--enable-foo` 在依赖不可探测时只是"尽力而为"）。
- **位置**：`build-in-arch.sh:420-447`（verify/smoke 阶段）；`smoke-tests.yaml`（仅 -version 两条）。
- **复现条件**：任一 `--enable-libX` 因构建环境缺 pkgconfig 而被静默禁用 → 构建绿、发布、用户发现滤镜没了——没有任何闸门会红。
- **影响范围**：计划列出的 10 项目标功能（NVENC/NVDEC/CUDA/Vulkan/OpenCL/libplacebo/SVT-AV1/VapourSynth/Whisper/OpenVINO）全部无验证。
- **推荐修复**（Phase 4.3 落点）：
  1. 新增 `scripts/verify-ffmpeg-features.sh`：构建后运行 `ffmpeg -buildconf`（断言每个 `--enable-*` 目标 flag 出现）、`ffmpeg -hwaccels`（断言 cuda/cuvid/vaapi/vulkan/drm）、`ffmpeg -encoders|decoders|filters`（断言 nvenc_*、libsvt_av1、libplacebo 相关 filter、vapoursynth、whisper 等关键条目存在）；产机器可读 JSON 到 dist/；
  2. 目标清单落在 `packages/ffmpeg-full/` 下的声明文件（与 `.build-strategy` 同目录风格），CI 与本地同源；
  3. 失败 = 构建失败（fail loudly），不是警告。
- **验证方式**：本地跑一次脚本对当前 9.0.2-3.43 已发布包（或本机安装的 ffmpeg-full）应全绿；人为删一个断言条目应红。
- **GPU 专项（4.5）**：CI runner 无 NVIDIA GPU，NVDEC/NVENC 真解码/编码测试**当前完全不存在**。修复时需按计划区分：无 GPU 环境 → 功能存在性检查（上条）+ 明确标注 `gpu-tests: not-executed`（进 build 摘要与产物 JSON，不许静默标成功）；有 GPU 环境（本机 `emo` 主机可跑）→ 专项 smoke（`ffmpeg -hwaccel cuda -i lavfi …` 型最小用例）。

## 5. 动态库与 ABI 检查（Phase 4.4）现状

| 检查 | 现状 | 缺口 |
|---|---|---|
| ldd 缺库 | ✅ runtime-verify（装包后） | — |
| SONAME/符号链接 | ✅ runtime-verify + `verify-repository-elf.sh`（发布） | — |
| .BUILDINFO 依赖对账 | ✅ verify-build-dependencies.sh | — |
| 已发布包 NEEDED vs 提供者 | ✅ check-repository-sonames（每 2h） | — |
| RPATH/RUNPATH | 部分：namcap rpath/runpath 规则**对 ffmpeg-full 未豁免**（`.namcap-exclude` 仅 dsh 有），构建期硬门禁在 | 建议显式断言产物 RPATH 为空（`--disable-rpath` 已配置，:254），进 verify-ffmpeg-features |
| 构建环境临时路径泄漏 | ❌ 无检查（staging 路径已从 libavfilter.pc 剥离，`:413-417`，但 ELF 字符串/其它 .pc 未查） | readelf -d + `grep -r "$srcdir"` 类断言 |
| NVIDIA 依赖边界 | 部分：cuda 构建期（makedep/optdep 划分正确）；`/opt/cuda/lib64` 通过 LDFLAGS 注入（:245），产物不应残留 rpath（同上断言） | 见上 |

## 6. 重建频率与调度（Phase 5.2 关联）

- 三个历史放大器已修（见 §1）；当前残余触发源：依赖 **pkgver** 真实前进（合理）+ SONAME urgent（合理）；24h 冷却对 ffmpeg-full 这类 ~120 滚动依赖的包等于"每天至多一次例行重建"——符合计划 5.2 的期望形态。
- lensfun/whisper.cpp 子依赖的"独立冷却"目前无意义（它们连追踪都没有）；pin + nvchecker（§2.1）之后，其更新走 `[upstream]` issue → 人工/更新器 bump pkgver，不进 ABI watch 的 pkgrel 循环，天然满足"高频 VCS 依赖独立冷却"。
- pkgrel 只升不降链（overlay `.6` 下限 → floor → bump → write-back）经 2026-11 系列修复后方向一致（`test-pkgrel-floor.sh`、`test_write_back_pkgrel.sh` 覆盖）。

## 7. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild
sed -n '166,168p;178,181p' packages/ffmpeg-full/PKGBUILD
# 预期: 167 行 'git+https://github.com/lensfun/lensfun.git'（无 #commit=）；
#       180 行（source 第 3 项 lensfun 对应的）'SKIP'
grep -c lensfun packages/ffmpeg-full/.nvchecker.toml; true    # 0（无追踪）
grep -n 'ffmpeg -version' scripts/data/smoke-tests.yaml       # 仅 :24 一条 ffmpeg -version（ffprobe 同型），无 -buildconf/-hwaccels
pacman -Q ffmpeg-full >/dev/null 2>&1 && ffmpeg -hwaccels 2>/dev/null | head -5 || echo 'ffmpeg-full 未安装于本机'
```
