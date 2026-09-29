#!/bin/bash
# ==============================================================================
#  port_limiter v3.0.0  —— 端口峰值带宽整形器（仅 tc 实现）
# ------------------------------------------------------------------------------
#  实现方式：tc HTB（每端口硬上限）+ cake（排队/AQM/每主机公平）
#    超限的包「排队延后发出」而不是「直接丢弃」，吞吐上限不变，但不再有
#    TCP 重传风暴，用户侧不会出现「卡几秒→恢复→再卡」的断断续续。
#
#  覆盖范围：TCP + UDP、IPv4 + IPv6（flower 同时匹配两个协议族）、双向
#            - 出方向：出接口上的 HTB+cake，按源端口分类
#            - 入方向：内核无法直接整形入站，用 ifb 中转（只重定向关心的端口）
#
#  依赖：自动检测并用 apt 补齐
#    - iproute2（tc / ip）、kmod（modprobe）
#    - 内核模块 sch_htb / sch_cake / cls_flower / act_mirred / ifb
#      缺失时自动尝试安装 linux-modules-extra-$(uname -r)
#    - 依赖清单写入 /etc/modules-load.d/port_limiter.conf 保证重启自动加载
#
#  规则文件：  类型|端口|Mbps|备注        （序号 = 行号，删除时直接输入序号）
#    类型 1：离散端口，各自独立限速    例：80,443,8080
#    类型 2：连续端口，各自独立限速    例：40001-41111
#    类型 3：连续端口，共享总额度      例：40001-40100（整段共用一个类）
#
#  幂等性（重点）：
#    - 每次 apply 先删除旧 root / ingress qdisc（不存在也不报错），再按
#      「端口升序 → 类号递增」的固定规则重建；重复执行结果完全一致，不会叠加
#    - stop 只清理本脚本创建的对象，并尽力还原原有 root qdisc 类型
#    - 类号/过滤器 prio 由规则列表唯一确定，不随机、不累计
#
#  用法：
#    bash port_limiter.sh                # 交互式菜单
#    bash port_limiter.sh apply boot     # 开机调用（服务单元使用）
#    bash port_limiter.sh stop           # 清除全部整形并还原
#    bash port_limiter.sh check          # 干跑：只打印即将执行的 tc 命令，不动现网
#    bash port_limiter.sh stats [秒]     # 统计：每端口实际通过量 + 排队丢弃
#    bash port_limiter.sh caps           # 本机能力自检
#
#  可调参数（写入 /etc/port_limiter/config 持久化）：
#    TC_IFACE=auto           出接口；auto=按默认路由自动识别
#    TC_DIR=both             整形方向：both 双向 / egress 仅出方向
#    TC_DEFAULT_RATE=10gbit  兜底类速率（未匹配流量不受限）
#    TC_CAKE_OPTS="triple-isolate nonat"   cake 参数
#    MAX_TC_PORTS=64         单条规则端口数上限（整形需要一类一口）
#    AUTO_INSTALL=1          缺失依赖时自动用 apt 安装
# ==============================================================================
set -uo pipefail

VERSION="3.0.0"
WORK_DIR="${WORK_DIR:-/etc/port_limiter}"
RULE_FILE="${RULE_FILE:-$WORK_DIR/rules.conf}"
CONFIG_FILE="${CONFIG_FILE:-$WORK_DIR/config}"
SCRIPT_PATH="${SCRIPT_PATH:-$WORK_DIR/port_limiter.sh}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/port-limiter.service}"
STATE_DIR="${STATE_DIR:-/run/port_limiter}"
TC_STATE="$STATE_DIR/tc.state"
MODULES_FILE="/etc/modules-load.d/port_limiter.conf"

# 默认参数（config 文件可覆盖）
TC_IFACE="${TC_IFACE:-auto}"
TC_DIR="${TC_DIR:-both}"
TC_DEFAULT_RATE="${TC_DEFAULT_RATE:-10gbit}"
TC_CAKE_OPTS="${TC_CAKE_OPTS:-triple-isolate nonat}"
MAX_TC_PORTS="${MAX_TC_PORTS:-64}"
AUTO_INSTALL="${AUTO_INSTALL:-1}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

REQ_MODULES="sch_htb sch_cake cls_flower act_mirred ifb"
DEFAULT_CLASS="ffff"
IFB_NAME="ifb_pl"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}$*${NC}"; }
ok()   { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}警告：$*${NC}"; }
err()  { echo -e "${RED}错误：$*${NC}" >&2; }

require_root() { [ "$(id -u)" -eq 0 ] || { err "请用 root 运行（当前 uid=$(id -u)）"; exit 1; }; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ 依赖自动补齐
APT_UPDATED=0

apt_install() {
    local pkgs="$*"
    [ -n "$pkgs" ] || return 0
    if ! need_cmd apt-get; then
        err "未检测到 apt-get，请手动安装：$pkgs"
        return 1
    fi
    if [ "$APT_UPDATED" = "0" ]; then
        info "更新软件包索引（apt-get update）..."
        apt-get update -qq >/dev/null 2>&1 && APT_UPDATED=1
    fi
    info "安装缺失依赖：$pkgs"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null 2>&1
}

load_modules() {
    local m
    for m in $REQ_MODULES; do
        modprobe "$m" >/dev/null 2>&1
    done
    return 0
}

# 功能探测（真机）：建一张 dummy 网卡，实际挂 htb/cake/flower，测完即删；对现网零影响
# 返回 0=全部可用  1=不可用  2=无法探测（dummy 不可用，交给真实构建去报错）
TC_OK=0; TC_CAKE_OK=0; TC_FLOWER_OK=0; IFB_OK=0
probe_env() {
    TC_OK=0; TC_CAKE_OK=0; TC_FLOWER_OK=0; IFB_OK=0
    need_cmd tc || return 1
    need_cmd ip || return 1
    modprobe ifb >/dev/null 2>&1
    if ip link add "_pl_ifbprobe" type ifb >/dev/null 2>&1; then
        IFB_OK=1; ip link del "_pl_ifbprobe" >/dev/null 2>&1
    fi
    modprobe dummy >/dev/null 2>&1
    local dev="_pl_tcprobe" rc=2
    if ip link add "$dev" type dummy >/dev/null 2>&1; then
        ip link set "$dev" up >/dev/null 2>&1
        if tc qdisc add dev "$dev" root handle 1: htb default "$DEFAULT_CLASS" >/dev/null 2>&1; then
            TC_OK=1; rc=1
            tc class add dev "$dev" parent 1: classid "1:$DEFAULT_CLASS" htb rate 10gbit ceil 10gbit quantum 1500 >/dev/null 2>&1
            tc class add dev "$dev" parent 1: classid 1:1 htb rate 100mbit ceil 100mbit quantum 1500 >/dev/null 2>&1
            tc qdisc add dev "$dev" parent 1:1 handle 2: cake bandwidth 100mbit >/dev/null 2>&1 && { TC_CAKE_OK=1; rc=0; }
            tc filter add dev "$dev" parent 1: protocol ip prio 1 flower ip_proto tcp src_port 1234 classid 1:1 >/dev/null 2>&1 \
                && { TC_FLOWER_OK=1; rc=0; }
        fi
        tc qdisc del dev "$dev" root >/dev/null 2>&1
        ip link del "$dev" >/dev/null 2>&1
    fi
    return $rc
}

ensure_deps() {
    local need=""
    need_cmd tc       || need="$need iproute2"
    need_cmd ip       || need="$need iproute2"
    need_cmd modprobe || need="$need kmod"
    if [ -n "$need" ]; then
        if [ "$AUTO_INSTALL" = "1" ]; then
            apt_install $need || { err "依赖安装失败：$need"; return 1; }
        else
            err "缺少命令：$need（AUTO_INSTALL=0 已关闭自动安装）"; return 1
        fi
    fi

    load_modules
    probe_env; local rc=$?
    if [ "$rc" != "0" ]; then
        local pkg="linux-modules-extra-$(uname -r)"
        if [ "$AUTO_INSTALL" = "1" ]; then
            warn "tc 所需内核模块不可用，尝试安装：$pkg"
            apt_install "$pkg" || warn "该发行版可能无此包名（例如 Debian 的模块多在 linux-image-* 里）"
            load_modules; probe_env; rc=$?
        fi
        if [ "$rc" = "1" ]; then
            err "本机 tc 能力不足：需要 sch_htb + sch_cake + cls_flower"
            echo "  请执行：apt-get install -y iproute2 kmod $pkg" >&2
            echo "  然后确认：modprobe sch_cake && tc qdisc add dev lo root cake 2>&1（临时验证后可 del）" >&2
            return 1
        fi
    fi

    # 记录模块清单，保证重启后自动加载（幂等：每次覆盖）
    if [ -d /etc/modules-load.d ] && [ "${DRY_RUN:-0}" != "1" ]; then
        printf '%s\n' $REQ_MODULES > "$MODULES_FILE" 2>/dev/null
    fi
    return 0
}

# ------------------------------------------------------------------ 端口解析
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

norm_ports()  { echo "$1" | tr -d ' \t'; }
count_ports() { expand_ports "$1" 2>/dev/null | awk 'END{print NR+0}'; }
validate_ports() { expand_ports "$1" >/dev/null 2>&1; }
count_rules() { awk 'END{print NR+0}' "$RULE_FILE" 2>/dev/null; }

# 规则行解析：当前格式「类型|端口|Mbps|备注」
# 若首列是 8 位以上纯数字（老版本的时间戳 ID），自动忽略该列——一次性迁移，不算兼容负担
parse_rule_line() {
    local f1="${1:-}" f2="${2:-}" f3="${3:-}" f4="${4:-}" f5="${5:-}"
    case "$f1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) echo "$f2|$f3|$f4|$f5" ;;
        *)                                         echo "$f1|$f2|$f3|$f4" ;;
    esac
}

tc_detect_iface() {
    if [ -n "${TC_IFACE:-}" ] && [ "$TC_IFACE" != "auto" ]; then echo "$TC_IFACE"; return 0; fi
    ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# ------------------------------------------------------------------ 类规格生成
# 输出「类号 速率(Mbit) 端口」；类号由出现顺序唯一确定 → 重复执行结果一致（幂等）
gen_specs() {
    local f1 f2 f3 f4 f5 line type ports mbps desc p n idx=0 ln=0
    while IFS='|' read -r f1 f2 f3 f4 f5; do
        [ -n "${f1:-}" ] || continue
        ln=$((ln + 1))
        line="$(parse_rule_line "$f1" "$f2" "$f3" "$f4" "$f5")"
        IFS='|' read -r type ports mbps desc <<EOF
$line
EOF
        case "$type" in 1|2|3) ;; *) warn "第 $ln 条：类型非法（$type），已跳过" >&2; continue;; esac
        validate_ports "$ports" || { warn "第 $ln 条：端口表达式非法（$ports），已跳过" >&2; continue; }
        case "$mbps" in ''|*[!0-9]*) warn "第 $ln 条：带宽必须是整数 Mbps，已跳过" >&2; continue;; esac
        [ "$mbps" -ge 1 ] || { warn "第 $ln 条：带宽必须 ≥1，已跳过" >&2; continue; }
        n="$(count_ports "$ports")"
        if [ "$n" -gt "$MAX_TC_PORTS" ]; then
            warn "第 $ln 条含 $n 个端口，超过 MAX_TC_PORTS=$MAX_TC_PORTS（整形需要一类一口），已跳过" >&2
            continue
        fi
        if [ "$type" = "3" ]; then
            # 类型3 = 整段共享额度 → 共用一个类
            idx=$((idx + 1))
            for p in $(expand_ports "$ports"); do echo "$idx $mbps $p"; done
        else
            # 类型1/2 = 每端口独立额度 → 每端口一个类
            for p in $(expand_ports "$ports"); do idx=$((idx + 1)); echo "$idx $mbps $p"; done
        fi
    done < "$RULE_FILE" | awk '!seen[$3]++'
}

tc_do()  { if [ "${DRY_RUN:-0}" = "1" ]; then echo "    $*"; return 0; fi; "$@"; }
tc_doq() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "    $*   # 允许失败（幂等清理）"; return 0; fi; "$@" 2>/dev/null || true; }

# ------------------------------------------------------------------ 构建一棵整形树
# $1=设备  $2=匹配关键字 src_port|dst_port  $3=specs 文件
build_tree() {
    local dev="$1" kw="$2" specs="$3" idx rate port fam
    tc_doq tc qdisc del dev "$dev" root                       # 幂等：先清旧的
    tc_do tc qdisc add dev "$dev" root handle 1: htb default "$DEFAULT_CLASS" || return 1
    tc_do tc class add dev "$dev" parent 1: classid "1:$DEFAULT_CLASS" htb rate "$TC_DEFAULT_RATE" ceil "$TC_DEFAULT_RATE" quantum 1500 || return 1

    while read -r idx rate port; do
        [ -n "${idx:-}" ] && [ -n "${port:-}" ] && [ -n "${rate:-}" ] || continue
        tc_do tc class add dev "$dev" parent 1: classid "1:$idx" htb rate "${rate}mbit" ceil "${rate}mbit" burst 32k cburst 32k quantum 1500 \
            || { err "类 $idx（端口 $port）创建失败"; return 1; }
        tc_do tc qdisc add dev "$dev" parent "1:$idx" handle "$((idx + 1)):" cake bandwidth "${rate}mbit" $TC_CAKE_OPTS \
            || warn "端口 $port 的 cake 叶子队列创建失败（退化为纯 HTB 排队）"
        # 双栈：ip 用 prio 1、ipv6 用 prio 2 —— 同一 prio 混用协议族会被内核拒绝
        for fam in ip ipv6; do
            case "$fam" in ip) prio=1 ;; *) prio=2 ;; esac
            if ! tc_do tc filter add dev "$dev" parent 1: protocol "$fam" prio "$prio" flower ip_proto tcp "$kw" "$port" classid "1:$idx"; then
                if [ "$fam" = "ip" ]; then
                    err "IPv4 TCP 过滤器创建失败（端口 $port，$kw）"; return 1
                fi
                warn "IPv6 TCP 过滤器创建失败（端口 $port），该端口仅 IPv4 生效"
            fi
            tc_do tc filter add dev "$dev" parent 1: protocol "$fam" prio "$prio" flower ip_proto udp "$kw" "$port" classid "1:$idx" \
                || warn "IPv6/UDP 过滤器创建失败（端口 $port，$kw）"
        done
    done < "$specs"
    return 0
}

# ------------------------------------------------------------------ 应用（幂等）
apply_all() {
    warn_if_test_mode
    ensure_deps || return 1
    local iface specs ORIG_ROOT="" IFB_CREATED=0
    iface="$(tc_detect_iface)"
    [ -n "$iface" ] || { err "未能识别出接口，请设置 TC_IFACE=eth0"; return 1; }
    ip link show "$iface" >/dev/null 2>&1 || { err "接口不存在：$iface"; return 1; }

    specs="$(mktemp)"; gen_specs > "$specs"
    if [ ! -s "$specs" ]; then
        warn "rules.conf 为空或端口数超限，本次只清理旧配置"
    fi

    info "整形接口：$iface（方向：$TC_DIR）"
    ORIG_ROOT="$(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="qdisc"){print $(i+1); exit}}')"
    case "$ORIG_ROOT" in htb) ORIG_ROOT="";; esac   # 已是我们的（或别人的）htb，不必还原

    # 1) 出方向（按源端口分类 = 我们的端口发送给客户的流量）
    build_tree "$iface" src_port "$specs" || { rm -f "$specs"; return 1; }

    # 2) 入方向（ifb 中转；内核不能直接整形入站）
    if [ "$TC_DIR" = "both" ]; then
        # 「由本脚本创建」的标记要跨多次 apply 保持，否则二次 apply 后 stop 不敢删 ifb
        local prev_created=0
        [ -f "$TC_STATE" ] && prev_created="$(awk -F= '/^IFB_CREATED=/{gsub(/[^0-9]/,"",$2); print $2}' "$TC_STATE" 2>/dev/null)"
        [ -n "$prev_created" ] || prev_created=0
        if [ "$IFB_OK" = "1" ]; then
            if ! ip link show "$IFB_NAME" >/dev/null 2>&1; then
                ip link add "$IFB_NAME" type ifb >/dev/null 2>&1 && IFB_CREATED=1
            fi
            [ "$IFB_CREATED" = "0" ] && IFB_CREATED="$prev_created"
            if ip link show "$IFB_NAME" >/dev/null 2>&1; then
                ip link set "$IFB_NAME" up >/dev/null 2>&1
                tc_doq tc qdisc del dev "$iface" ingress
                tc_do tc qdisc add dev "$iface" handle ffff: ingress
                build_tree "$IFB_NAME" dst_port "$specs" || warn "$IFB_NAME 整形树创建失败，入方向未限速"
                # 只重定向我们关心的端口，其余入站流量走原路径（比全量重定向安全）
                local redir_ok=0
                while read -r idx rate port; do
                    [ -n "${port:-}" ] || continue
                    for fam in ip ipv6; do
                        case "$fam" in ip) prio=1 ;; *) prio=2 ;; esac
                        if tc_do tc filter add dev "$iface" parent ffff: protocol "$fam" prio "$prio" flower ip_proto tcp dst_port "$port" \
                               action mirred egress redirect dev "$IFB_NAME"; then
                            redir_ok=$((redir_ok + 1))
                        fi
                        tc_do tc filter add dev "$iface" parent ffff: protocol "$fam" prio "$prio" flower ip_proto udp dst_port "$port" \
                            action mirred egress redirect dev "$IFB_NAME" || true
                    done
                done < "$specs"
                if [ "$redir_ok" -eq 0 ] && [ "${DRY_RUN:-0}" != "1" ]; then
                    warn "入方向重定向规则一条都没建成功，入方向未限速"
                fi
            else
                warn "无法创建 ifb 设备，入方向未限速（出方向已生效）"
            fi
        else
            warn "本机不支持 ifb，入方向未限速（出方向已生效）；如需双向请安装 ifb 模块"
        fi
    fi

    rm -f "$specs"
    mkdir -p "$STATE_DIR" 2>/dev/null
    {
        printf "IFACE='%s'\n" "$iface"
        printf "IFB='%s'\n" "$(ip link show "$IFB_NAME" >/dev/null 2>&1 && echo "$IFB_NAME")"
        printf "IFB_CREATED='%s'\n" "$IFB_CREATED"
        printf "ORIG_ROOT='%s'\n" "$ORIG_ROOT"
    } > "$TC_STATE" 2>/dev/null

    [ "${DRY_RUN:-0}" != "1" ] && show_brief
    return 0
}

# ------------------------------------------------------------------ 清理（幂等）
stop_all() {
    local iface ifb did=0
    [ -f "$TC_STATE" ] && . "$TC_STATE"
    iface="${IFACE:-$(tc_detect_iface)}"
    ifb="${IFB:-}"
    if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then
        if tc qdisc show dev "$iface" 2>/dev/null | grep -q '^qdisc ingress'; then
            tc qdisc del dev "$iface" ingress >/dev/null 2>&1 && did=1
        fi
        if tc qdisc show dev "$iface" 2>/dev/null | grep -q 'qdisc htb 1:'; then
            tc qdisc del dev "$iface" root >/dev/null 2>&1 && did=1
            case "${ORIG_ROOT:-}" in
                fq_codel)   tc qdisc add dev "$iface" root handle 1: fq_codel >/dev/null 2>&1 ;;
                fq)         tc qdisc add dev "$iface" root handle 1: fq >/dev/null 2>&1 ;;
                mq)         tc qdisc add dev "$iface" root handle 1: mq >/dev/null 2>&1 ;;
                pfifo_fast) tc qdisc add dev "$iface" root handle 0: pfifo_fast >/dev/null 2>&1 ;;
                cake)       tc qdisc add dev "$iface" root cake >/dev/null 2>&1 ;;
            esac
        fi
    fi
    if [ -n "$ifb" ] && ip link show "$ifb" >/dev/null 2>&1; then
        tc qdisc del dev "$ifb" root >/dev/null 2>&1
        # 归属判定：状态文件标记为主，设备名等于本脚本命名（ifb_pl）为辅
        if [ "${IFB_CREATED:-0}" = "1" ] || [ "$ifb" = "$IFB_NAME" ]; then
            ip link del "$ifb" >/dev/null 2>&1 && did=1
        fi
    fi
    rm -f "$TC_STATE" 2>/dev/null
    if [ "$did" = "1" ]; then ok "整形配置已清理（并尽力还原原有队列规则）"; else warn "没有发现本脚本创建的整形配置"; fi
    return 0
}

# ------------------------------------------------------------------ 结构自检
show_brief() {
    local iface n_class n_filter
    [ -f "$TC_STATE" ] && . "$TC_STATE"
    iface="${IFACE:-}"
    [ -n "$iface" ] || return 0
    n_class=$(tc class show dev "$iface" 2>/dev/null | grep -c 'class htb')
    n_filter=$(tc filter show dev "$iface" parent 1: 2>/dev/null | grep -c 'flower')
    echo "  出方向 $iface：HTB 类 $n_class 个（含兜底），过滤器 $n_filter 条"
    if [ -n "${IFB:-}" ] && ip link show "${IFB:-}" >/dev/null 2>&1; then
        n_class=$(tc class show dev "$IFB" 2>/dev/null | grep -c 'class htb')
        n_filter=$(tc filter show dev "$IFB" parent 1: 2>/dev/null | grep -c 'flower')
        echo "  入方向 $IFB：HTB 类 $n_class 个，过滤器 $n_filter 条（按目的端口）"
    fi
}

# ------------------------------------------------------------------ 统计
# 输出：tag|类号|字节|包|排队丢弃   （来自 cake 叶子队列，包含实际通过量与丢弃）
stats_dump() {
    local dev="$1" tag="$2" specs="$3"
    tc -s qdisc show dev "$dev" 2>/dev/null | awk -v t="$tag" -v dv="$dev" '
        /^qdisc / {
            if ($0 ~ /^qdisc cake/) {
                par=""
                for (i=1;i<=NF;i++) if ($i=="parent") par=$(i+1)
                sub(/^1:/,"",par); cur=par
            } else {
                cur=""          # 非 cake（如 htb 根、ingress）的 Sent 行不能算到 cake 头上
            }
            next
        }
        /Sent [0-9]+ bytes/ {
            if (cur=="") next
            line=$0; sub(/.*Sent /,"",line); split(line,a," ")
            d=0
            if (match($0,/dropped [0-9]+/)) d=substr($0,RSTART+8,RLENGTH-8)
            printf "%s|%s|%s|%s|%s|%s\n", t, dv, cur, a[1], a[3], d
        }' | while IFS='|' read -r t dv idx b p d; do
        local port rate
        port="$(awk -v i="$idx" '$1==i{print $3; exit}' "$specs" 2>/dev/null)"
        rate="$(awk -v i="$idx" '$1==i{print $2; exit}' "$specs" 2>/dev/null)"
        echo "$t|$dv|$idx|${port:-?}|${rate:-0}|$b|$p|$d"
    done
}

show_stats() {
    local d="${1:-10}" iface specs f1 f2
    [ -f "$TC_STATE" ] && . "$TC_STATE"
    iface="${IFACE:-$(tc_detect_iface)}"
    [ -n "$iface" ] || { err "未能识别出接口"; return 1; }
    specs="$(mktemp)"; gen_specs > "$specs"
    f1="$(mktemp)"; f2="$(mktemp)"

    { stats_dump "$iface" "出" "$specs"; [ -n "${IFB:-}" ] && stats_dump "${IFB}" "入" "$specs"; } | sort > "$f1"
    info "采样 ${d} 秒（统计每端口实际通过量；整形模式下超限的包会排队而不是丢包）..."
    sleep "$d"
    { stats_dump "$iface" "出" "$specs"; [ -n "${IFB:-}" ] && stats_dump "${IFB}" "入" "$specs"; } | sort > "$f2"

    awk -F'|' -v d="$d" '
        NR==FNR { b[$1"|"$2"|"$3]=$6; p[$1"|"$2"|"$3]=$7; dq[$1"|"$2"|"$3]=$8; next }
        {
          k=$1"|"$2"|"$3
          db=$6-b[k]; dp=$7-p[k]; dd=$8-dq[k]
          if (db<0) db=0; if (dp<0) dp=0; if (dd<0) dd=0
          if (db>0 || dp>0 || dd>0)
              printf "  %-2s %-6s 端口 %-6s 上限 %5s Mbit/s | 通过 %9.2f Mbit/s | %8.0f 包/秒 | 排队丢弃 %8.0f 包/秒\n",
                     $1, $2, $4, $5, db*8/1000000/d, dp/d, dd/d
        }' "$f1" "$f2" | sort -k6 -nr | head -30

    echo
    if grep -qE '\|[^0]*$' "$f2" 2>/dev/null; then
        info "说明：整形模式下「排队丢弃」通常很小；若持续偏大说明该端口长期远超上限，建议提高额度"
    else
        ok "本次采样窗口内所有端口均未触及上限"
    fi
    rm -f "$specs" "$f1" "$f2"
}

# ------------------------------------------------------------------ 持久配置
write_config() {
    mkdir -p "$WORK_DIR" 2>/dev/null
    {
        echo "# port_limiter 持久配置（由脚本生成，可手工编辑）"
        echo "TC_IFACE=\"$TC_IFACE\""
        echo "TC_DIR=\"$TC_DIR\""
        echo "TC_DEFAULT_RATE=\"$TC_DEFAULT_RATE\""
        echo "TC_CAKE_OPTS=\"$TC_CAKE_OPTS\""
        echo "MAX_TC_PORTS=\"$MAX_TC_PORTS\""
        echo "AUTO_INSTALL=\"$AUTO_INSTALL\""
    } > "$CONFIG_FILE" 2>/dev/null
}

# ------------------------------------------------------------------ 服务 / 自启
deploy_service() {
    if has_systemd && [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Port peak bandwidth limiter (port_limiter v$VERSION, tc HTB+cake)
After=network-online.target
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

has_systemd() { need_cmd systemctl && [ -d /run/systemd/system ]; }

enable_autostart() {
    if has_systemd; then
        deploy_service
        systemctl enable port-limiter.service >/dev/null 2>&1 && ok "已设置开机自启（systemd）" || { err "systemd 启用失败"; return 1; }
        return 0
    fi
    if [ -d /etc/local.d ]; then
        printf '#!/bin/sh\n%s apply boot\n' "$SCRIPT_PATH" > /etc/local.d/port_limiter.start
        chmod +x /etc/local.d/port_limiter.start
        rc-update add local default >/dev/null 2>&1
        ok "已设置开机自启（OpenRC /etc/local.d）"; return 0
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
    ok "已取消开机自启"
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
    if need_cmd curl && curl -fsSL --max-time 20 "$REMOTE_URL" -o "$SCRIPT_PATH.tmp" 2>/dev/null && [ -s "$SCRIPT_PATH.tmp" ]; then
        mv -f "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"; chmod +x "$SCRIPT_PATH"; return 0
    fi
    warn "脚本自我固化失败（不影响本次运行）"
}

warn_if_test_mode() {
    [ "${TC_IFACE:-auto}" = "auto" ] && return 0
    local d
    d="$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ "$TC_IFACE" != "$d" ] && warn "测试模式：只操作接口 $TC_IFACE（默认路由接口 ${d:-未知} 不受影响）"
    return 0
}

# ------------------------------------------------------------------ 规则管理
# 序号 = 规则文件的行号；删除直接按序号（sed -i），不需要长 ID
resolve_line() {
    local input="$1" total
    case "$input" in ''|*[!0-9]*) return 1;; esac
    total="$(count_rules)"
    [ "$input" -ge 1 ] && [ "$input" -le "$total" ] && { echo "$input"; return 0; }
    return 1
}

delete_line() {
    local n="$1"
    [ -s "$RULE_FILE" ] || return 1
    sed -i "${n}d" "$RULE_FILE" 2>/dev/null || return 1
    return 0
}

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
    [ "$(count_ports "$ports")" -le "$MAX_TC_PORTS" ] || { err "端口数超过 MAX_TC_PORTS=$MAX_TC_PORTS（整形需要一类一口），请只列真实服务端口"; return 1; }

    read -r -p "峰值带宽（整数 Mbps）: " mbps
    case "$mbps" in ''|*[!0-9]*) err "带宽必须是整数"; return 1;; esac
    [ "$mbps" -ge 1 ] || { err "带宽必须 ≥1"; return 1; }

    read -r -p "备注: " desc
    desc="${desc:-无}"
    case "$desc" in *"|"*) err "备注不能包含竖线 |"; return 1;; esac

    printf '%s|%s|%s|%s\n' "$type" "$ports" "$mbps" "$desc" >> "$RULE_FILE"
    ok "已添加：第 $(count_rules) 条 → 类型$type / $ports / ${mbps}Mbps"
    read -r -p "立即应用？(Y/n): " a
    case "${a:-y}" in y|Y|"") apply_all;; esac
}

menu_view_rules() {
    echo
    info "=== 当前规则 ==="
    if [ ! -s "$RULE_FILE" ]; then warn "暂无规则"; return 0; fi
    awk -F'|' 'BEGIN{printf "%-5s %-6s %-22s %-8s %s\n","序号","类型","端口","Mbps","备注"}
               {printf "%-5d %-6s %-22s %-8s %s\n", NR,$1,$2,$3,$4}' "$RULE_FILE"
    echo
    info "类型：1 离散端口各自独立 | 2 连续端口各自独立 | 3 连续端口共享额度"
    info "删除时输入「序号」即可（如输入 2 删除第 2 条）"
}

menu_del_rule() {
    menu_view_rules
    [ -s "$RULE_FILE" ] || return 0
    read -r -p "输入要删除的规则序号: " num
    resolve_line "$num" >/dev/null || { err "没有这条规则（序号需在 1..$(count_rules) 之间）"; return 1; }
    if delete_line "$num"; then
        ok "已删除第 $num 条规则"
        read -r -p "立即重新应用？(Y/n): " a
        case "${a:-y}" in y|Y|"") apply_all;; esac
    else
        err "删除失败"
    fi
}

menu_settings() {
    echo
    info "=== 整形参数（写入 $CONFIG_FILE 持久化）==="
    echo " 1. 出接口          当前：$TC_IFACE"
    echo " 2. 整形方向        当前：$TC_DIR（both 双向 / egress 仅出方向）"
    echo " 3. 兜底类速率      当前：$TC_DEFAULT_RATE（未匹配流量不受限）"
    echo " 4. cake 参数       当前：$TC_CAKE_OPTS"
    echo " 5. 单规则端口上限  当前：$MAX_TC_PORTS"
    echo " 6. 自动安装依赖    当前：$AUTO_INSTALL"
    read -r -p "选择要修改的项（回车返回）: " c
    case "${c:-}" in
        1) read -r -p "出接口（auto=自动识别）: " v; [ -n "$v" ] && TC_IFACE="$v" ;;
        2) read -r -p "整形方向 both|egress: " v; [ -n "$v" ] && TC_DIR="$v" ;;
        3) read -r -p "兜底类速率（如 10gbit）: " v; [ -n "$v" ] && TC_DEFAULT_RATE="$v" ;;
        4) read -r -p "cake 参数: " v; [ -n "$v" ] && TC_CAKE_OPTS="$v" ;;
        5) read -r -p "单规则端口上限: " v; [ -n "$v" ] && MAX_TC_PORTS="$v" ;;
        6) read -r -p "自动安装依赖 1/0: " v; [ -n "$v" ] && AUTO_INSTALL="$v" ;;
        "") return 0 ;;
        *) err "无效选择"; return 1 ;;
    esac
    write_config
    ok "已保存到 $CONFIG_FILE"
}

menu_status() {
    echo
    info "=== 运行状态 ==="
    local iface
    [ -f "$TC_STATE" ] && . "$TC_STATE"
    iface="${IFACE:-$(tc_detect_iface)}"
    echo "出接口：${iface:-未识别}   整形方向：$TC_DIR"
    if [ -n "$iface" ] && tc qdisc show dev "$iface" 2>/dev/null | grep -q 'qdisc htb 1:'; then
        echo "整形：已生效"
        show_brief
    else
        warn "整形：未生效（当前不限制任何端口）"
    fi
    if has_systemd; then
        systemctl is-enabled port-limiter.service >/dev/null 2>&1 && echo "开机自启：已启用" || echo "开机自启：未启用"
    else
        echo "init 系统：非 systemd（自启走 local.d / rc.local）"
    fi
    echo
    info "=== 本机能力自检 ==="
    echo "  发行版     : $( ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" ) || echo unknown )"
    echo "  内核       : $(uname -r)"
    echo "  tc         : $(tc -V 2>/dev/null | head -1)"
    probe_env >/dev/null 2>&1
    echo "  sch_htb    : $([ "$TC_OK" = 1 ] && echo 支持 || echo '不支持')"
    echo "  sch_cake   : $([ "$TC_CAKE_OK" = 1 ] && echo 支持 || echo '不支持')"
    echo "  cls_flower : $([ "$TC_FLOWER_OK" = 1 ] && echo 支持 || echo '不支持')"
    echo "  ifb(入方向): $([ "$IFB_OK" = 1 ] && echo 支持 || echo '不支持（入方向将不整形）')"
    echo "  init 系统  : $(has_systemd && echo systemd || echo '非 systemd')"
}

interactive() {
    require_root
    mkdir -p "$WORK_DIR"; touch "$RULE_FILE"
    fixate_self
    ensure_deps || exit 1
    has_systemd && deploy_service
    ok "port_limiter v$VERSION 已就绪（tc HTB+cake 整形 / TCP+UDP 双栈 / 不限连接数）"
    while true; do
        echo
        echo "=============================================="
        echo "   端口峰值带宽管理面板  v$VERSION  [tc 整形]"
        echo "=============================================="
        echo " 1. 添加限速规则"
        echo " 2. 查看当前规则"
        echo " 3. 删除规则"
        echo " 4. 立即应用 / 重启整形"
        echo " 5. 停止并移除全部整形"
        echo " 6. 运行状态 + 能力自检"
        echo " 7. 统计（每端口通过量 / 排队丢弃）"
        echo " 8. 设置开机自启"
        echo " 9. 取消开机自启"
        echo "10. 修改整形参数（接口/方向/cake 等）"
        echo " 0. 退出"
        echo "=============================================="
        read -r -p "请输入菜单数字，或直接输入规则序号删除（如 2）: " choice
        case "$choice" in
            1) menu_add_rule ;;
            2) menu_view_rules ;;
            3) menu_del_rule ;;
            4) apply_all ;;
            5) stop_all ;;
            6) menu_status ;;
            7) read -r -p "采样秒数（默认 10）: " s; show_stats "${s:-10}" ;;
            8) enable_autostart ;;
            9) disable_autostart ;;
            10) menu_settings ;;
            0) ok "再见"; exit 0 ;;
            *)
                # 纯数字且非菜单项 → 视为规则序号，快捷删除
                case "$choice" in
                    ''|*[!0-9]*) err "无效输入" ;;
                    *)
                        if resolve_line "$choice" >/dev/null; then
                            delete_line "$choice" && { ok "已删除第 $choice 条规则，正在重新应用"; apply_all; } \
                                                   || err "删除失败"
                        else
                            err "未找到序号 $choice（当前共 $(count_rules) 条）"
                        fi ;;
                esac ;;
        esac
    done
}

main() {
    case "${1:-}" in
        apply)  require_root; apply_all; exit $? ;;
        stop)   require_root; stop_all; exit $? ;;
        check)  require_root; DRY_RUN=1 apply_all; exit $? ;;
        stats)  require_root; show_stats "${2:-10}"; exit $? ;;
        caps)   require_root; ensure_deps >/dev/null 2>&1; menu_status; exit 0 ;;
        "")     interactive ;;
        *)      echo "端口峰值带宽整形器 v$VERSION（tc HTB+cake）"
                echo "用法: $0 [apply boot|stop|check|stats [秒]|caps]"
                exit 1 ;;
    esac
}

main "$@"
