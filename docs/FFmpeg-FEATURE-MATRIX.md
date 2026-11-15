# FFmpeg 功能矩阵

ffmpeg-full 的 configure 是"尽力而为"：`--enable-libX` 在构建环境缺一个 pkgconfig 文件时会**静默降级 disable**，构建仍然全绿。只有对真实产物的断言能拦住这种静默功能丢失。本仓库用声明式矩阵 + 构建后验证脚本实现。

## 组成

| 文件 | 角色 |
|---|---|
| `packages/ffmpeg-full/feature-matrix.txt` | 机器可读声明（69 条）：目标功能清单 |
| `scripts/verify-ffmpeg-features.sh` | 构建后逐条断言 + 功能链路 + ELF 检查 |
| `scripts/build-in-arch.sh` | verify 阶段对 ffmpeg-full 自动调用 |
| `dist/ffmpeg-features.json` | 每次构建产出的机器可读报告（schema 1） |

## 矩阵格式

`<class> <token>`，`#` 注释。六个类：

| class | 断言方式 |
|---|---|
| `flag` | `-buildconf` 的 configuration 里有 `--enable-<token>` |
| `hwaccel` | `-hwaccels` 表中的独立一行 |
| `encoder` / `decoder` / `filter` | 对应表第 2 字段精确匹配（表头跳过，`NR >= 2`） |
| `needed` | ffmpeg 或 libav* 的 `DT_NEEDED` 有以 `<token>` 开头的库（readelf -d） |

增删条目 = 改这一个文件；CI 与本地跑同一个脚本、读同一份声明，不存在第二份清单。

## 覆盖范围（当前 69 条）

configure 开关 30 条（libnpp/libplacebo/SVT 全家/openvino/opencv/vapoursynth/whisper/vulkan/opencl/cuda 全家/编解码库/gpl/version3/nonfree/shared……）、hwaccel 8 条、encoder 13 条、decoder 6 条、filter 9 条、needed 3 条（libplacebo/libvapoursynth-script/libopenvino）。

## 运行条件与 GPU 三态

- **无 GPU 功能链路**（每次构建都跑）：H.264/HEVC/AV1 编码→管道→解码→null、mp3 音频链、transpose+vflip 滤镜链。失败即构建失败。
- **GPU 专项三态**（绝不把"没测"伪装成"通过"）：
  - `passed`：nvidia-smi 有卡 + CUDA 设备可建 + NVENC→NVDEC 链路通；
  - `failed`：有卡但建不起 CUDA 或链路断 → 计入 errors → 构建失败；
  - `not-executed`：无卡（CI 容器）或 `--no-gpu` → 明确标注进 SUMMARY 与 JSON，不影响退出码。
- 运行条件说明：NVENC/NVDEC/CUVID 需要 `nvidia-utils`（optdepends）；NPP 滤镜需要 `cuda` 包（optdepends，运行期经 ld.so 配置解析）；Vulkan/OpenCL 需要 ICD（vulkan-icd-loader / ocl-icd 是 loader，驱动是运行环境的事）。

## ELF 检查（动态库与 ABI）

每次构建后对 ffmpeg 与 libav* 7 个库执行：

1. 禁止 RPATH/RUNPATH（`--disable-rpath` 已配置，产物必须没有）；
2. `ldd` 不得有缺失库；
3. `DT_NEEDED` 不得是绝对路径；
4. `--banned staging,srcdir`：不得泄漏构建树子串（strings 扫描）。

## 失败语义与首跑修正原则

- 任何矩阵断言 / 功能链 / ELF 检查失败 → 构建失败（指名道姓：`MISSING flag: --enable-libnpp` 这类）；
- **假红处理**：首次跑真实构建若某 token 与 9.0.2 产物实际命名不符（如 encoder 表的实际拼写），修 `feature-matrix.txt`（对照 `-encoders` 真实输出），**不放宽脚本**；
- SUMMARY 行：`SUMMARY ffmpeg-features matrix_missing=N functional_failed=N elf_failures=N gpu=<status>`。

## 本地手动运行

```bash
bash scripts/verify-ffmpeg-features.sh \
  --ffmpeg /usr/bin/ffmpeg \
  --matrix packages/ffmpeg-full/feature-matrix.txt \
  --json-out /tmp/ff-features.json \
  --banned staging,srcdir
```

GPU 在场时自动执行 NVENC→NVDEC 专项；`--no-gpu` 强制 not-executed；`--skip-functional` 只跑矩阵与 ELF（用于无 lavfi 源的容器）。

## 测试

`tests/test-ffmpeg-features.sh`：6 用例（全绿+GPU 标注、假红指名、GPU 建不起 CUDA 必须失败、功能链失败必须失败、RUNPATH/泄漏必须失败、真实矩阵格式校验）。桩为 fixture ffmpeg + gcc 生成的 ELF 桩，离线秒级。
