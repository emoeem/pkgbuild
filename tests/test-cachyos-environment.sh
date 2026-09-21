#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-base}"

if [[ ! -f /etc/os-release ]] || ! grep -q "^ID=cachyos$" /etc/os-release; then
    echo "CachyOS environment required." >&2
    exit 1
fi

pacman-conf --repo-list | grep -Fxq cachyos-v3
pacman-conf --repo-list | grep -Fxq chaotic-aur
pacman -Qi chaotic-keyring >/dev/null
command -v pacman >/dev/null
command -v makepkg >/dev/null
command -v aria2c >/dev/null
[[ "$(uname -m)" == x86_64 ]]

command -v gcc >/dev/null
command -v g++ >/dev/null
command -v as >/dev/null
command -v ld >/dev/null
gcc -march=znver3 -mtune=znver3 -O3 -x c -c -o /tmp/emo-cflags-test.o - <<< 'int main(void){return 0;}'
rm -f /tmp/emo-cflags-test.o

if [[ "$mode" == builder ]]; then
    command -v namcap >/dev/null
    command -v yay >/dev/null
    command -v cc1obj >/dev/null || gcc -print-prog-name=cc1obj
    gcc -march=znver3 -mtune=znver3 -O3 -x objective-c -c -o /tmp/emo-objc-test.o - <<< 'int main(void){return 0;}'
    rm -f /tmp/emo-objc-test.o
    pacman-conf DisableSandboxNetwork | grep -Fxq DisableSandboxNetwork
    [[ "${PKGBUILD_BUILDER_IMAGE:-0}" == 1 ]]
    [[ -f /etc/makepkg.conf.d/90-emo-native.conf ]]
fi
