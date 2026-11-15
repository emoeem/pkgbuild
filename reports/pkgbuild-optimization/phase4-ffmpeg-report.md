# Phase 4 验收报告 — FFmpeg Full 构建质量优化（2026-11-15）

对应计划 Phase 4.1–4.5；问题定位见 [ffmpeg-audit.md](ffmpeg-audit.md)。未执行任何 git commit / push。

## 1. 变更文件清单

| 文件 | 变更 | 对应计划项 |
|---|---|---|
| `packages/ffmpeg-full/.lensfun-pin` | **新增**。40 位 commit `52cf1a7b0e82e07e0ecaa3391ee5106a6dd1ee54`（2026-11-04 的 master HEAD，唯一事实来源） | 4.1 |
| `packages/ffmpeg-full/PKGBUILD` | lensfun source 加 `#commit=<pin>`；`.SRCINFO` 同步重生成 | 4.1 |
| `packages/ffmpeg-full/.nvchecker.toml` | 扩为三 section（ffmpeg-full / lensfun-master / whisper-cpp），新增 `__baselines__` 显式基线机制（`pin:.lensfun-pin`、`pkgvar:_whispercpp_ver`） | 4.1 |
| `scripts/check-upstream-versions.py` | `load_definitions` 支持多 section + `__baselines__`（字面量 / `pkgvar:` / `pin:`），git source 的基线同样截短 7 位（防 nvcmp 恒报） | 4.1 |
| `scripts/overlays/ffmpeg-full.sh` | 新步骤 1b：每次 AUR 同步后从 `.lensfun-pin` 重放 pin（幂等正则，恰好一处替换，缺失/非法 pin 即红） | 4.1 |
| `packages/ffmpeg-full/feature-matrix.txt` | **新增**。69 条机器可读断言：30 flag / 8 hwaccel / 13 encoder / 6 decoder / 9 filter / 3 needed | 4.3 |
| `scripts/verify-ffmpeg-features.sh` | **新增**。矩阵断言 + 功能链路 + GPU 三态 + ELF 检查（详见 §3） | 4.3/4.4/4.5 |
| `scripts/build-in-arch.sh` | verify 阶段 ffmpeg-full 专属调用，`--banned staging,srcdir`；失败即构建失败 | 4.3 |
| `tests/test-ffmpeg-features.sh` | **新增**。6 用例（桩 ffmpeg + gcc 生成 ELF 桩） | 4.3 |
| `tests/test-build-regressions.sh` | 夹具补 `.lensfun-pin`，新增两条 overlay 断言（pin 重放 + PKGBUILD 可解析） | 4.1 |
| `tests/test_upstream_versions.py` | expected 集合 5→7，新增 vendored 基线断言（52cf1a7 / 1.9.5） | 4.1 |

## 2. 修复前后对比（4.1 VCS 依赖固定）

```text
修复前:
  source=('git+https://github.com/lensfun/lensfun.git')          # 无 #commit，每次构建拉 master
  sha256sums 第三项 'SKIP'                                       # 无校验
  .nvchecker.toml 只追踪 FFmpeg 本体                             # lensfun/whisper 零上游追踪
修复后:
  source=('git+https://github.com/lensfun/lensfun.git#commit=52cf1a7b0e82e07e0ecaa3391ee5106a6dd1ee54')
  .lensfun-pin = pin 的唯一事实来源；overlay 每次 sync 重放；nvchecker
    lensfun-master 条目以 pin 为基线（git use_commit，7 位对齐）→ pin 落后
    master 时每日 upstream-check 开 [upstream] issue
  whisper.cpp（1.9.5 = 当前 latest release tag，实测）纳入追踪；
    SVT-HEVC 基线刻意不追踪（上游仓库归档，commit 冻结——注释已写明）
  幂等验证：对已 pin 目录重跑 overlay → PKGBUILD 字节不变（IDEMPOTENT 实测）
```

## 3. verify-ffmpeg-features.sh 行为（4.3/4.4/4.5）

| 检查 | 实现 | 失败语义 |
|---|---|---|
| configure 开关 | `-buildconf` 的 configuration 逐 flag `grep -Fxq --enable-<token>` | MISSING 指名 → errors |
| hwaccels/encoders/decoders/filters | 各表逐 token 断言（表头跳过，`NR >= 2`——首版 `NR > 2` 漏掉第一数据行，被桩测试抓出） | 同上 |
| DT_NEEDED | ffmpeg + libav* 7 个库的 readelf NEEDED 按前缀比对 | 同上 |
| 功能链路（无 GPU） | testsrc2 → libx264/libx265/libsvtav1 编码 → 管道 → 解码 → null；sine → libmp3lame；transpose+vflip 滤镜链 | functional_fail → errors → exit 1 |
| GPU 专项 | 三态：`passed`（nvidia-smi 有卡 + CUDA 可建 + NVENC→NVDEC 链路通）/ `failed`（有卡建不起 CUDA 或链路断 → errors）/ `not-executed`（无卡或 `--no-gpu`，detail 写明"NOT executed"） | failed 才失败；not-executed 显式标注，**绝不伪装成功** |
| ELF（4.4） | RPATH/RUNPATH 禁止、ldd 缺失库、NEEDED 绝对路径、`--banned` 构建树子串泄漏（staging,srcdir） | 每条指名 → errors |

机器可读报告 `dist/ffmpeg-features.json`（schema 1：counts/functional/gpu/errors）+ stdout `SUMMARY ffmpeg-features matrix_missing=N functional_failed=N elf_failures=N gpu=<status>`。

## 4. 测试报告

| 套件 | Phase 3 | 本次 |
|---|---|---|
| `./tests/run-all.sh --fast` | 134 / 0 | **137 / 0 / 2 skip**（+test-ffmpeg-features.sh 6 用例；regressions +2 断言；upstream 13→14 用例） |
| `./scripts/run-static-checks.sh` | 14/14 | **14/14** |
| `bash tests/test-ffmpeg-features.sh` | — | 6/6 过（含真实矩阵 69 条目格式校验） |

实施中被自家测试抓出并修复的三个缺陷：
1. 脚本 `list_missing` 的 `NR > 2` off-by-one（漏查每表第一数据行 → aac/h264/libplacebo 假 MISSING）；
2. 脚本功能链失败不进 errors（退出码无视 functional_fail）；
3. 测试夹具 `make_matrix` 的 printf 未重定向（bogus flag 没写进矩阵，用例 2 名存实亡）。

## 5. 剩余风险（含未执行项的显式标注）

1. **【not-executed】真实 ffmpeg-full 构建上的矩阵首跑**：矩阵 token 与 9.0.2 实际产物命名（如 `libsvtjpegxs` 是否真在 encoders 表）只能由下一次 CI/本地完整构建验证；`feature-matrix.txt` 头注释已声明"首跑假红修正矩阵，不放宽脚本"。GPU 专项同理：CI 容器无 GPU → not-executed（符合计划 4.5 的区分要求）；GPU 实机专项待有 NVIDIA 环境的运行点执行。
2. lensfun pin 的验证方式受限于 pin 时刻：`makepkg --verifysource` 在下次完整构建时首次走过 `#commit=` 路径；本机已验证 `makepkg --printsrcinfo` 对带 `#commit` 的 git source 解析正常。
3. whisper.cpp 若升级到带 ABI 变化的新版，需重新验证 070 补丁——nvchecker issue 会提示，构建是验证点。
4. `--banned staging` 用 strings 扫 ELF：泄漏若藏在未加载段以外的非常规节，理论上可漏——已覆盖 ffmpeg 构建泄漏的历史形态（libavfilter.pc 路径、staging 目录名）。

## 6. 复现命令与预期回显

```bash
cd /media/emo/code/pkgbuild

# 1. pin 与追踪基线：
grep -n 'lensfun.git#' packages/ffmpeg-full/PKGBUILD
# 预期: 167 行 'git+https://github.com/lensfun/lensfun.git#commit=52cf1a7b0e82e07e0ecaa3391ee5106a6dd1ee54'
python3 -c "
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('m', 'scripts/check-upstream-versions.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d, b = m.load_definitions(Path('.'))
print(b['lensfun-master'], b['whisper-cpp'])"
# 预期: 52cf1a7 1.9.5

# 2. overlay 幂等（含 pin 重放）：
cp -r packages/ffmpeg-full /tmp/ff-ov && bash scripts/overlays/ffmpeg-full.sh /tmp/ff-ov && \
  diff <(grep lensfun.git /tmp/ff-ov/PKGBUILD) <(grep lensfun.git packages/ffmpeg-full/PKGBUILD) && echo IDEMPOTENT; rm -rf /tmp/ff-ov
# 预期: IDEMPOTENT

# 3. 功能验证脚本（桩测试 + 真实矩阵格式校验）：
bash tests/test-ffmpeg-features.sh
# 预期: all ffmpeg-features cases passed

# 4. 回归：
./tests/run-all.sh --fast 2>&1 | tail -2
# 预期: passed 137, failed 0, skipped 2 / All local checks passed.
```

**阶段验收结论**：4.1（lensfun 固定 commit + 自动追踪，不再无条件拉 master）✅；4.2（依赖划分逐项判定见 ffmpeg-audit §3，无需改动的结论成立）✅；4.3（构建后自动采集+矩阵比对，缺失即失败）✅；4.4（RPATH/缺失库/绝对路径/泄漏检查）✅；4.5（无 GPU 功能链路 + GPU 三态标注）✅。FFmpeg 的构建配置、动态链接和功能测试结果能够自动生成报告（json + SUMMARY）。可进入 Phase 5（自动更新与 ABI 重建调度优化）。
