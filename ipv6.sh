#!/usr/bin/env bash
# =============================================================================
# warp-ipv6only.sh —— 给「只有 IPv4」的 Debian/Ubuntu 服务器添加 IPv6 出网能力
#
# 效果：
#   · IPv4 → 完全直连：公网 IPv4 不变，外部 SSH / 任意端口入站访问不受影响
#   · IPv6 → 全部走 Cloudflare WARP 隧道（免费版即可，无需注册账号）
#
# 原理：
#   WARP 的 Split Tunnel（分流）默认即 Exclude（排除）模式；把整个 IPv4 空间
#   （0.0.0.0/0）加入排除列表后：IPv4 不进隧道（走物理网卡原生路由），
#   IPv6 因未被排除而继续进隧道 → 借 Cloudflare 的 IPv6 出口上网。
#
# 用法：  sudo bash warp-ipv6only.sh
# 验收：
#   warp-cli --accept-tos status     → Connected
#   curl -4 https://ip.sb            → 本机原生 IPv4
#   curl -6 https://ip.sb            → Cloudflare 段 IPv6（2a09:bac5:…）
#
# 回退 / 卸载：
#   warp-cli --accept-tos tunnel ip remove-range 0.0.0.0/0   # 取消 IPv4 排除
#   warp-cli --accept-tos disconnect                          # 断开
#   systemctl disable --now warp-svc                          # 关闭服务
#   warp-cli --accept-tos registration delete && apt remove cloudflare-warp
# =============================================================================
set -euo pipefail

W() { warp-cli --accept-tos "$@"; }   # 非交互环境：所有命令都需 --accept-tos

cyan() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

get4() { curl -4 -s --max-time 10 https://ip.sb 2>/dev/null \
      || curl -4 -s --max-time 10 https://ifconfig.co 2>/dev/null \
      || curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || true; }
get6() { curl -6 -s --max-time 15 https://ip.sb 2>/dev/null \
      || curl -6 -s --max-time 15 https://ifconfig.co 2>/dev/null \
      || curl -6 -s --max-time 15 https://ipv6.icanhazip.com 2>/dev/null || true; }

[ "$(id -u)" = 0 ] || die "需要 root 权限运行：sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "本脚本目前仅支持 Debian / Ubuntu"

# ---------- 0. 时钟保障（快照还原后时钟可能回退：先让 NTP 同步到位） ----------
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-ntp true >/dev/null 2>&1 || true
  for i in $(seq 1 10); do
    timedatectl 2>/dev/null | grep -q "synchronized: yes" && break
    sleep 2
  done
  cyan "系统时间：$(date -u '+%F %T UTC')（$(timedatectl 2>/dev/null | grep -o 'synchronized: [a-z]*' || echo '状态未知')）"
fi

# ---------- 1. 安装 Cloudflare WARP（幂等） ----------
export DEBIAN_FRONTEND=noninteractive
if ! command -v warp-cli >/dev/null 2>&1; then
  cyan "安装 Cloudflare WARP ..."
  . /etc/os-release
  CN="${VERSION_CODENAME:-bookworm}"
  apt-get update -qq || true
  apt-get install -y -qq curl gnupg >/dev/null
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CN main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt-get update -qq || true
  if ! apt-cache policy cloudflare-warp 2>/dev/null | grep -q "Candidate: [0-9]"; then
    warn "仓库无 $CN 发行版（或索引失败），回退 bookworm 仓库"
    sed -i "s#/$CN main#/ bookworm main#; s#/ $CN main#/ bookworm main#" /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq || true
  fi
  apt-get install -y -qq cloudflare-warp || die "cloudflare-warp 安装失败"
fi
command -v curl >/dev/null 2>&1 || apt-get install -y -qq curl >/dev/null
ok "warp-cli 可用：$(warp-cli --version 2>/dev/null | head -1 || echo '未知版本')"

# ---------- 2. 启动 warp-svc 服务 ----------
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
else
  pgrep -x warp-svc >/dev/null 2>&1 || setsid nohup warp-svc >/var/log/warp-svc.log 2>&1 &
fi
for i in $(seq 1 15); do W status >/dev/null 2>&1 && break; sleep 1; done
ok "warp-svc 已就绪"

# ---------- 3. 记录连接前状态 ----------
# 等待网络与 TLS 可用（时钟异常时 TLS 会短暂失败，NTP 补齐后数秒内恢复）
for i in $(seq 1 10); do
  curl -fsS --max-time 5 https://pkg.cloudflareclient.com/pubkey.gpg -o /dev/null 2>/dev/null && break
  sleep 2
done
N4_BEFORE=$(get4 | tr -d ' \r\n')
cyan "连接前原生 IPv4：${N4_BEFORE:-（获取失败）}"
if ip -6 route show default 2>/dev/null | grep -q .; then
  warn "检测到本机已有原生 IPv6 路由：配置后其流量将改走 WARP"
fi

# ---------- 4. 注册设备（幂等） ----------
if W registration show >/dev/null 2>&1; then
  ok "设备已注册（$(W registration show 2>/dev/null | grep -m1 'Account type' | tr -d '\r' || true)）"
else
  cyan "注册 WARP 设备 ..."
  W registration new >/dev/null || die "注册失败：检查到 pkg.cloudflareclient.com 与 Cloudflare API 的出网"
  ok "注册成功"
fi

# ---------- 5. 分流配置：排除整个 IPv4 空间 ----------
LIST=$(W tunnel ip list 2>/dev/null || true)
FIRST=$(printf '%s\n' "$LIST" | head -1)
printf '%s' "$FIRST" | grep -qi "exclude" \
  || die "当前非 Exclude 模式（显示：${FIRST:-空}）。请升级客户端：apt update && apt upgrade cloudflare-warp"
if printf '%s\n' "$LIST" | grep -q "0\.0\.0\.0/0"; then
  ok "已存在 0.0.0.0/0 排除项"
else
  cyan "添加 0.0.0.0/0（整个 IPv4 空间）到排除列表 ..."
  if W tunnel ip add-range 0.0.0.0/0 >/dev/null 2>&1; then
    ok "已添加 0.0.0.0/0"
  else
    warn "该客户端版本拒绝 0.0.0.0/0，回退 /1 拆分法（0.0.0.0/1 + 128.0.0.0/1）"
    W tunnel ip add-range 0.0.0.0/1 || true
    W tunnel ip add-range 128.0.0.0/1 || true
  fi
fi
W tunnel ip list 2>/dev/null | grep -qE "0\.0\.0\.0/(0|1)" || die "IPv4 排除项未生效"

# ---------- 6. 连接 ----------
cyan "连接 WARP ..."
W connect >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  W status 2>/dev/null | head -1 | grep -q "Connected" && break
  sleep 2
done
W status 2>/dev/null | head -1 | grep -q "Connected" \
  || die "连接超时：请检查本机 UDP 出站（WARP 走 UDP 2408/500/4500 或 MASQUE 443）是否被防火墙封锁"
ok "WARP 已连接"

# ---------- 7. 自检（异常时自动断开，防失联） ----------
sleep 4
N4_AFTER=$(get4 | tr -d ' \r\n')
V6=$(get6 | tr -d ' \r\n')
echo
echo "======================= 自检 ======================="
printf '  warp-cli status : %s\n' "$(W status 2>/dev/null | head -1)"
if [ -n "$N4_BEFORE" ] && [ "$N4_BEFORE" = "$N4_AFTER" ]; then
  ok "IPv4 保持原生直连：$N4_AFTER（未走 WARP）"
else
  warn "IPv4 异常（前：${N4_BEFORE:-?} 后：${N4_AFTER:-?}），自动断开以防失联"
  W disconnect >/dev/null 2>&1 || true
  die "分流未按预期工作，已回退为断开状态"
fi
if [ -z "$V6" ]; then sleep 5; V6=$(get6 | tr -d ' \r\n'); fi
if [ -n "$V6" ]; then
  ok "IPv6 出口可用：$V6（Cloudflare WARP）"
else
  W disconnect >/dev/null 2>&1 || true
  die "IPv6 出口不可用，已回退为断开状态"
fi
echo "===================================================="
echo
ok "全部完成：IPv4 原生直连 + IPv6 走 WARP 隧道"
echo "   · 重启后 warp-svc 会自动启动并恢复连接（systemd 环境实测通过）"
echo "   · 强制走 IPv6 访问：curl -6 https://ip.sb"