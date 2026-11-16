#!/usr/bin/env bash
# ffmpeg-full 构建后功能验证（Phase 4.3/4.4/4.5）。
#
# configure 对 --enable-lib* 是"尽力而为"：构建环境缺一个 pkgconfig 文件就
# 会静默降级 disable，构建仍然全绿——只有对真实产物的断言能拦住这种静默
# 功能丢失。本脚本：
#
#   1. 采集产物自述：-buildconf / -hwaccels / -encoders / -decoders / -filters；
#   2. 对照 packages/ffmpeg-full/feature-matrix.txt 逐条断言，缺失即失败；
#   3. 无 GPU 也能跑的功能链路测试（lavfi 测试源经编码→管道→解码→null）；
#   4. GPU 专项：nvidia-smi 有卡且能建 CUDA 设备才执行 NVENC→NVDEC 链路；
#      无 GPU 明确输出 gpu: not-executed（写入 JSON 与 stdout），绝不把
#      "没测"伪装成"通过"；
#   5. 动态库检查（4.4）：ffmpeg 与 libav* 不得带 RPATH/RUNPATH、ldd 不得有
#      缺失项、DT_NEEDED 不得是绝对路径、不得泄漏构建树子串。
#
# 用法:
#   verify-ffmpeg-features.sh --ffmpeg /usr/bin/ffmpeg \
#       --matrix packages/ffmpeg-full/feature-matrix.txt \
#       --json-out dist/ffmpeg-features.json [--lib-dir /usr/lib] [--no-gpu]
#
# 退出码：0 = 矩阵断言与功能测试全过（GPU not-executed 不算失败）；
#         1 = 任一断言/功能测试失败；2 = 用法或前置条件错误。
set -Eeuo pipefail
export LC_ALL=C

ffmpeg_bin=""
matrix=""
json_out=""
lib_dir="/usr/lib"
no_gpu=0
skip_functional=0
banned_substrings="staging"

while (( $# > 0 )); do
    case "$1" in
        --ffmpeg) ffmpeg_bin="$2"; shift 2 ;;
        --matrix) matrix="$2"; shift 2 ;;
        --json-out) json_out="$2"; shift 2 ;;
        --lib-dir) lib_dir="$2"; shift 2 ;;
        --banned) banned_substrings="$2"; shift 2 ;;
        --no-gpu) no_gpu=1; shift ;;
        --skip-functional) skip_functional=1; shift ;;
        --help | -h)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -x "$ffmpeg_bin" ]] || { printf 'ffmpeg binary not executable: %s\n' "$ffmpeg_bin" >&2; exit 2; }
[[ -r "$matrix" ]] || { printf 'feature matrix not readable: %s\n' "$matrix" >&2; exit 2; }
command -v readelf > /dev/null || { printf 'readelf is required\n' >&2; exit 2; }
command -v ldd > /dev/null || { printf 'ldd is required\n' >&2; exit 2; }
command -v strings > /dev/null || { printf 'strings is required\n' >&2; exit 2; }

workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

errors=()
note() { printf '%s\n' "$*" >&2; }

# ---- 1. 采集产物自述 -------------------------------------------------------

"$ffmpeg_bin" -hide_banner -buildconf > "$workdir/buildconf.txt" 2>/dev/null ||
    { note "ffmpeg -buildconf failed"; exit 1; }
"$ffmpeg_bin" -hide_banner -hwaccels > "$workdir/hwaccels.txt" 2>/dev/null || true
"$ffmpeg_bin" -hide_banner -encoders > "$workdir/encoders.txt" 2>/dev/null || true
"$ffmpeg_bin" -hide_banner -decoders > "$workdir/decoders.txt" 2>/dev/null || true
"$ffmpeg_bin" -hide_banner -filters > "$workdir/filters.txt" 2>/dev/null || true
version_line="$("$ffmpeg_bin" -hide_banner -version 2>/dev/null | head -1 || true)"

# buildconf 的 configuration 有两种形态：ffmpeg ≤8 是一整行
# "configuration: --flag --flag ..."；9.0.2 起是缩进逐行排列（"  configuration:"
# 后每个 flag 单独一行,以空行结束,实测 2026-11-17）。两种都要能拆 token,
# 旧解析对 9.0.2 得到空集,30 个 flag 断言全部假 MISSING(CI run 43921345810)。
conf_flags="$(awk '
    /^[[:space:]]*configuration:/ {
        rest = substr($0, index($0, ":") + 1)
        sub(/^[[:space:]]+/, "", rest)
        if (rest != "") {
            n = split(rest, a, " ")
            for (i = 1; i <= n; i++) print a[i]
            next
        }
        inconf = 1
        next
    }
    inconf {
        if ($0 !~ /^[[:space:]]/) { inconf = 0; next }
        gsub(/^[[:space:]]+/, "")
        if ($0 != "") print
        next
    }
' "$workdir/buildconf.txt")"
hwaccels_body="$(tail -n +2 "$workdir/hwaccels.txt")"

matrix_has_token() { # <class> <token>
    awk -v cls="$1" -v tok="$2" '
        $1 == cls && $2 == tok { found = 1 }
        END { exit !found }
    ' "$matrix"
}

matrix_tokens() { # <class>; 打印该类全部 token
    awk -v cls="$1" '$1 == cls { print $2 }' "$matrix"
}

# ---- 2. 矩阵断言 -----------------------------------------------------------

flag_missing=0
while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    if ! grep -Fxq -- "--enable-${token}" <<<"$conf_flags"; then
        note "MISSING flag: --enable-${token}"
        errors+=("flag:--enable-${token}")
        flag_missing=$((flag_missing + 1))
    fi
done < <(matrix_tokens flag)

hwaccel_missing=0
while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    if ! grep -Fxq "$token" <<<"$hwaccels_body"; then
        note "MISSING hwaccel: ${token}"
        errors+=("hwaccel:${token}")
        hwaccel_missing=$((hwaccel_missing + 1))
    fi
done < <(matrix_tokens hwaccel)

list_missing() { # <class> <file>
    local class="$1" file="$2" token count=0
    while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        # NR >= 2: the first line is the table header ("Encoders:"), the very
        # next line is already data. NR > 2 skipped the first data row (aac,
        # h264, libplacebo were false MISSINGs in the first run).
        if ! awk -v tok="$token" 'NR >= 2 && $2 == tok { found = 1 } END { exit !found }' "$file"; then
            note "MISSING ${class}: ${token}"
            errors+=("${class}:${token}")
            count=$((count + 1))
        fi
    done < <(matrix_tokens "$class")
    printf '%s\n' "$count"
}
encoder_missing="$(list_missing encoder "$workdir/encoders.txt")"
decoder_missing="$(list_missing decoder "$workdir/decoders.txt")"
filter_missing="$(list_missing filter "$workdir/filters.txt")"

needed_objects=()
needed_objects+=("$ffmpeg_bin")
shopt -s nullglob
for lib in "$lib_dir"/libavcodec.so.* "$lib_dir"/libavdevice.so.* \
           "$lib_dir"/libavfilter.so.* "$lib_dir"/libavformat.so.* \
           "$lib_dir"/libavutil.so.* "$lib_dir"/libswscale.so.* \
           "$lib_dir"/libswresample.so.*; do
    needed_objects+=("$lib")
done
shopt -u nullglob

needed_missing=0
while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    found=0
    for obj in "${needed_objects[@]}"; do
        if readelf -d "$obj" 2>/dev/null | awk '/NEEDED/ { print $NF }' | tr -d '[]' | grep -q "^${token}"; then
            found=1
            break
        fi
    done
    if (( found == 0 )); then
        note "MISSING needed: ${token} (no libav*/ffmpeg object links it)"
        errors+=("needed:${token}")
        needed_missing=$((needed_missing + 1))
    fi
done < <(matrix_tokens needed)

# ---- 2b. dlopen 引用断言 ----------------------------------------------------
# ffmpeg 9 起 vapoursynth 等集成改为运行时 dlopen（产物无 DT_NEEDED,
# 2026-11-17 CI run 43921345810 实测:demuxer 编入但 no libav* links it）。
# 对产物 strings 查引用名,缺失即断言失败——dlopen 的库不在运行时装上,
# 链路在 functional/gpu 阶段才暴露,这里先拦静默丢失。

dlopen_missing=0
while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    found=0
    for obj in "${needed_objects[@]}"; do
        # grep -q 会在首个命中处立刻退出,strings 对几十 MB 的真产物随后
        # 吃 SIGPIPE,pipefail 把整个管道判假 → 已引用的库被误报 MISSING
        # (CI run 43928304170:libavformat 明明含 libvapoursynth-script.so
        # 仍报 MISSING)。用不带 -q 的 grep 消费完整个输入再判。
        if [[ -n "$(strings -a "$obj" 2>/dev/null | grep -F -- "$token")" ]]; then
            found=1
            break
        fi
    done
    if (( found == 0 )); then
        note "MISSING dlopen: ${token} (no libav*/ffmpeg object references it)"
        errors+=("dlopen:${token}")
        dlopen_missing=$((dlopen_missing + 1))
    fi
done < <(matrix_tokens dlopen)

# ---- 3. 无 GPU 功能链路（编码 → 管道 → 解码 → null） ------------------------

functional_pass=()
functional_fail=()
run_chain() { # <name> <encode-args...> -- <decode-input>
    local name="$1"
    shift
    local encode_args=()
    local split=0
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then split=1; continue; fi
        if (( split == 0 )); then encode_args+=("$arg"); fi
    done
    if (( ${#encode_args[@]} > 0 )); then
        if "$ffmpeg_bin" -v error -f lavfi -i testsrc2=size=128x96:rate=10:duration=1 \
            "${encode_args[@]}" -f matroska - 2>"$workdir/enc.$name.err" |
            "$ffmpeg_bin" -v error -i pipe:0 -f null - 2>"$workdir/dec.$name.err"; then
            functional_pass+=("$name")
            return 0
        fi
    fi
    functional_fail+=("$name")
    note "FUNCTIONAL FAIL: ${name}"
    sed -n '1,5p' "$workdir/enc.$name.err" 2>/dev/null | sed 's/^/  encode: /' >&2 || true
    sed -n '1,5p' "$workdir/dec.$name.err" 2>/dev/null | sed 's/^/  decode: /' >&2 || true
    return 0
}

if (( skip_functional == 0 )); then
    run_chain h264 -c:v libx264 -preset ultrafast
    run_chain hevc -c:v libx265 -preset ultrafast
    run_chain av1 -c:v libsvtav1 -preset 8
    # 音频链路：正弦源 → mp3 编码 → 解码 → null
    if "$ffmpeg_bin" -v error -f lavfi -i 'sine=frequency=440:duration=1' \
        -c:a libmp3lame -f mp3 - 2>"$workdir/enc.audio.err" |
        "$ffmpeg_bin" -v error -i pipe:0 -f null - 2>"$workdir/dec.audio.err"; then
        functional_pass+=("audio-mp3")
    else
        functional_fail+=("audio-mp3")
        note "FUNCTIONAL FAIL: audio-mp3"
    fi
    # 滤镜链：transpose+vflip 在 CPU 上可直接验证
    if "$ffmpeg_bin" -v error -f lavfi -i testsrc2=size=128x96:rate=10:duration=1 \
        -vf 'transpose=cclock,vflip' -f null - 2>"$workdir/filter.err"; then
        functional_pass+=("filter-chain")
    else
        functional_fail+=("filter-chain")
        note "FUNCTIONAL FAIL: filter-chain"
    fi
fi

# ---- 4. GPU 专项（区分执行与未执行，绝不静默标记成功） -----------------------

gpu_status="not-executed"
gpu_detail=""
if (( no_gpu == 1 )); then
    gpu_detail="--no-gpu was requested"
elif command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi -L > /dev/null 2>&1; then
    if "$ffmpeg_bin" -v error -init_hw_device cuda -f null - 2>"$workdir/gpu-init.err"; then
        if "$ffmpeg_bin" -v error -f lavfi -i testsrc2=size=128x96:rate=10:duration=1 \
            -c:v h264_nvenc -f h264 - 2>"$workdir/gpu-enc.err" |
            "$ffmpeg_bin" -v error -hwaccel cuda -i pipe:0 -f null - 2>"$workdir/gpu-dec.err"; then
            gpu_status="passed"
        else
            gpu_status="failed"
            gpu_detail="NVENC encode or NVDEC decode failed on a detected GPU"
            note "GPU FAIL: $gpu_detail"
            errors+=("gpu:nvenc-nvdec")
        fi
    else
        gpu_status="failed"
        gpu_detail="nvidia-smi reports a GPU but ffmpeg cannot create a CUDA device"
        note "GPU FAIL: $gpu_detail"
        errors+=("gpu:cuda-init")
    fi
else
    gpu_detail="no NVIDIA GPU detected (nvidia-smi absent or empty); hardware tests were NOT executed"
    note "GPU not-executed: $gpu_detail"
fi

# ---- 5. 动态库检查（4.4） ---------------------------------------------------

elf_fail=0
for obj in "${needed_objects[@]}"; do
    [[ -e "$obj" ]] || { note "ELF MISSING: $obj"; errors+=("elf:missing:$(basename "$obj")"); elf_fail=$((elf_fail + 1)); continue; }
    if readelf -d "$obj" 2>/dev/null | grep -Eq '\(RPATH\)|\(RUNPATH\)'; then
        note "ELF RPATH/RUNPATH present: $obj"
        errors+=("elf:rpath:$(basename "$obj")")
        elf_fail=$((elf_fail + 1))
    fi
    if ldd "$obj" 2>&1 | grep -q 'not found'; then
        note "ELF unresolved library: $obj: $(ldd "$obj" 2>&1 | awk '/not found/ {print $1}' | paste -sd, -)"
        errors+=("elf:unresolved:$(basename "$obj")")
        elf_fail=$((elf_fail + 1))
    fi
    if readelf -d "$obj" 2>/dev/null | awk '/NEEDED/ { print $NF }' | tr -d '[]' | grep -q '^/'; then
        note "ELF NEEDED with absolute path: $obj"
        errors+=("elf:needed-absolute:$(basename "$obj")")
        elf_fail=$((elf_fail + 1))
    fi
    IFS=',' read -r -a banned_list <<<"$banned_substrings"
    for banned in "${banned_list[@]}"; do
        [[ -n "$banned" ]] || continue
        # 同 dlopen 检查:grep -q 早退会让 strings 对大产物吃 SIGPIPE,
        # pipefail 反转判定 → 构建树泄漏被静默漏报。
        if [[ -n "$(strings -a "$obj" 2>/dev/null | grep -F -- "$banned")" ]]; then
            note "ELF leaks build-tree substring '$banned': $obj"
            errors+=("elf:leak:${banned}:$(basename "$obj")")
            elf_fail=$((elf_fail + 1))
        fi
    done
done

# ---- 6. 结论与机器可读报告 ---------------------------------------------------

python3 - "$json_out" <<PYEOF
import json, sys

errors = $(printf '%s\n' "${errors[@]-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')
functional_pass = $(printf '%s\n' "${functional_pass[@]-}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().split() if x]))')
functional_fail = $(printf '%s\n' "${functional_fail[@]-}" | python3 -c 'import json,sys; print(json.dumps([x for x in sys.stdin.read().split() if x]))')
report = {
    "schema": 1,
    "ffmpeg": $(printf '%s' "$version_line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),
    "matrix": $(printf '%s' "$matrix" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),
    "counts": {
        "flag_missing": $flag_missing,
        "hwaccel_missing": $hwaccel_missing,
        "encoder_missing": $encoder_missing,
        "decoder_missing": $decoder_missing,
        "filter_missing": $filter_missing,
        "needed_missing": $needed_missing,
        "dlopen_missing": $dlopen_missing,
        "elf_failures": $elf_fail,
    },
    "functional": {"passed": functional_pass, "failed": functional_fail},
    "gpu": {"status": "$gpu_status", "detail": "$gpu_detail"},
    "errors": errors,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
PYEOF

total_missing=$((flag_missing + hwaccel_missing + encoder_missing + decoder_missing + filter_missing + needed_missing + dlopen_missing))
printf 'SUMMARY ffmpeg-features matrix_missing=%d functional_failed=%d elf_failures=%d gpu=%s\n' \
    "$total_missing" "${#functional_fail[@]}" "$elf_fail" "$gpu_status"

# Functional failures are real failures: a chain that cannot encode/decode
# with the shipped build is exactly what this script exists to catch. They
# must reach the errors list or the exit code would ignore them.
for chain in "${functional_fail[@]}"; do
    errors+=("functional:${chain}")
done

if (( ${#errors[@]} > 0 )); then
    note "FAILED: ${#errors[@]} ffmpeg feature/lib check(s); see ${json_out:-stderr} for the machine-readable report"
    exit 1
fi
note "OK: feature matrix, functional chains, ELF checks all pass (gpu: $gpu_status)"
exit 0
