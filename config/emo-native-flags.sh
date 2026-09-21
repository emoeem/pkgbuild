#!/usr/bin/env bash
# Emo local-only performance profile for Ryzen 7 7735H (Zen 3 / znver3).
# Do not use this profile for redistributable binaries.
export EMO_MARCH="znver3"
export EMO_CFLAGS="-march=znver3 -mtune=znver3 -O3 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection"
export EMO_CXXFLAGS="${EMO_CFLAGS} -Wp,-D_GLIBCXX_ASSERTIONS"
export EMO_LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"
export EMO_RUSTFLAGS="-C target-cpu=znver3 -C opt-level=3"
export EMO_CMAKE_CUDA_ARCHITECTURES="89"
