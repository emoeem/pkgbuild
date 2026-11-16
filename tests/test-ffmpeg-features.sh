#!/usr/bin/env bash
# verify-ffmpeg-features.sh 的行为测试（Phase 4.3/4.4/4.5）。
#
# 用 fixture ffmpeg 桩喂固定自述输出，覆盖五条路径：
#   1. 矩阵全绿 → exit 0，gpu 标注 not-executed（--no-gpu 时）；
#   2. 矩阵多一条 bogus flag → exit 1 且 MISSING 指名；
#   3. GPU 检测到但 CUDA 设备建不起来 → gpu: failed + gpu:cuda-init 入 errors
#      （GPU 在场时的失败是真失败，绝不允许静默）；
#   4. 无 GPU（无 nvidia-smi）→ not-executed 显式标注，不影响退出码；
#   5. ELF 检查：RUNPATH 与构建树泄漏子串都会失败。
# 功能链路用真实 ffmpeg 二进制（若本机存在）跑一次冒烟，桩链路则验证
# 失败路径（lavfi 命令直接失败）。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/verify-ffmpeg-features.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_ffmpeg_stub() { # <dir> <init_hw_device-exit> <lavfi-exit>
    local dir="$1" hwdev_exit="$2" lavfi_exit="$3"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/ffmpeg" <<MOCK
#!/usr/bin/env bash
lavfi_exit=$lavfi_exit
hwdev_exit=$hwdev_exit
case "\$*" in
  *-version*) echo 'ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers'; exit 0 ;;
  *-buildconf*)
    # ffmpeg 9.0.2 起是缩进逐行排列（"  configuration:" 后每 flag 一行,空行
    # 结束）;旧单行格式的兼容在用例 7 单独覆盖。
    cat <<'CONF'
ffmpeg version 9.0.2
  configuration:
    --prefix=/usr
    --enable-gpl
    --enable-version3
    --enable-nonfree
    --enable-shared
    --enable-libnpp
    --enable-libplacebo
    --enable-libsvtav1
    --enable-libsvthevc
    --enable-libsvtjpegxs
    --enable-libsvtvp9
    --enable-libopenvino
    --enable-libopencv
    --enable-vapoursynth
    --enable-whisper
    --enable-vulkan
    --enable-opencl
    --enable-cuda
    --enable-cuvid
    --enable-nvenc
    --enable-nvdec
    --enable-ffnvcodec
    --enable-libdrm
    --enable-vaapi
    --enable-vdpau
    --enable-libvpl
    --enable-libx264
    --enable-libx265
    --enable-libdav1d
    --enable-libaom
    --enable-libfdk-aac

CONF
    exit 0 ;;
  *-hwaccels*) printf 'Hardware acceleration methods:\ncuda\ndrm\nvaapi\nvdpau\nvulkan\nqsv\nopencl\n'; exit 0 ;;
  *-encoders*)
    printf 'Encoders:\n A..... aac                 AAC\n V..... libsvtav1           SVT-AV1\n V..... libsvthevc          SVT-HEVC\n V..... libsvtvp9           SVT-VP9\n V..... libsvtjpegxs        SVT-JPEG-XS\n V..... h264_nvenc          NVIDIA NVENC\n V..... hevc_nvenc          NVIDIA NVENC\n V..... libx264             libx264\n V..... libx265             libx265\n V..... libopenh264         OpenH264\n A..... libfdk_aac          FDK AAC\n A..... libmp3lame          mp3\n V..... rav1e               AV1\n'; exit 0 ;;
  *-decoders*)
    printf 'Decoders:\n V..... h264                H.264\n V..... hevc                HEVC\n V..... av1                 AV1\n V..... libdav1d            dav1d\n V..... h264_cuvid          Nvidia CUVID\n V..... hevc_cuvid          Nvidia CUVID\n'; exit 0 ;;
  *-filters*)
    printf 'Filters:\n  T.. = Timeline support\n  .S. = Slice threading\n  ------\n  T.. libplacebo            Compute and apply\n  ... scale_vulkan          Scale\n  ... overlay_vulkan        Overlay\n  ... transpose_vulkan      Transpose\n  ... whisper               Speech\n  ... zscale                Apply scaling\n'; exit 0 ;;
  *-init_hw_device*) exit "\$hwdev_exit" ;;
  # -f lavfi puts "lavfi" after "-f ", so the pattern cannot demand a dash.
  *lavfi*) exit "\$lavfi_exit" ;;
  *) exit 0 ;;
esac
MOCK
    chmod +x "$dir/bin/ffmpeg"
}

make_lib_dir() { # <dir> [with-rpath]
    local dir="$1" with_rpath="${2:-}"
    mkdir -p "$dir/lib"
    cat > "$dir/tiny.c" <<'EOF'
int ffmpeg_test_value(void) { return 42; }
EOF
    local extra=()
    [[ "$with_rpath" == with-rpath ]] && extra+=('-Wl,-rpath,/ffbuild/staging/lib')
    for lib in libavcodec libavdevice libavfilter libavformat libavutil libswscale libswresample; do
        gcc -shared -fPIC "${extra[@]}" -o "$dir/lib/$lib.so.9" "$dir/tiny.c"
    done
}

make_matrix() { # <file> [extra-line...]
    local file="$1"
    shift
    grep -vE '^(needed|dlopen) ' "$root/packages/ffmpeg-full/feature-matrix.txt" > "$file"
    [[ $# == 0 ]] || printf '%s\n' "$@" >> "$file"
}

# gcc 是 ELV 检查桩的前提（CachyOS 构建机与 CI builder 都有）。
command -v gcc > /dev/null || { printf 'SKIP  tests/test-ffmpeg-features.sh (gcc unavailable)\n'; exit 0; }

printf '%s\n' '1: a clean stub passes and marks gpu as not-executed'
make_ffmpeg_stub "$tmp/green" 0 0
make_lib_dir "$tmp/green"
make_matrix "$tmp/green-matrix.txt"
PATH="$tmp/green/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/green/bin/ffmpeg" --matrix "$tmp/green-matrix.txt" \
    --json-out "$tmp/green/report.json" --lib-dir "$tmp/green/lib" --no-gpu \
    >"$tmp/green/out.txt" 2>&1 ||
    fail "clean run exited non-zero: $(cat "$tmp/green/out.txt")"
grep -q 'gpu=not-executed' "$tmp/green/out.txt" || fail 'the SUMMARY does not state gpu=not-executed'
grep -q '"status": "not-executed"' "$tmp/green/report.json" || fail 'JSON gpu status is not not-executed'
python3 -c 'import json; r=json.load(open('"'$tmp/green/report.json'"')); assert r["counts"]["elf_failures"] == 0; assert r["errors"] == []' ||
    fail 'the clean run recorded errors'
echo 'ok: clean stub passes with gpu explicitly not-executed'

printf '%s\n' '2: a bogus matrix entry fails and names the token'
make_matrix "$tmp/bogus-matrix.txt" 'flag totally-bogus-flag'
if PATH="$tmp/green/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/green/bin/ffmpeg" --matrix "$tmp/bogus-matrix.txt" \
    --json-out "$tmp/bogus/report.json" --lib-dir "$tmp/green/lib" --no-gpu \
    >"$tmp/bogus-out.txt" 2>&1; then
    fail 'a bogus matrix flag passed the check'
fi
mkdir -p "$tmp/bogus"
if ! grep -q 'MISSING flag: --enable-totally-bogus-flag' "$tmp/bogus-out.txt"; then
    printf '%s\n' '--- bogus-out.txt (debug) ---' >&2
    cat "$tmp/bogus-out.txt" >&2 || true
    fail 'the bogus flag was not named in the failure output'
fi
echo 'ok: a missing matrix entry fails loudly and names the token'

printf '%s\n' '3: a detected GPU that cannot init CUDA is a real failure'
make_ffmpeg_stub "$tmp/gpufail" 1 0
make_lib_dir "$tmp/gpufail"
make_matrix "$tmp/gpufail-matrix.txt"
mkdir -p "$tmp/gpufail/bin"
cat > "$tmp/gpufail/bin/nvidia-smi" <<'MOCK'
#!/usr/bin/env bash
printf 'GPU 0: NVIDIA GeForce RTX (fixture)\n'
MOCK
chmod +x "$tmp/gpufail/bin/nvidia-smi"
if PATH="$tmp/gpufail/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/gpufail/bin/ffmpeg" --matrix "$tmp/gpufail-matrix.txt" \
    --json-out "$tmp/gpufail/report.json" --lib-dir "$tmp/gpufail/lib" \
    >"$tmp/gpufail-out.txt" 2>&1; then
    fail 'a GPU that cannot init CUDA passed the check'
fi
grep -q '"status": "failed"' "$tmp/gpufail/report.json" || fail 'JSON gpu status is not failed'
python3 -c 'import json; r=json.load(open('"'$tmp/gpufail/report.json'"')); assert "gpu:cuda-init" in r["errors"], r["errors"]' ||
    fail 'gpu:cuda-init is not recorded as an error'
echo 'ok: GPU present but CUDA unusable fails instead of silently passing'

printf '%s\n' '4: broken functional chains fail'
make_ffmpeg_stub "$tmp/funfail" 0 1
make_lib_dir "$tmp/funfail"
make_matrix "$tmp/funfail-matrix.txt"
if PATH="$tmp/funfail/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/funfail/bin/ffmpeg" --matrix "$tmp/funfail-matrix.txt" \
    --json-out "$tmp/funfail/report.json" --lib-dir "$tmp/funfail/lib" --no-gpu \
    >"$tmp/funfail-out.txt" 2>&1; then
    fail 'failing functional chains passed the check'
fi
python3 -c 'import json; r=json.load(open('"'$tmp/funfail/report.json'"')); assert len(r["functional"]["failed"]) >= 1, r["functional"]' ||
    fail 'functional failures are not recorded'
echo 'ok: broken functional chains fail'

printf '%s\n' '5: RPATH and build-tree leaks fail the ELF checks'
make_ffmpeg_stub "$tmp/elf" 0 0
make_lib_dir "$tmp/elf" with-rpath
make_matrix "$tmp/elf-matrix.txt"
if PATH="$tmp/elf/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/elf/bin/ffmpeg" --matrix "$tmp/elf-matrix.txt" \
    --json-out "$tmp/elf/report.json" --lib-dir "$tmp/elf/lib" --no-gpu \
    --banned '/ffbuild/staging' \
    >"$tmp/elf-out.txt" 2>&1; then
    fail 'an RPATH-bearing, build-tree-leaking artifact passed the ELF checks'
fi
grep -q 'ELF RPATH/RUNPATH present' "$tmp/elf-out.txt" || fail 'RUNPATH was not reported'
grep -q "ELF leaks build-tree substring '/ffbuild/staging'" "$tmp/elf-out.txt" ||
    fail 'the build-tree leak was not reported'
echo 'ok: RUNPATH and build-tree substring leaks both fail'

printf '%s\n' '6: the real feature matrix parses and counts 60+ entries'
entries="$(grep -cE '^(flag|hwaccel|encoder|decoder|filter|needed|dlopen) ' "$root/packages/ffmpeg-full/feature-matrix.txt")"
(( entries >= 60 )) || fail "the real feature matrix only has $entries entries"
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^(flag|hwaccel|encoder|decoder|filter|needed|dlopen)[[:space:]][^[:space:]]+$ ]] ||
        fail "malformed matrix line: $line"
done < <(grep -vE '^\s*(#|$)' "$root/packages/ffmpeg-full/feature-matrix.txt")
echo "ok: real matrix is well-formed with $entries entries"

printf '%s\n' '7: the legacy single-line buildconf (ffmpeg <=8) still parses'
make_ffmpeg_stub "$tmp/legacy" 0 0
make_lib_dir "$tmp/legacy"
make_matrix "$tmp/legacy-matrix.txt"
# 把 9.0.2 桩的多行 buildconf 换回旧单行格式，其余桩保持一致。
mkdir -p "$tmp/legacy/bin"
cat > "$tmp/legacy/bin/ffmpeg" <<MOCK
#!/usr/bin/env bash
case "\$*" in
  *-version*) echo 'ffmpeg version 8.0 Copyright (c) 2000-2025 the FFmpeg developers'; exit 0 ;;
  *-buildconf*) echo 'configuration: --prefix=/usr --enable-gpl --enable-version3 --enable-nonfree --enable-shared --enable-libx264 --enable-libx265 --enable-libplacebo --enable-libsvtav1 --enable-libsvthevc --enable-libsvtjpegxs --enable-libsvtvp9 --enable-libopenvino --enable-libopencv --enable-vapoursynth --enable-whisper --enable-vulkan --enable-opencl --enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec --enable-libdrm --enable-vaapi --enable-vdpau --enable-libvpl --enable-libdav1d --enable-libaom --enable-libfdk-aac'; exit 0 ;;
  *-hwaccels*) printf 'Hardware acceleration methods:\ncuda\ncuvid\ndrm\nvaapi\nvdpau\nvulkan\nqsv\nopencl\n'; exit 0 ;;
  *-encoders*) printf 'Encoders:\n A..... aac                 AAC\n V..... libsvtav1           SVT-AV1\n V..... libsvt_hevc         SVT-HEVC\n V..... libsvt_vp9          SVT-VP9\n V..... libsvtjpegxs        SVT-JPEG-XS\n V..... librav1e            AV1\n V..... h264_nvenc          NVIDIA NVENC\n V..... hevc_nvenc          NVIDIA NVENC\n V..... libx264             libx264\n V..... libx265             libx265\n V..... libopenh264         OpenH264\n A..... libfdk_aac          FDK AAC\n A..... libmp3lame          mp3\n'; exit 0 ;;
  *-decoders*) printf 'Decoders:\n V..... h264                H.264\n V..... hevc                HEVC\n V..... av1                 AV1\n V..... libdav1d            dav1d\n V..... h264_cuvid          Nvidia CUVID\n V..... hevc_cuvid          Nvidia CUVID\n'; exit 0 ;;
  *-filters*) printf 'Filters:\n  T.. libplacebo            Compute and apply\n  ... scale_vulkan          Scale\n  ... overlay_vulkan        Overlay\n  ... transpose_vulkan      Transpose\n  ... whisper               Speech\n  ... zscale                Apply scaling\n'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$tmp/legacy/bin/ffmpeg"
PATH="$tmp/legacy/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/legacy/bin/ffmpeg" --matrix "$tmp/legacy-matrix.txt" \
    --json-out "$tmp/legacy/report.json" --lib-dir "$tmp/legacy/lib" --no-gpu \
    >"$tmp/legacy/out.txt" 2>&1 ||
    fail "legacy buildconf run exited non-zero: $(cat "$tmp/legacy/out.txt")"
grep -q 'MISSING' "$tmp/legacy/out.txt" && fail "legacy buildconf produced false MISSINGs: $(cat "$tmp/legacy/out.txt")"
echo 'ok: legacy single-line buildconf still parses'

printf '%s\n' '8: the dlopen class asserts runtime-loaded libraries'
# 正向:产物引用 libvapoursynth-script(ffmpeg 9 的 vapoursynth demuxer dlopen 形态)
mkdir -p "$tmp/dlpass" "$tmp/dlfail"
make_matrix "$tmp/dlpass-matrix.txt" 'dlopen libvapoursynth-script'
mkdir -p "$tmp/dl"
cat > "$tmp/dl/with-vapoursynth.c" <<'EOF'
const char *vs_loader = "libvapoursynth-script.so.6";
int ffmpeg_test_value(void) { return 42; }
EOF
gcc -shared -fPIC -o "$tmp/green/lib/libavformat.so.9" "$tmp/dl/with-vapoursynth.c"
PATH="$tmp/green/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/green/bin/ffmpeg" --matrix "$tmp/dlpass-matrix.txt" \
    --json-out "$tmp/dlpass/report.json" --lib-dir "$tmp/green/lib" --no-gpu \
    >"$tmp/dlpass/out.txt" 2>&1 ||
    fail "dlopen pass run exited non-zero: $(cat "$tmp/dlpass/out.txt")"
python3 -c 'import json; r=json.load(open('"'$tmp/dlpass/report.json'"')); assert r["counts"]["dlopen_missing"] == 0' ||
    fail 'dlopen_missing is not 0 when the artifact references the library'
# 反向:产物不引用 → MISSING dlopen 且 exit 1
make_lib_dir "$tmp/green"
if PATH="$tmp/green/bin:/usr/bin:/bin" bash "$script" \
    --ffmpeg "$tmp/green/bin/ffmpeg" --matrix "$tmp/dlpass-matrix.txt" \
    --json-out "$tmp/dlfail/report.json" --lib-dir "$tmp/green/lib" --no-gpu \
    >"$tmp/dlfail-out.txt" 2>&1; then
    fail 'an artifact without the dlopen reference passed the dlopen assertion'
fi
grep -q 'MISSING dlopen: libvapoursynth-script' "$tmp/dlfail-out.txt" ||
    fail "MISSING dlopen was not reported: $(cat "$tmp/dlfail-out.txt")"
echo 'ok: dlopen references are asserted both ways'

printf 'all ffmpeg-features cases passed\n'
