#!/bin/bash
# ==============================================================================
#  port_limiter v2.0.0  —— 端口峰值带宽限制管理器
# ------------------------------------------------------------------------------
#  设计目标
#    1) 只限制「端口峰值带宽」：不限制连接数、不做 per-IP 限制
#    2) 一次覆盖 TCP + UDP、IPv4 + IPv6（inet 表天然双栈，无需分写两套）
#    3) 跨发行版：Debian 12+ / Ubuntu 22.04+ / RHEL9 系 / Alpine 等，有 nftables 即可
#    4) 规则原子下发：生成规则集 → nft -c 语法校验 → nft -f 单事务提交；
#       任一步失败，现网规则原封不动（v1 是"逐条 nft add"，中间有空窗和半成品）
#    5) 可观测：每条限速规则都带 counter，能查到「每个端口丢了多少包」
#    6) 能力自检：按主机 nft/内核能力自动选择实现，老内核自动降级，不写死行为
#
#  规则文件格式（与 v1 完全兼容）：  id|类型|端口|Mbps|备注
#    类型 1：离散端口，各自独立限速    例：80,443,8080
#    类型 2：连续端口，各自独立限速    例：40001-41111
#    类型 3：连续端口，共享总额度      例：40001-40100
#
#  用法：
#    bash port_limiter.sh              # 交互式菜单
#    bash port_limiter.sh apply boot   # 开机调用（服务单元使用）
#    bash port_limiter.sh stop         # 清除全部限速
#    bash port_limiter.sh check        # 只生成 + 语法校验，不提交（干跑）
#    bash port_limiter.sh stats [秒]   # 统计：每端口被限速丢弃的流量
#    bash port_limiter.sh caps         # 本机能力自检
#
#  可调环境变量：
#    BURST_MS=250            突发额度 ≈ 多少毫秒的数据量（v1 固定为 2000ms 两倍速率）
#    SET_TIMEOUT=1h          动态集合元素老化时间，0 = 不老化
#    MAX_EXPLICIT_PORTS=256  降级为逐端口显式规则时的端口数上限
#    INCLUDE_FORWARD=auto    是否给 forward 链也加规则（auto = 本机开启转发时才加）
#    TABLE=port_limiter      规则表名（改掉即进入测试模式，不动生产表）
#    WORK_DIR=/etc/port_limiter
#
#  与 v1 的行为差异（升级须知）：
#    1) burst 由「2 秒数据量」改为「250ms 数据量」，峰值控制更紧；设 BURST_MS=2000 可还原 v1 手感
#    2) 类型 1（离散端口）由「多口共享一个桶」修正为「每口独立桶」
#    3) UDP 由「整段共享一桶、无 burst」修正为「按端口独立 + 带 burst」
#    4) 默认只在本机开启转发时生成 forward 链规则（v1 固定生成，非路由器上是死规则）
# ==============================================================================
set -uo pipefail

VERSION="2.0.0"
# 路径与表名都支持环境变量覆盖，便于在独立测试表上验证（生产默认值不变）
WORK_DIR="${WORK_DIR:-/etc/port_limiter}"
RULE_FILE="${RULE_FILE:-$WORK_DIR/rules.conf}"
SCRIPT_PATH="${SCRIPT_PATH:-$WORK_DIR/port_limiter.sh}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/port-limiter.service}"
TABLE="${TABLE:-port_limiter}"

# 可调参数（可用环境变量覆盖）
MAX_EXPLICIT_PORTS="${MAX_EXPLICIT_PORTS:-256}"   # 降级为逐端口显式规则的端口上限
SET_TIMEOUT="${SET_TIMEOUT:-1h}"                  # 动态集合元素老化时间（0 = 不老化）
BURST_MS="${BURST_MS:-250}"                       # 突发额度 ≈ 多少毫秒的数据量
INCLUDE_FORWARD="${INCLUDE_FORWARD:-auto}"        # auto|yes|no：是否给 forward 链也加规则

# ---- 能力开关：probe_caps() 运行时探测填充，决定实现方式 ----
CAP_INET=0            # 支持 inet 表（双栈）
CAP_DYNSET=0          # 支持 flags dynamic 动态集合
CAP_ELEM_LIMIT=0      # 支持「集合元素内嵌 limit」（v1 依赖此特性）
CAP_ELEM_COUNTER=0    # 支持「元素内嵌 counter」（可统计每端口丢包）
CAP_SET_TIMEOUT=0     # 集合元素可带 timeout 老化
IMPL=""               # dynset | explicit  —— 最终选用的实现

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ------------------------------------------------------------------ 基础工具
info() { echo -e "${BLUE}$*${NC}"; }
ok()   { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}警告：$*${NC}"; }
err()  { echo -e "${RED}错误：$*${NC}" >&2; }

require_root() {
    [ "$(id -u)" -eq 0 ] || { err "请用 root 运行（当前 uid=$(id -u)）"; exit 1; }
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 差异容错：GNU date 与 busybox date 都能拿到秒级时间戳
now() { date +%s; }

# ------------------------------------------------------------------ 平台适配
detect_pkg_mgr() {
    local m
    for m in apt-get dnf yum zypper apk pacman; do
        if need_cmd "$m"; then echo "$m"; return 0; fi
    done
    echo ""; return 1
}

# 缺少 nft 时按发行版安装；boot 模式（开机）下不联网安装，直接失败退出
ensure_nft() {
    need_cmd nft && return 0
    local mode="${1:-interactive}"
    if [ "$mode" = "boot" ]; then
        err "开机应用时未找到 nft 命令，跳过（请先手动安装 nftables）"
        return 1
    fi
    local pm; pm="$(detect_pkg_mgr)" || true
    [ -n "$pm" ] || { err "未检测到包管理器，请手动安装 nftables"; return 1; }
    info "未检测到 nftables，尝试用 $pm 安装..."
    case "$pm" in
        apt-get) apt-get update -qq && apt-get install -y -qq nftables ;;
        dnf)     dnf install -y nftables ;;
        yum)     yum install -y nftables ;;
        zypper)  zypper --non-interactive install nftables ;;
        apk)     apk add --no-cache nftables ;;
        pacman)  pacman -Sy --noconfirm nftables ;;
    esac
    need_cmd nft || { err "nftables 安装失败，请手动处理后重试"; return 1; }
    ok "nftables 安装完成：$(nft --version 2>/dev/null | head -1)"
}

has_systemd() { need_cmd systemctl && [ -d /run/systemd/system ]; }

# ------------------------------------------------------------------ 能力探测
# 用「非挂钩的普通链」做真机探测：规则会真正提交给内核（能测出内核级 EOPNOTSUPP），
# 但普通链没有任何数据包经过，因此对现网零影响；探完立即删除。
probe_caps() {
    local t="_pl_probe" rc=0
    nft delete table inet "$t" 2>/dev/null
    if nft add table inet "$t" 2>/dev/null; then CAP_INET=1; else
        err "本机内核不支持 nftables inet 表，无法做双栈统一限速（内核过旧）"
        return 1
    fi
    nft add chain inet "$t" c >/dev/null 2>&1 || { nft delete table inet "$t" 2>/dev/null; return 1; }

    # 1) 动态集合 + 元素内嵌 limit（v1 依赖的特性）
    if nft add set inet "$t" s1 '{ type inet_service; size 1024; flags dynamic; }' >/dev/null 2>&1; then
        CAP_DYNSET=1
        # 1a) 优先探测「limit + counter」：可以拿到每端口丢包统计
        if nft add rule inet "$t" c tcp dport 40000-40010 update @s1 \
             '{ tcp dport limit rate over 3750 kbytes/second burst 900 kbytes counter }' >/dev/null 2>&1; then
            CAP_ELEM_LIMIT=1; CAP_ELEM_COUNTER=1
        elif nft add rule inet "$t" c tcp dport 40000-40010 update @s1 \
             '{ tcp dport limit rate over 3750 kbytes/second burst 900 kbytes }' >/dev/null 2>&1; then
            # 1b) 老版本不支持元素内 counter：仍可限速，只是没有每端口丢包统计
            CAP_ELEM_LIMIT=1; CAP_ELEM_COUNTER=0
        fi
    fi
    # 2) 动态集合 + timeout 老化（长跑代理用，避免元素无限堆积）
    if [ "$CAP_DYNSET" = "1" ] && [ -n "$SET_TIMEOUT" ] && [ "$SET_TIMEOUT" != "0" ]; then
        if nft add set inet "$t" s2 "{ type inet_service; size 1024; flags dynamic,timeout; timeout $SET_TIMEOUT; }" >/dev/null 2>&1; then
            CAP_SET_TIMEOUT=1
        fi
    fi
    # 3) 规则级 limit（所有版本都支持，作为降级兜底）
    nft add rule inet "$t" c tcp dport 40000-40010 \
        limit rate over 3750 kbytes/second burst 900 kbytes counter drop >/dev/null 2>&1 \
        || { err "连最基础的规则级 limit 都不支持，请升级 nftables"; rc=1; }

    nft delete table inet "$t" 2>/dev/null
    [ "$rc" -eq 0 ] || return 1

    if [ "$CAP_DYNSET" = "1" ] && [ "$CAP_ELEM_LIMIT" = "1" ]; then
        IMPL="dynset"      # 首选：单规则 + 每端口独立令牌桶，O(1)，规则数极少
    else
        IMPL="explicit"    # 兜底：逐端口显式规则（受 MAX_EXPLICIT_PORTS 限制）
    fi
    return 0
}

print_caps() {
    echo "  发行版     : $( ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" ) || echo unknown )"
    echo "  内核       : $(uname -r)"
    echo "  nftables   : $(nft --version 2>/dev/null | head -1)"
    echo "  inet 表    : $([ "$CAP_INET" = 1 ] && echo 支持 || echo '不支持')"
    echo "  动态集合   : $([ "$CAP_DYNSET" = 1 ] && echo 支持 || echo '不支持')"
    echo "  元素级限速 : $([ "$CAP_ELEM_LIMIT" = 1 ] && echo 支持 || echo '不支持')"
    echo "  每端口丢包统计 : $([ "$CAP_ELEM_COUNTER" = 1 ] && echo 支持 || echo '不支持（改用规则级统计）')"
    echo "  元素老化   : $([ "$CAP_SET_TIMEOUT" = 1 ] && echo "支持($SET_TIMEOUT)" || echo '不支持')"
    echo "  init 系统  : $(has_systemd && echo systemd || echo '非 systemd（用 rc.local/local.d 兜底）')"
    echo "  选用实现   : $IMPL"
}

# ------------------------------------------------------------------ 端口解析
# 输入 "80,443,40001-40010" → 逐行输出端口号；非法输入返回非零
expand_ports() {
    local list part a b p
    list="$(echo "$1" | tr -d ' \t' | tr ',' '\n')"
    while IFS= read -r part; do
        [ -n "$part" ] || continue
        case "$part" in
            *-*)
                a="${part%%-*}"; b="${part##*-}"
                case "$a" in ''|*[!0-9]*) return 1;; esac
                case "$b" in ''|*[!0-9]*) return 1;; esac
                if [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$a" -gt "$b" ]; then return 1; fi
                p="$a"
                while [ "$p" -le "$b" ]; do echo "$p"; p=$((p + 1)); done
                ;;
            *)
                case "$part" in *[!0-9]*) return 1;; esac
                if [ "$part" -lt 1 ] || [ "$part" -gt 65535 ]; then return 1; fi
                echo "$part"
                ;;
        esac
    done <<EOF
$list
EOF
    return 0
}

norm_ports() { echo "$1" | tr -d ' \t'; }
count_ports() { expand_ports "$1" 2>/dev/null | grep -c . ; }
validate_ports() { expand_ports "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 速率换算
mbps_to_kb() { echo $(( $1 * 125 )); }                       # Mbps → KB/s（nft 按 1024 计）
calc_burst() {                                               # burst ≈ BURST_MS 毫秒的数据量
    local kb="$1" b
    b=$(( kb * BURST_MS / 1000 ))
    [ "$b" -lt 1 ] && b=1
    echo "$b"
}

# ------------------------------------------------------------------ 规则集生成
set_decl() {
    local name="$1"
    if [ "$CAP_SET_TIMEOUT" = "1" ]; then
        printf '\tset %s {\n\t\ttype inet_service\n\t\tsize 65535\n\t\tflags dynamic,timeout\n\t\ttimeout %s\n\t}\n' "$name" "$SET_TIMEOUT"
    else
        printf '\tset %s {\n\t\ttype inet_service\n\t\tsize 65535\n\t\tflags dynamic\n\t}\n' "$name"
    fi
}

# 单条规则文本：$1=proto $2=dport/sport $3=匹配值 $4=KB/s $5=burst $6=集合名(空=共享桶)
one_rule() {
    local proto="$1" kw="$2" match="$3" kb="$4" burst="$5" setn="${6:-}"
    local cnt=""
    # 元素内嵌 counter：能统计「每个端口被丢了多少包」，老版本自动省略
    [ -n "$setn" ] && [ "${CAP_ELEM_COUNTER:-0}" = "1" ] && cnt=" counter"
    if [ -n "$setn" ]; then
        # 注意：集合元素的键表达式必须是完整的键（tcp dport / udp sport …），
        # 只写 dport 会被 nft 当成服务名去解析而报错
        printf '%s %s %s update @%s { %s %s limit rate over %s kbytes/second burst %s kbytes%s } drop\n' \
            "$proto" "$kw" "$match" "$setn" "$proto" "$kw" "$kb" "$burst" "$cnt"
    else
        printf '%s %s %s limit rate over %s kbytes/second burst %s kbytes counter drop\n' \
            "$proto" "$kw" "$match" "$kb" "$burst"
    fi
}

# 逐端口显式规则（降级实现）：为每个端口各生成 4 条独立规则 → 桶天然独立
emit_explicit() {
    local ports="$1" kb="$2" burst="$3" p
    for p in $(expand_ports "$ports"); do
        printf '\t\t%s\n' "$(one_rule tcp dport "$p" "$kb" "$burst")"
        printf '\t\t%s\n' "$(one_rule udp dport "$p" "$kb" "$burst")"
    done
}

emit_explicit_out() {
    local ports="$1" kb="$2" burst="$3" p
    for p in $(expand_ports "$ports"); do
        printf '\t\t%s\n' "$(one_rule tcp sport "$p" "$kb" "$burst")"
        printf '\t\t%s\n' "$(one_rule udp sport "$p" "$kb" "$burst")"
    done
}

forward_enabled() {
    case "${INCLUDE_FORWARD:-auto}" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ] && return 0
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)" = "1" ] && return 0
    return 1
}

# 生成完整规则集（stdout）；失败返回非零并给出原因
gen_ruleset() {
    local id type ports mbps desc kb burst n
    local match
    # 先做一遍输入体检，任何非法行都直接报错，避免下发半套规则
    if [ ! -s "$RULE_FILE" ]; then
        echo "# 规则文件为空：仅清空限速表" >&2
    fi
    while IFS='|' read -r id type ports mbps desc; do
        [ -n "${id:-}" ] || continue
        case "$type" in 1|2|3) ;; *) warn "跳过规则 $id：类型 $type 非法" >&2; continue;; esac
        if ! validate_ports "$ports"; then
            warn "跳过规则 $id：端口表达式非法 → $ports" >&2; continue
        fi
        case "$mbps" in ''|*[!0-9]*) warn "跳过规则 $id：带宽必须是整数 Mbps → $mbps" >&2; continue;; esac
        [ "$mbps" -ge 1 ] || { warn "跳过规则 $id：带宽必须 ≥1 Mbps" >&2; continue; }
    done < "$RULE_FILE"

    # ---------- 表头 ----------
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
        echo "flush table inet $TABLE"      # 与后续内容同一事务 → 无放行空窗
    fi
    echo "table inet $TABLE {"

    # ---------- 集合（dynset 实现需要，必须先声明后使用）----------
    if [ "$IMPL" = "dynset" ]; then
        while IFS='|' read -r id type ports mbps desc; do
            [ -n "${id:-}" ] || continue
            case "$type" in 1|2) ;; *) continue;; esac
            validate_ports "$ports" || continue
            echo "	# ---- 规则 $id 的令牌桶集合（每端口一个，双向分开）----"
            set_decl "pl_${id}_tcp_in"
            set_decl "pl_${id}_tcp_out"
            set_decl "pl_${id}_udp_in"
            set_decl "pl_${id}_udp_out"
        done < "$RULE_FILE"
    fi

    # ---------- 链 ----------
    echo "	chain input {"
    echo "		type filter hook input priority filter; policy accept;"
    echo "		# 控制面小包放行：纯 ACK/握手包不参与限速，避免把 TCP 掐死"
    echo "		tcp flags & (fin|syn|rst|ack) == ack meta length < 100 accept"
    gen_in_rules "input"
    echo "	}"
    echo "	chain output {"
    echo "		type filter hook output priority filter; policy accept;"
    echo "		tcp flags & (fin|syn|rst|ack) == ack meta length < 100 accept"
    gen_in_rules "output"
    echo "	}"
    if forward_enabled; then
        echo "	chain forward {"
        echo "		type filter hook forward priority filter; policy accept;"
        echo "		tcp flags & (fin|syn|rst|ack) == ack meta length < 100 accept"
        gen_in_rules "forward"
        echo "	}"
    fi
    echo "}"
    return 0
}

# 生成某条链内的规则；$1 = input|output|forward
gen_in_rules() {
    local chain="$1" id type ports mbps desc kb burst match n
    while IFS='|' read -r id type ports mbps desc; do
        [ -n "${id:-}" ] || continue
        case "$type" in 1|2|3) ;; *) continue;; esac
        validate_ports "$ports" || continue
        case "$mbps" in ''|*[!0-9]*) continue;; esac
        kb="$(mbps_to_kb "$mbps")"
        burst="$(calc_burst "$kb")"
        match="$(norm_ports "$ports")"
        echo "		# ---- 规则 $id（类型$type / ${mbps}Mbps / ${desc:-无}）----"

        if [ "$type" = "3" ]; then
            # 共享额度：整个端口段一个桶
            [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule tcp dport "$match" "$kb" "$burst")"
            [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule udp dport "$match" "$kb" "$burst")"
            [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule tcp sport "$match" "$kb" "$burst")"
            [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule udp sport "$match" "$kb" "$burst")"
            continue
        fi

        # 类型 1/2：每端口独立令牌桶
        if [ "$IMPL" = "dynset" ]; then
            [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule tcp dport "$match" "$kb" "$burst" "pl_${id}_tcp_in")"
            [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule udp dport "$match" "$kb" "$burst" "pl_${id}_udp_in")"
            [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule tcp sport "$match" "$kb" "$burst" "pl_${id}_tcp_out")"
            [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule udp sport "$match" "$kb" "$burst" "pl_${id}_udp_out")"
        else
            n=$(count_ports "$ports")
            if [ "$n" -gt "$MAX_EXPLICIT_PORTS" ]; then
                warn "规则 $id 端口数 $n 超过 $MAX_EXPLICIT_PORTS，本机不支持动态集合，退化为「整段共享额度」" >&2
                [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule tcp dport "$match" "$kb" "$burst")"
                [ "$chain" != "output" ] && printf '\t\t%s\n' "$(one_rule udp dport "$match" "$kb" "$burst")"
                [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule tcp sport "$match" "$kb" "$burst")"
                [ "$chain" != "input"  ] && printf '\t\t%s\n' "$(one_rule udp sport "$match" "$kb" "$burst")"
            else
                [ "$chain" != "output" ] && emit_explicit "$ports" "$kb" "$burst"
                [ "$chain" != "input"  ] && emit_explicit_out "$ports" "$kb" "$burst"
            fi
        fi
    done < "$RULE_FILE"
    return 0
}

# 环境变量把表名改掉时，明确提示当前处于测试模式，避免误操作生产表
warn_if_test_mode() {
    [ "${TABLE:-port_limiter}" = "port_limiter" ] || \
        warn "测试模式：本次只操作表 inet $TABLE（生产表 port_limiter 不受影响）"
}

# ------------------------------------------------------------------ 应用 / 停止
apply_rules() {
    local f errf
    warn_if_test_mode
    f="$(mktemp "${TMPDIR:-/tmp}/pl_rules.XXXXXX" 2>/dev/null)" || { err "无法创建临时文件"; return 1; }
    errf="$(mktemp "${TMPDIR:-/tmp}/pl_err.XXXXXX" 2>/dev/null)" || errf=/dev/null

    if ! gen_ruleset >"$f" 2>/tmp/pl_gen_err; then
        err "规则生成失败，现网规则未做任何改动"
        sed 's/^/    /' /tmp/pl_gen_err 2>/dev/null
        rm -f "$f" "$errf"; return 1
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -s /tmp/pl_gen_err ]; then warn "生成过程中的提示："; sed 's/^/    /' /tmp/pl_gen_err; fi
        info "===== 干跑（check）：以下规则集只做校验，不会提交 ====="
        cat "$f"
        echo
        if nft -c -f "$f" >"$errf" 2>&1; then
            ok "语法校验通过（本机实现：$IMPL）"
        else
            err "语法校验失败："; sed 's/^/    /' "$errf"
        fi
        rm -f "$f" "$errf"; return 0
    fi

    # 提交前先校验：语法/语义有问题的规则绝不会污染现网
    if ! nft -c -f "$f" >"$errf" 2>&1; then
        err "规则语法校验失败，现网规则保持原样："
        sed 's/^/    /' "$errf"
        rm -f "$f" "$errf"; return 1
    fi
    # 单事务提交：要么整套生效，要么完全不变
    if ! nft -f "$f" >"$errf" 2>&1; then
        err "规则提交失败，现网规则保持原样："
        sed 's/^/    /' "$errf"
        rm -f "$f" "$errf"; return 1
    fi
    rm -f "$f" "$errf"
    ok "限速规则已生效（原子下发，实现方式：$IMPL）"
    return 0
}

stop_rules() {
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
        if nft delete table inet "$TABLE" 2>/dev/null; then
            ok "已清除全部限速规则（流量恢复不受限）"
        else
            err "清除失败，请手动检查：nft list table inet $TABLE"
            return 1
        fi
    else
        warn "当前没有生效的限速表"
    fi
    return 0
}

# ------------------------------------------------------------------ 统计
list_sets() {
    nft list table inet "$TABLE" 2>/dev/null | sed -n 's/^	set \([A-Za-z0-9_]*\).*/\1/p'
}

# 元素级计数器（每端口被丢弃的包/字节）——dynset 实现
elem_counters() {
    local setname dir
    for setname in $(list_sets); do
        case "$setname" in
            *_in)  dir=in ;;
            *_out) dir=out ;;
            *) continue ;;
        esac
        nft list set inet "$TABLE" "$setname" 2>/dev/null \
        | tr -d '\n\t' | sed 's/},/}\n/g' | tr ',' '\n' \
        | awk -v d="$dir" '
            {
              if (match($0, /[0-9]+ limit rate/)) {
                  port = substr($0, RSTART, RLENGTH); gsub(/ limit rate/, "", port)
                  if (match($0, /counter packets [0-9]+/)) p = substr($0, RSTART+16, RLENGTH-16); else p = 0
                  if (match($0, /bytes [0-9]+/)) b = substr($0, RSTART+6, RLENGTH-6); else b = 0
                  print d"-端口-"port, p, b
              }
            }'
    done
}

# 规则级计数器（整条规则匹配到的被丢弃流量）——显式/共享实现
rule_counters() {
    nft -a list table inet "$TABLE" 2>/dev/null | tr '\t' ' ' | grep 'counter packets' | grep -v 'update @' \
    | awk '
        {
          label = $1" "$2" "$3
          if (match($0, /counter packets [0-9]+/)) p = substr($0, RSTART+16, RLENGTH-16); else p = 0
          if (match($0, /bytes [0-9]+/)) b = substr($0, RSTART+6, RLENGTH-6); else b = 0
          print "规则-"label, p, b
        }'
}

show_stats() {
    local d="${1:-10}" f1 f2 total
    f1="$(mktemp)"; f2="$(mktemp)"
    { elem_counters; rule_counters; } | sort > "$f1"
    info "采样 ${d} 秒（只统计「被限速丢弃」的流量；未被限速的端口不会出现）..."
    sleep "$d"
    { elem_counters; rule_counters; } | sort > "$f2"

    total=$(awk '
        NR==FNR { p[$1]=$2; b[$1]=$3; next }
        { k=$1; dp=$2-p[k]; db=$3-b[k]; if (dp<0) dp=0; if (db<0) db=0; t+=dp }
        END { print t+0 }' "$f1" "$f2")

    awk -v d="$d" '
        NR==FNR { p[$1]=$2; b[$1]=$3; next }
        {
          k=$1; dp=$2-p[k]; db=$3-b[k]; if (dp<0) dp=0; if (db<0) db=0
          if (dp>0 || db>0) printf "%-26s 丢弃速率 %9.2f Mbit/s   丢弃 %8.0f 包/秒\n", k, db*8/1000000/d, dp/d
        }' "$f1" "$f2" | sort -k3 -nr | head -25

    echo
    if [ "${total:-0}" = "0" ]; then
        ok "本次采样窗口内没有任何端口触顶 → 限速未丢弃任何包"
    else
        warn "检测到正在被限速丢弃的流量：合计 ${total} 个包（说明有端口达到了峰值上限）"
    fi
    rm -f "$f1" "$f2"
}

# ------------------------------------------------------------------ 服务 / 自启
deploy_service() {
    if has_systemd; then
        [ -f "$SERVICE_FILE" ] && return 0
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Port peak bandwidth limiter (port_limiter v$VERSION)
# 排在发行版自带 nftables.service 之后，避免被它的 flush ruleset 清掉
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH apply boot
ExecStop=$SCRIPT_PATH stop

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null
    fi
}

enable_autostart() {
    if has_systemd; then
        deploy_service
        systemctl enable port-limiter.service >/dev/null 2>&1 && ok "已设置开机自启（systemd）" \
            || { err "systemd 启用失败"; return 1; }
        return 0
    fi
    # 非 systemd 兜底：Alpine/OpenRC 用 /etc/local.d，其它用 /etc/rc.local
    if [ -d /etc/local.d ]; then
        printf '#!/bin/sh\n%s apply boot\n' "$SCRIPT_PATH" > /etc/local.d/port_limiter.start
        chmod +x /etc/local.d/port_limiter.start
        rc-update add local default >/dev/null 2>&1
        ok "已设置开机自启（OpenRC /etc/local.d）"
        return 0
    fi
    local rc=/etc/rc.local
    [ -f "$rc" ] || { printf '#!/bin/sh -e\nexit 0\n' > "$rc"; chmod +x "$rc"; }
    grep -q "port_limiter" "$rc" 2>/dev/null || sed -i "/^exit 0/i $SCRIPT_PATH apply boot" "$rc"
    ok "已写入 $rc（请确认 rc-local 服务已启用）"
}

disable_autostart() {
    if has_systemd; then
        systemctl disable port-limiter.service >/dev/null 2>&1 && ok "已取消开机自启" || warn "取消自启失败或本就未启用"
        return 0
    fi
    rm -f /etc/local.d/port_limiter.start 2>/dev/null
    sed -i "/port_limiter/d" /etc/rc.local 2>/dev/null
    ok "已取消开机自启（非 systemd 路径）"
}

# ------------------------------------------------------------------ 规则管理
menu_add_rule() {
    echo
    info "=== 添加限速规则 ==="
    echo " 1. 离散端口，各自独立限速（例 80,443,8080）"
    echo " 2. 连续端口，各自独立限速（例 40001-41111，每个端口独享）"
    echo " 3. 连续端口，共享总额度  （例 40001-40100，整段共用一个额度）"
    read -r -p "选择类型: " type
    case "$type" in 1|2|3) ;; *) err "无效类型"; return 1;; esac

    read -r -p "端口（支持逗号与范围）: " ports
    validate_ports "$ports" || { err "端口表达式非法：$ports"; return 1; }

    read -r -p "峰值带宽（整数 Mbps）: " mbps
    case "$mbps" in ''|*[!0-9]*) err "带宽必须是整数"; return 1;; esac
    [ "$mbps" -ge 1 ] || { err "带宽必须 ≥1"; return 1; }

    read -r -p "备注: " desc
    desc="${desc:-无}"
    case "$desc" in *"|"*) err "备注不能包含竖线 |"; return 1;; esac

    local id; id="$(date +%s)"
    printf '%s|%s|%s|%s|%s\n' "$id" "$type" "$ports" "$mbps" "$desc" >> "$RULE_FILE"
    ok "已添加，规则 ID：$id"

    read -r -p "立即应用？(Y/n): " a
    case "${a:-y}" in y|Y|"") apply_rules;; esac
}

menu_view_rules() {
    echo
    info "=== 当前规则 ==="
    if [ ! -s "$RULE_FILE" ]; then warn "暂无规则"; return 0; fi
    awk -F'|' 'BEGIN{printf "%-12s %-6s %-22s %-8s %s\n","ID","类型","端口","Mbps","备注"}
               {printf "%-12s %-6s %-22s %-8s %s\n",$1,$2,$3,$4,$5}' "$RULE_FILE"
    echo
    info "类型说明：1 离散端口各自独立 | 2 连续端口各自独立 | 3 连续端口共享额度"
}

menu_del_rule() {
    menu_view_rules
    [ -s "$RULE_FILE" ] || return 0
    read -r -p "输入要删除的规则 ID: " del_id
    case "$del_id" in ''|*[!0-9]*) err "ID 必须是数字"; return 1;; esac
    if grep -q "^${del_id}|" "$RULE_FILE" 2>/dev/null; then
        grep -v "^${del_id}|" "$RULE_FILE" > "$RULE_FILE.tmp" && mv "$RULE_FILE.tmp" "$RULE_FILE"
        ok "规则 $del_id 已删除"
        read -r -p "立即重新应用？(Y/n): " a
        case "${a:-y}" in y|Y|"") apply_rules;; esac
    else
        err "未找到规则 ID：$del_id"
    fi
}

menu_status() {
    echo
    info "=== 运行状态 ==="
    if nft list table inet "$TABLE" >/dev/null 2>&1; then
        echo "限速表：已加载"
        nft list table inet "$TABLE" 2>/dev/null | grep -cE 'drop' | awk '{print "限速规则条数："$1}'
    else
        warn "限速表：未加载（当前不限制任何端口）"
    fi
    if has_systemd; then
        systemctl is-enabled port-limiter.service >/dev/null 2>&1 && echo "开机自启：已启用" || echo "开机自启：未启用"
    else
        echo "init 系统：非 systemd（自启走 local.d / rc.local）"
    fi
    echo
    info "=== 本机能力自检 ==="
    probe_caps && print_caps
}

# ------------------------------------------------------------------ 自我固化
REMOTE_URL="https://raw.githubusercontent.com/otaku-say/port_limiter/refs/heads/main/port_limiter.sh"

fixate_self() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    [ "$self" = "$SCRIPT_PATH" ] && return 0
    mkdir -p "$WORK_DIR"
    if [ -f "$self" ] && [ -s "$self" ]; then
        [ -f "$SCRIPT_PATH" ] && ! cmp -s "$self" "$SCRIPT_PATH" 2>/dev/null && \
            cp -f "$SCRIPT_PATH" "$SCRIPT_PATH.bak.$(date +%s)" 2>/dev/null
        if cp -f "$self" "$SCRIPT_PATH" 2>/dev/null; then chmod +x "$SCRIPT_PATH"; return 0; fi
    fi
    if need_cmd curl && curl -fsSL --max-time 20 "$REMOTE_URL" -o "$SCRIPT_PATH.tmp" 2>/dev/null \
       && [ -s "$SCRIPT_PATH.tmp" ]; then
        mv -f "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"; chmod +x "$SCRIPT_PATH"; return 0
    fi
    warn "脚本自我固化失败（不影响本次运行）"
}

# ------------------------------------------------------------------ 入口
init_env() {
    require_root
    mkdir -p "$WORK_DIR"; touch "$RULE_FILE"
    fixate_self
    ensure_nft interactive || exit 1
    probe_caps || exit 1
    has_systemd && deploy_service
}

interactive() {
    init_env
    info "port_limiter v$VERSION 已就绪（实现方式：$IMPL / 双栈 TCP+UDP / 不限连接数）"
    while true; do
        echo
        echo "=============================================="
        echo "   端口峰值带宽管理面板  v$VERSION"
        echo "=============================================="
        echo " 1. 添加限速规则"
        echo " 2. 查看当前规则"
        echo " 3. 删除规则"
        echo " 4. 立即应用 / 重启限速"
        echo " 5. 停止并移除全部限速"
        echo " 6. 运行状态 + 能力自检"
        echo " 7. 统计（被限速丢弃的端口/流量）"
        echo " 8. 设置开机自启"
        echo " 9. 取消开机自启"
        echo " 0. 退出"
        echo "=============================================="
        read -r -p "请选择: " choice
        # 直接粘贴 10 位规则 ID 即删除
        case "$choice" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
                if grep -q "^${choice}|" "$RULE_FILE" 2>/dev/null; then
                    grep -v "^${choice}|" "$RULE_FILE" > "$RULE_FILE.tmp" && mv "$RULE_FILE.tmp" "$RULE_FILE"
                    ok "规则 $choice 已删除并重新应用"
                    apply_rules
                else
                    err "未找到规则 ID：$choice"
                fi
                ;;
            1) menu_add_rule ;;
            2) menu_view_rules ;;
            3) menu_del_rule ;;
            4) apply_rules ;;
            5) stop_rules ;;
            6) menu_status ;;
            7) read -r -p "采样秒数（默认 10）: " s; show_stats "${s:-10}" ;;
            8) enable_autostart ;;
            9) disable_autostart ;;
            0) ok "再见"; exit 0 ;;
            *) err "无效输入" ;;
        esac
    done
}

main() {
    case "${1:-}" in
        apply)  require_root; ensure_nft "${2:-interactive}" || exit 1; probe_caps || exit 1; apply_rules; exit $? ;;
        stop)   require_root; stop_rules; exit $? ;;
        check)  require_root; ensure_nft interactive || exit 1; probe_caps || exit 1; DRY_RUN=1 apply_rules; exit $? ;;
        stats)  require_root; probe_caps >/dev/null 2>&1; show_stats "${2:-10}"; exit 0 ;;
        caps)   require_root; probe_caps && print_caps; exit 0 ;;
        "")     interactive ;;
        *)      echo "端口峰值带宽限制器 v$VERSION"; echo "用法: $0 [apply boot|stop|check|stats [秒]|caps]"; exit 1 ;;
    esac
}

main "$@"
