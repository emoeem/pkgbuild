#!/usr/bin/env bash
# 让 rootful podman 容器在 eBPF 模式下也被代理
#
#   sudo ./enable-container-proxy.sh              # 自动探测/创建 podman 网桥并启用 eBPF shared 数据面
#   sudo ./enable-container-proxy.sh --disable    # 关闭 shared（回到"容器只走直连"）
#   sudo ./enable-container-proxy.sh --iface br0  # 手动指定下游接口
#
# 背景（实测结论）：
#   rootless podman 默认用 pasta，它是把容器数据包 splice 进宿主网络栈、**不创建宿主 socket**，
#   所以 eBPF 的 local cgroup 钩子看不到容器流量（容器 DNS 通、国内直连通、境外直连被墙）。
#   TUN 模式靠 auto_route 管住了转发流量，eBPF 模式要管住转发流量只能用 shared 数据面。
#
#   本脚本在 podman 网桥上开 eBPF shared（packet_rewrite），并用 rootful 容器**实测**验证；
#   任一环节失败自动回滚。rootless 容器（pasta）不走网桥，不受此影响（仍需 --network=host）。
set -Eeuo pipefail

CONF="${CONF:-/etc/sing-box/config.json}"
BIN="${BIN:-/usr/bin/sing-box}"
SERVICE="${SERVICE:-sing-box}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
BACKUP_DIR="/etc/sing-box/backups"
MODE="enable"
IFACE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable) MODE="disable"; shift ;;
    --iface)   IFACE="${2:-}"; shift 2 ;;
    *) printf 'FATAL 未知参数：%s（可用：--disable --iface <接口>）\n' "$1" >&2; exit 1 ;;
  esac
done

WORK="$(mktemp -d /tmp/container-proxy.XXXXXX)"
NEW_JSON="$WORK/new.json"
CHECK_OUT="$WORK/check.out"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：sudo $0"
[[ -f $CONF ]] || die "找不到 $CONF"
command -v python3 >/dev/null || die "需要 python3"

say "① 前置检查"
systemctl is-active --quiet "$SERVICE" || die "$SERVICE 不是 active"
INBOUND_KIND="$(python3 -c "
import json
d=json.load(open('$CONF'))
t=[i.get('type') for i in d.get('inbounds',[])]
print('ebpf' if 'ebpf' in t else ('tun' if 'tun' in t else 'other'))")"
[[ $INBOUND_KIND == "ebpf" ]] || die "当前不是 eBPF 模式（是 $INBOUND_KIND）。TUN 模式下容器本来就靠 auto_route 管着，不需要本脚本"
say "   eBPF 模式确认"

if [[ $MODE == "disable" ]]; then
  say "② 关闭 shared（容器将只走直连）"
  python3 - "$CONF" "$NEW_JSON" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
for i in cfg["inbounds"]:
    if i.get("type") == "ebpf":
        i["shared"] = {"enabled": False}
json.dump(cfg, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("   shared.enabled → false")
PY
else
  say "② 确定下游接口"
  if [[ -z $IFACE ]]; then
    IFACE="$(ip -brief link show type bridge 2>/dev/null | awk '{print $1}' |
             grep -E '^(podman|cni-podman|podman[0-9]+|cni[0-9]+)$' | head -1 || true)"
  fi
  if [[ -z $IFACE ]]; then
    warn "没找到 podman 网桥，尝试用 rootful podman 创建一个（这会拉起一个临时容器）"
    if command -v podman >/dev/null; then
      podman network create sb-container-proxy >/dev/null 2>&1 || true
      timeout 120 podman run --rm --network sb-container-proxy docker.io/library/alpine:latest \
        /bin/true >/dev/null 2>&1 || warn "创建临时容器失败"
      IFACE="$(ip -brief link show type bridge 2>/dev/null | awk '{print $1}' |
               grep -E '^(podman|cni-podman|podman[0-9]+|cni[0-9]+)$' | head -1 || true)"
    fi
  fi
  [[ -n $IFACE ]] || die "仍找不到网桥接口。请先跑一次 rootful 容器（例如 sudo podman run --rm alpine true），或用 --iface 指定"
  ip link show "$IFACE" >/dev/null 2>&1 || die "接口 $IFACE 不存在"
  FRAMING_OK="$(ip -details link show "$IFACE" 2>/dev/null | grep -c 'link/ether' || true)"
  (( FRAMING_OK > 0 )) || die "接口 $IFACE 不是以太网帧（shared packet_rewrite 需要）"
  say "   接口：$IFACE（以太网帧 ✅）"

  say "③ 生成新配置（给 ebpf 入站开启 shared）"
  python3 - "$CONF" "$NEW_JSON" "$IFACE" <<'PY'
import json, sys
conf_path, out_path, iface = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(conf_path, encoding="utf-8"))
for i in cfg["inbounds"]:
    if i.get("type") == "ebpf":
        i["shared"] = {
            "enabled": True,
            "data_plane": "packet_rewrite",
            "interface": [iface],
            "dns_mode": "hijack",
            "bypass_private_address": True,
            "ipv6": True,
        }
        print(f"   shared: enabled, packet_rewrite, interface={iface}")
json.dump(cfg, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
fi

say "④ 校验新配置"
if ! "$BIN" check -c "$NEW_JSON" > "$CHECK_OUT" 2>&1; then
  tail -6 "$CHECK_OUT" | sed 's/^/    /'
  die "新配置 check 失败，线上未做任何改动"
fi
say "   check 通过 ✅"

say "⑤ 备份 → 原子替换 → 重启"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUP_DIR/config.$STAMP.pre-container-proxy.json"
install -d -m 755 "$BACKUP_DIR"
cp -a "$CONF" "$BK" && say "   备份：$BK"
cp -a "$NEW_JSON" "$CONF.new" && chmod 644 "$CONF.new" && mv -f "$CONF.new" "$CONF"
systemctl restart "$SERVICE"
sleep 3

say "⑥ 健康检查"
fail=""
for _ in $(seq 40); do systemctl is-active --quiet "$SERVICE" && break; sleep 0.5; done
systemctl is-active --quiet "$SERVICE" || { fail="服务未 active"; journalctl -u "$SERVICE" -n 12 --no-pager | sed 's/^/    /'; }

if [[ -z $fail ]]; then
  secret="$(python3 -c "
import json
try: print((json.load(open('$CONF')).get('experimental',{}).get('clash_api',{}) or {}).get('secret',''))
except Exception: print('')")"
  st="$("$BIN" api ebpf --url "$API_URL" --secret "$secret" 2>&1 || true)"
  printf '%s' "$st" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('   ⚠️ api ebpf 无输出'); raise SystemExit
for i in d.get('inbounds',[]):
    for a in i.get('attachments',[]) or []:
        print(f\"   附件: role={a.get('role')} mechanism={a.get('mechanism')} iface={a.get('interfaceName') or '-'}\")
" 2>/dev/null || true
fi

# 宿主不设代理仍必须走代理
if [[ -z $fail ]]; then
  h="$(curl -s -m 12 https://api.ipify.org || true)"
  p="$(curl -s -m 12 -x http://127.0.0.1:7892 https://api.ipify.org || true)"
  printf '   宿主不设代理=%s / 本地代理口=%s\n' "${h:-无}" "${p:-无}"
  [[ -n $h && "$h" == "$p" ]] || fail="宿主流量不再被接管"
fi

# 关键：rootful 容器实测（用 root 的 podman，走网桥）
if [[ -z $fail && $MODE == "enable" ]]; then
  printf '   rootful 容器实测（网桥 %s）…\n' "$IFACE"
  net="$(podman network ls --format '{{.Name}}' 2>/dev/null | grep -Fx sb-container-proxy || true)"
  cnet=()
  [[ -n $net ]] && cnet=(--network "$net")
  cip="$(timeout 180 podman run --rm "${cnet[@]}" docker.io/library/alpine:latest \
        sh -c 'apk add --no-cache curl >/dev/null 2>&1; curl -4 -s -m 25 https://api.ipify.org' 2>/dev/null | tail -1 || true)"
  printf '   容器出口=%s\n' "${cip:-失败}"
  if [[ -z $cip ]]; then fail="容器仍拿不到出口（shared 未生效或容器链路不同）"
  else
    prox="$(curl -s -m 12 -x http://127.0.0.1:7892 https://api.ipify.org || true)"
    [[ "$cip" == "$prox" ]] || fail="容器出口($cip) ≠ 代理出口($prox)"
  fi
fi

if [[ -n $fail ]]; then
  warn "健康检查失败：$fail —— 正在回滚"
  cp -a "$BK" "$CONF"
  systemctl restart "$SERVICE"
  sleep 3
  systemctl is-active --quiet "$SERVICE" && warn "已回滚并重启" || warn "回滚后仍异常，请手动检查！"
  exit 1
fi

say "✅ 完成"
echo "   备份：$BK（回滚：sudo cp -a $BK $CONF && sudo systemctl restart $SERVICE）"
if [[ $MODE == "enable" ]]; then
  echo "   注意：这只覆盖**走网桥**的 rootful 容器；rootless（pasta）容器不受影响，仍需 --network=host"
fi
