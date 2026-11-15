#!/usr/bin/env bash
# 包构建策略（packages/<dir>/.build-strategy）的唯一读取实现。
#
# 四类策略与调度语义（Phase 3，reports/pkgbuild-optimization/package-strategy-audit.md）：
#   source        从源码构建。依赖 pkgver 漂移与 SONAME 断裂都触发重建。
#   vcs           从 Git 构建（pkgver() 解析版本）。同上，另有发布闸门的
#                 VCS pkgver 例外（verify-publish-inputs.sh）。
#   binary-repack 重打包上游预编译产物。本地重建不会重新链接任何字节：
#                 依赖版本漂移与 SONAME 断裂都只报告（等上游新资产），
#                 不 dispatch 重建。
#   data          数据/规则/静态资产（arch any 语义上也不受系统 ABI 影响）。
#                 同 binary-repack：不因系统库变化重建。
#
# 消费点：check-dependency-drift.sh（版本漂移降级 NOTE）、
# check-repository-sonames.sh（SONAME 断裂降级 UPSTREAM、不进 stale/urgent）、
# dispatch-stale-rebuilds.sh（对 binary-repack/data 直接 IGNORE，防御外部
# 路径塞进来的 stale 项）。校验点：check-package-manifests.py（每包必填、
# 值合法、与 pkgver() 特征交叉验证）。
#
# 文件格式：第一个非空、非 # 开头的行是策略值；其余行是 # 注释。

build_strategy_of() { # <package-dir>; stdout = 策略值；缺失/非法返回 1 且输出空
    local file="$1/.build-strategy"
    [[ -f "$file" ]] || return 1
    local value
    value="$(awk 'NF && substr($1, 1, 1) != "#" { print; exit }' "$file")"
    case "$value" in
        source | binary-repack | vcs | data)
            printf '%s\n' "$value"
            ;;
        *)
            return 1
            ;;
    esac
}

# 0 = 该包**明确声明**了「payload 由上游提供」的策略（binary-repack / data）。
# 只认明确声明：缺失或非法的 .build-strategy 一律按可本地重建处理（fail-safe：
# 宁可多一次重建，不可漏掉一次真实修复）。三个消费点共用这一条判据，
# 不允许各自对「策略不明」做相反的假设。
build_strategy_defers_to_upstream() { # <strategy>
    case "$1" in
        binary-repack | data) return 0 ;;
        *) return 1 ;;
    esac
}
