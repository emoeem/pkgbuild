#!/usr/bin/env bash
# Build one PKGBUILD from a disposable CachyOS-v3 clean chroot.
set -Eeuo pipefail
source_dir="${1:?usage: build-in-clean-chroot.sh PKGBUILD_DIR OUTPUT_DIR}"
output_dir="${2:?usage: build-in-clean-chroot.sh PKGBUILD_DIR OUTPUT_DIR}"
cache_dir="${CACHE_DIR:-/cache}"
repo_dir="${LOCAL_REPO_MOUNT:-/run/pkgbuild-localrepo}"
package_name="${PACKAGE_NAME:?PACKAGE_NAME is required}"
architecture="$(uname -m)-v3"
generation="${BUILDER_GENERATION:-dev}"
builder_flavor="${PKGBUILD_CUDA_BUILDER:-0}"
[[ "$builder_flavor" == 1 ]] || builder_flavor=0
for tool in mkarchroot makechrootpkg arch-nspawn repo-add; do
    command -v "$tool" >/dev/null || { printf 'Required devtools command missing: %s\n' "$tool" >&2; exit 127; }
done
[[ -f "$source_dir/PKGBUILD" ]] || { echo "Missing PKGBUILD: $source_dir" >&2; exit 2; }
mkdir -p "$cache_dir/pacman" "$cache_dir/chroot" "$output_dir" \
    "$cache_dir/sources/$package_name" "$cache_dir/cargo" "$cache_dir/ccache"
base_config="$cache_dir/chroot/pacman-base.conf"
builder_pacman_conf="${BUILDER_PACMAN_CONF:-}"
if [[ -z "$builder_pacman_conf" ]]; then
    if [[ -f /etc/pacman.conf.pkgbuild-base ]]; then builder_pacman_conf=/etc/pacman.conf.pkgbuild-base; else builder_pacman_conf=/etc/pacman.conf; fi
fi
python3 - "$base_config" "$builder_pacman_conf" <<'PY'
from pathlib import Path
import re, sys
source = Path(sys.argv[2]).read_text(encoding='utf-8')
sections = re.split(r'(?m)(?=^\[[^\]]+\]\s*$)', source)
options = [s for s in sections if not re.match(r'\s*\[[^\]]+\]', s)]
by_name, other = {}, []
for section in sections:
    m = re.match(r'\s*\[([^\]]+)\]', section)
    if not m: continue
    name = m.group(1)
    if name in {'options', 'cachyos-v3', 'cachyos-extra-v3', 'cachyos-core-v3', 'cachyos'}: by_name[name] = section
    else: other.append(section)
order = ['cachyos-v3', 'cachyos-extra-v3', 'cachyos-core-v3', 'cachyos']
missing = [name for name in order if name not in by_name]
if missing: raise SystemExit('Builder pacman.conf missing CachyOS repos: ' + ', '.join(missing))
if 'options' not in by_name: raise SystemExit('Builder pacman.conf missing [options] section')
other = [section for section in other if not re.match(r'\s*\[(?:emoeem|emoeem-staging)\]', section)]
Path(sys.argv[1]).write_text(''.join(options + [by_name['options']] + [by_name[n] for n in order] + other), encoding='utf-8')
PY
# Install the wrapper before mkarchroot: baseline creation itself invokes
# arch-nspawn for package hooks, so creating it only before makechrootpkg is too late.
# arch-nspawn invokes systemd-nspawn by name through PATH. Docker builders do
# not have a host systemd machine-id/journal to link; systemd-nspawn otherwise
# fails in setup_journal and leaves its mount-tunnel cleanup error in the log.
nspawn_wrapper_dir="$(mktemp -d "/tmp/pkgbuild-nspawn-${package_name}.XXXXXX")"
cat > "$nspawn_wrapper_dir/systemd-nspawn" <<'__NSPAWN_WRAPPER__'
#!/usr/bin/env bash
exec /usr/bin/systemd-nspawn --link-journal=no "$@"
__NSPAWN_WRAPPER__
chmod 0755 "$nspawn_wrapper_dir/systemd-nspawn"
cleanup_paths=("$nspawn_wrapper_dir")
cleanup() { rm -rf -- "${cleanup_paths[@]}"; }
trap cleanup EXIT INT TERM
export PATH="$nspawn_wrapper_dir:$PATH"
fingerprint="$( { cat "$base_config"; printf '\n%s\n%s\nflavor=%s\n' "$generation" "$architecture" "$builder_flavor"; sha256sum /etc/makepkg.conf /etc/makepkg.conf.d/90-emo-native.conf "$0" 2>/dev/null || true; } | sha256sum | cut -c1-20)"
baseline_name="baseline-${generation}-${architecture}-${fingerprint}"
cache_fs="$(stat -f -c %T "$cache_dir/chroot")"
if [[ "$cache_fs" == btrfs ]]; then
    # devtools automatically attempts btrfs subvolumes when the chroot root is
    # on btrfs. Keep the requested ordinary-copy strategy by extracting the
    # cached baseline archive into the container's overlay /tmp instead.
    runtime_root="/tmp/pkgbuild-chroot-${fingerprint}"
    baseline="$runtime_root/$baseline_name"
    baseline_archive="$cache_dir/chroot/${baseline_name}.tar.zst"
    mkdir -p "$runtime_root"
    if [[ -s "$baseline_archive" ]]; then
        mkdir -p "$baseline"
        tar --zstd -xf "$baseline_archive" -C "$baseline"
    else
        mkdir -p "$baseline"
        echo "Creating clean CachyOS-v3 chroot baseline $fingerprint (btrfs cache uses an archive)"
        base_packages=(base-devel gcc-objc ccache)
        if [[ "$builder_flavor" == 1 ]]; then base_packages+=(cuda gcc15); fi
        mkarchroot -C "$base_config" -c "$cache_dir/pacman" "$baseline/root" "${base_packages[@]}"
        install -d "$baseline/root/etc/makepkg.conf.d"
        [[ ! -f /etc/makepkg.conf.d/90-emo-native.conf ]] || install -m0644 /etc/makepkg.conf.d/90-emo-native.conf "$baseline/root/etc/makepkg.conf.d/90-emo-native.conf"
        cat >> "$baseline/root/etc/makepkg.conf.d/90-emo-native.conf" <<'__CACHE_ENV__'
export CARGO_HOME=/cache/cargo
export CCACHE_DIR=/cache/ccache
export CCACHE_MAXSIZE=2G
export PATH=/usr/lib/ccache/bin:$PATH
__CACHE_ENV__
        printf '%s\n' "$fingerprint" > "$baseline/FINGERPRINT"
        tar --zstd -cf "${baseline_archive}.tmp" -C "$baseline" root FINGERPRINT
        mv -f "${baseline_archive}.tmp" "$baseline_archive"
    fi
    baseline_root="$baseline/root"
    work_parent="$runtime_root"
else
    baseline="$cache_dir/chroot/$baseline_name"
    mkdir -p "$baseline"
    if [[ ! -x "$baseline/root/usr/bin/bash" ]]; then
        rm -rf "$baseline/root"
        echo "Creating clean CachyOS-v3 chroot baseline $fingerprint"
        base_packages=(base-devel gcc-objc ccache)
        if [[ "$builder_flavor" == 1 ]]; then base_packages+=(cuda gcc15); fi
        mkarchroot -C "$base_config" -c "$cache_dir/pacman" "$baseline/root" "${base_packages[@]}"
        install -d "$baseline/root/etc/makepkg.conf.d"
        [[ ! -f /etc/makepkg.conf.d/90-emo-native.conf ]] || install -m0644 /etc/makepkg.conf.d/90-emo-native.conf "$baseline/root/etc/makepkg.conf.d/90-emo-native.conf"
        cat >> "$baseline/root/etc/makepkg.conf.d/90-emo-native.conf" <<'__CACHE_ENV__'
export CARGO_HOME=/cache/cargo
export CCACHE_DIR=/cache/ccache
export CCACHE_MAXSIZE=2G
export PATH=/usr/lib/ccache/bin:$PATH
__CACHE_ENV__
        printf '%s\n' "$fingerprint" > "$baseline/FINGERPRINT"
    fi
    baseline_root="$baseline/root"
    work_parent="$cache_dir/chroot"
fi
work_root="$(mktemp -d "$work_parent/work-${package_name}.XXXXXX")"
cleanup_paths+=("$work_root")
mkdir -p "$work_root/root"
cp --reflink=auto -a "$baseline_root/." "$work_root/root/"
sed -i '/^\[options\]$/a CacheDir = /cache/pacman' "$work_root/root/etc/pacman.conf"
if [[ -d "$repo_dir" ]] && compgen -G "$repo_dir/*.db*" >/dev/null; then
    # The same-run repository must outrank upstream repositories; otherwise a
    # matching package from chaotic-aur could shadow a freshly built DAG input.
    python3 - "$work_root/root/etc/pacman.conf" <<'PYCONF'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
match = re.search(r'(?m)^\[cachyos-v3\]\s*$', text)
if not match:
    raise SystemExit('Clean chroot config lost the cachyos-v3 repository')
staging = '[emoeem]\nSigLevel = Never\nServer = file:///run/pkgbuild-localrepo\n\n'
path.write_text(text[:match.start()] + staging + text[match.start():], encoding='utf-8')
PYCONF
fi
cache_mounts=()
for path in "$cache_dir/pacman" "${cache_dir}/sources/${package_name}" "$cache_dir/cargo" "$cache_dir/ccache"; do
    [[ -d "$path" ]] || continue
    mkdir -p "$work_root/root$path"
    cache_mounts+=( -d "$path" )
done
if [[ -d "$repo_dir" ]] && compgen -G "$repo_dir/*.db*" >/dev/null; then
    mkdir -p "$work_root/root/run/pkgbuild-localrepo"
fi
export MAKEFLAGS="-j${MAKE_JOBS:-$(nproc)}" NPROC="${MAKE_JOBS:-$(nproc)}"
export CFLAGS="${EMO_CFLAGS:-}" CXXFLAGS="${EMO_CXXFLAGS:-${EMO_CFLAGS:-}}" LDFLAGS="${EMO_LDFLAGS:-}" RUSTFLAGS="${EMO_RUSTFLAGS:-}"
export CMAKE_BUILD_PARALLEL_LEVEL="${MAKE_JOBS:-$(nproc)}" SRCDEST="${cache_dir}/sources/${package_name}" CARGO_HOME="$cache_dir/cargo" CCACHE_DIR="$cache_dir/ccache" CCACHE_MAXSIZE=2G PATH="$nspawn_wrapper_dir:/usr/lib/ccache/bin:$PATH"
mkdir -p "$SRCDEST" "$cache_dir/cargo" "$cache_dir/ccache"
printf 'Clean-chroot build: package=%s baseline=%s repo=%s\n' "$package_name" "$fingerprint" "$repo_dir"
# Update this package's disposable work copy before invoking makechrootpkg.
# This is intentionally not an update of the reusable baseline: every package
# gets its own current repository state, and no work-root state is cached.
if [[ -d "$repo_dir" ]] && compgen -G "$repo_dir/*.db*" >/dev/null; then
    arch-nspawn -c "$cache_dir/pacman" "$work_root/root" --bind="$repo_dir" pacman -Syu --noconfirm
else
    arch-nspawn -c "$cache_dir/pacman" "$work_root/root" pacman -Syu --noconfirm
fi
cd "$source_dir"
args=(makechrootpkg -c -u -r "$work_root" -l "pkgbuild-${package_name}")
[[ ! -d "$repo_dir" ]] || args+=( -D "$repo_dir" )
for mount in "${cache_mounts[@]}"; do args+=("$mount"); done
if [[ -f "$source_dir/.skip-check" ]]; then
    echo "check() explicitly skipped by $source_dir/.skip-check"
    "${args[@]}" -- --nocheck --cleanbuild --noconfirm
else
    "${args[@]}" -- --cleanbuild --noconfirm
fi
mapfile -d '' packages < <(find "$source_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0 | sort -z)
((${#packages[@]} > 0)) || { echo "Clean chroot produced no package artifacts for $package_name" >&2; exit 1; }
for package in "${packages[@]}"; do cp -f -- "$package" "$output_dir/"; done
printf 'Clean-chroot build produced %d package artifact(s).\n' "${#packages[@]}"
