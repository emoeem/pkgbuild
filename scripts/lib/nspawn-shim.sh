#!/usr/bin/env bash
# systemd-nspawn 垫片:在 docker 构建容器里跑 devtools(arch-nspawn /
# makechrootpkg)时必须经过它。容器没有可用的 host machine-id/journal,
# 裸 nspawn 会在 setup_journal 里失败并把 mount-tunnel 清理错误留在日志;
# --keep-unit 避免分配 transient scope(那需要打不开的 system bus)。
# 上游 systemd 在关闭 journal 链接时会跳过 machine-id 查找,所以两个选项
# 合起来就是容器内跑 nspawn 的最小可用集。
#
# 用法:
#   source /path/to/nspawn-shim.sh
#   shim_dir="$(nspawn_shim_install "前缀名")"   # 打印 shim 目录
#   PATH="$shim_dir:$PATH"                       # arch-nspawn 按名字找 nspawn
#   退出时 rm -rf "$shim_dir"(调用方自己挂 trap)

nspawn_shim_install() {
    local dir
    dir="$(mktemp -d "${1:-/tmp/pkgbuild-nspawn-shim.XXXXXX}")" || return 1
    cat > "$dir/systemd-nspawn" <<'__NSPAWN_WRAPPER__'
#!/usr/bin/env bash
exec /usr/bin/systemd-nspawn --link-journal=no --keep-unit "$@"
__NSPAWN_WRAPPER__
    chmod 0755 "$dir/systemd-nspawn" || { rm -rf "$dir"; return 1; }
    printf '%s\n' "$dir"
}
