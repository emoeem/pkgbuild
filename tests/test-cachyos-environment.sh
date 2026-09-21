#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-base}"

if [[ ! -f /etc/os-release ]] || ! grep -q "^ID=cachyos$" /etc/os-release; then
    echo "CachyOS environment required." >&2
    exit 1
fi

check() { printf '==> %s\n' "$1"; shift; "$@"; }

check 'repo: cachyos-v3' bash -c 'pacman-conf --repo-list | grep -Fxq cachyos-v3'
check 'repo: chaotic-aur' bash -c 'pacman-conf --repo-list | grep -Fxq chaotic-aur'
check 'package: chaotic-keyring' pacman -Qi chaotic-keyring >/dev/null
check 'command: pacman' command -v pacman >/dev/null
check 'command: makepkg' command -v makepkg >/dev/null
check 'command: aria2c' command -v aria2c >/dev/null
check 'architecture: x86_64' test "$(uname -m)" = x86_64

check 'command: gcc' command -v gcc >/dev/null
check 'command: g++' command -v g++ >/dev/null
check 'command: as' command -v as >/dev/null
check 'command: ld' command -v ld >/dev/null
check 'compiler: native march=znver3' bash -c '[[ "$(gcc -march=native -Q --help=target 2>/dev/null | awk '\''$1 == "-march=" {print $2}'\'')" == "znver3" ]]'
check 'compiler: znver3 C smoke test' bash -c 'gcc -march=znver3 -mtune=znver3 -O3 -x c -c -o /tmp/emo-cflags-test.o - <<< '\''int main(void){return 0;}'\'''
rm -f /tmp/emo-cflags-test.o

if [[ "$mode" == builder ]]; then
    check 'command: namcap' command -v namcap >/dev/null
    check 'command: yay' command -v yay >/dev/null
    check 'frontend: cc1obj' bash -c 'test -x "$(gcc -print-prog-name=cc1obj)"'
    check 'compiler: Objective-C smoke test' bash -c 'gcc -march=znver3 -mtune=znver3 -O3 -x objective-c -c -o /tmp/emo-objc-test.o - <<< '\''int main(void){return 0;}'\'''
    rm -f /tmp/emo-objc-test.o
    check 'pacman: DisableSandboxNetwork' bash -c 'pacman-conf DisableSandboxNetwork | grep -Fxq DisableSandboxNetwork'
    check 'environment: PKGBUILD_BUILDER_IMAGE=1' test "${PKGBUILD_BUILDER_IMAGE:-0}" = 1
    check 'config: 90-emo-native.conf' test -f /etc/makepkg.conf.d/90-emo-native.conf
fi

if [[ "$mode" == cuda ]]; then
    check 'command: nvcc' command -v nvcc >/dev/null
    check 'CUDA toolkit: version' nvcc --version >/dev/null
    check 'CUDA arch 89 compile' bash -c 'printf "__global__ void k() {}\\nint main(){return 0;}\\n" | nvcc -x cu -arch=sm_89 -c -o /tmp/emo-cuda-test.o -'
    rm -f /tmp/emo-cuda-test.o
fi
