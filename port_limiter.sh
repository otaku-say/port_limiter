#!/bin/bash
# ==============================================================================
#  port_limiter v4.1.0  —— 端口峰值带宽整形器（tc HTB + cake）
#
#  ★ 默认工作模式：自动跟踪（auto-tracking）
#    规则里可以放心写一大段端口（如 40001-41111）：脚本只为「本机真正在监听」的
#    端口建类，并每 REFRESH_SEC 秒自动巡检 —— 端口上线则自动建类限速，
#    端口下线则自动收回。巡检发现配置未变时直接跳过，不做任何重建（开销只有一次
#    ss 快照 + 指纹比对，约几十毫秒）；变更事件写入 EVENT_LOG（默认 /var/log/port_limiter.log），
#    巡检无变化时不产生任何日志。
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
#  幂等与增量（重点）：
#    - 配置没变 → 什么都不做（一次指纹比对 + 完整性检查）
#    - 只有端口上下线 → **增量更新**：只增删/改速率那些变化的端口，其它端口的类与
#      cake 队列一个都不碰 → tc 统计连续（不归零）、无「未整形」空窗，
#      下发命令数与「变化的端口数」成正比，与总端口数无关
#    - 结构性变化（接口/方向/cake 参数/兜底速率/ifb 名/端口来源）或 apply force
#      → 整树重建：先删旧 root / ingress qdisc 再重建，结果完全一致，不会叠加
#    - 槽位（类号）随状态文件持久保存：端口上下线时沿用旧槽位，类号不会越加越乱；
#      过滤器 prio 每个单元独占一对，因此能按 prio 精确增删
#    - stop 只清理本脚本创建的对象，并尽力还原原有 root qdisc 类型
#
#  用法：
#    bash port_limiter.sh                # 交互式菜单
#    bash port_limiter.sh apply          # 应用（配置未变则跳过重建）
#    bash port_limiter.sh apply force    # 强制重建
#    bash port_limiter.sh apply boot     # 开机调用（强制重建）
#    bash port_limiter.sh stop           # 停止并还原（保留脚本与规则）
#    bash port_limiter.sh uninstall      # 一键卸载：停服务 + 清整形 + 删残留
#    bash port_limiter.sh check          # 干跑：只打印即将执行的 tc 命令
#    bash port_limiter.sh stats [秒]     # 统计：每端口实际通过量 + 排队丢弃
#    bash port_limiter.sh caps           # 本机能力自检
#
#  可调参数（写入 /etc/port_limiter/config 持久化）：
#    PORT_SOURCE=listen      listen=只为在监听的端口建类（默认，自动跟踪）
#                            config=按规则文件写的端口全量建类
#    REFRESH_SEC=30          自动巡检间隔（0 = 不装巡检定时器）
#    WARN_CLASSES=200        端口/类数超过此值时只提醒（不拦截）
#    TC_IFACE=auto           出接口；auto=按默认路由自动识别
#    TC_DIR=both             整形方向：both 双向 / egress 仅出方向
#    TC_DEFAULT_RATE=10gbit  兜底类速率（未匹配流量不受限）
#    TC_CAKE_OPTS="triple-isolate nonat"   cake 参数
#    IFB_NAME=ifb_pl         入方向中转网卡名（测试/多接口场景请换名）
#    AUTO_INSTALL=1          缺失依赖时自动用 apt 安装
#
#  规模与性能（实测：Debian13 / 内核6.18.54 / iproute2 6.15）
#    - 命令批量下发：一次 tc -batch（单进程）代替逐条：202 条命令 397ms → 9ms
#    - 端口范围原生匹配（类型3）：1111 个端口只需 1 个类 + 4 条过滤器
#    - 自动跟踪：规则 2|40001-41111|30 在本机只监听 12 个口时 → 只建 13 个类
# ==============================================================================
set -uo pipefail

VERSION="4.1.0"
WORK_DIR="${WORK_DIR:-/etc/port_limiter}"
RULE_FILE="${RULE_FILE:-$WORK_DIR/rules.conf}"
CONFIG_FILE="${CONFIG_FILE:-$WORK_DIR/config}"
SCRIPT_PATH="${SCRIPT_PATH:-$WORK_DIR/port_limiter.sh}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/port-limiter.service}"
STATE_DIR="${STATE_DIR:-$WORK_DIR}"      # 状态文件放配置目录（持久）；放 /run 会因重启丢失 ifb 归属信息
TC_STATE="$STATE_DIR/tc.state"
MODULES_FILE="${MODULES_FILE:-/etc/modules-load.d/port_limiter.conf}"

# 默认参数（config 文件可覆盖）
TC_IFACE="${TC_IFACE:-auto}"
TC_DIR="${TC_DIR:-both}"
TC_DEFAULT_RATE="${TC_DEFAULT_RATE:-10gbit}"
TC_CAKE_OPTS="${TC_CAKE_OPTS:-triple-isolate nonat}"
# 端口来源：listen = 只为本机「真正在监听」的端口建类（默认，自动跟踪）
#           config = 按规则文件里写的端口全量建类
PORT_SOURCE="${PORT_SOURCE:-listen}"
REFRESH_SEC="${REFRESH_SEC:-30}"      # 自动巡检间隔秒数（0 = 不安装巡检定时器）
WARN_CLASSES="${WARN_CLASSES:-200}"   # 计划建类数超过该值时只提醒、不拦截（0 = 关闭提醒）
EVENT_LOG="${EVENT_LOG:-/var/log/port_limiter.log}"   # 自动跟踪的变更事件日志（端口上下线）
AUTO_INSTALL="${AUTO_INSTALL:-1}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

REQ_MODULES="sch_htb sch_cake cls_flower act_mirred ifb"
DEFAULT_CLASS="ffff"
IFB_NAME="${IFB_NAME:-ifb_pl}"                  # 入方向中转网卡名；测试或多接口场景请改掉，避免互相覆盖

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
    # $1=quick：巡检路径复用上次探测结果（省掉 dummy 网卡探测，几十毫秒完成）
    local quick="${1:-}" need=""
    if [ "$quick" = "quick" ] && [ "${CAPS_OK:-0}" = "1" ] && need_cmd tc && need_cmd ip; then
        probe_batch
        return 0
    fi
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
    need_cmd tc && { probe_batch || warn "本机 tc 不支持 -batch 批量下发，将逐条执行（较慢）"; }
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
    CAPS_OK=1        # 供巡检路径复用，避免每次都做 dummy 网卡探测
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

tc_detect_iface() {
    if [ -n "${TC_IFACE:-}" ] && [ "$TC_IFACE" != "auto" ]; then echo "$TC_IFACE"; return 0; fi
    ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# 本机正在监听的 TCP/UDP 端口（PORT_SOURCE=listen 时用于动态建类）
local_listen_ports() {
    local out=""
    if need_cmd ss; then
        out="$(ss -H -lntu 2>/dev/null | awk '{print $5}')"
        [ -n "$out" ] || out="$(ss -lntu 2>/dev/null | awk 'NR>1{print $5}')"
    elif need_cmd netstat; then
        out="$(netstat -lntu 2>/dev/null | awk 'NR>2{print $4}')"
    fi
    printf '%s\n' "$out" | sed 's/.*://' | grep -E '^[0-9]+$' | sort -n -u
}

# ------------------------------------------------------------------ 类规格生成
# 输出「类号 速率(Mbit) 端口」；类号由出现顺序唯一确定 → 重复执行结果一致（幂等）
gen_specs() {
    local type ports mbps desc p n ln=0 unit kept_ports kept total_ports first
    while IFS='|' read -r type ports mbps desc; do
        [ -n "${type:-}" ] || continue
        ln=$((ln + 1))
        case "$type" in 1|2|3) ;; *) warn "第 $ln 条：类型非法（$type），已跳过" >&2; continue;; esac
        validate_ports "$ports" || { warn "第 $ln 条：端口表达式非法（$ports），已跳过" >&2; continue; }
        case "$mbps" in ''|*[!0-9]*) warn "第 $ln 条：带宽必须是整数 Mbps，已跳过" >&2; continue;; esac
        [ "$mbps" -ge 1 ] || { warn "第 $ln 条：带宽必须 ≥1，已跳过" >&2; continue; }
        # 动态建类（PORT_SOURCE=listen）：先把规则端口与本机「真实在监听」的端口求交集。
        # 必须在「上限检查」之前做 —— 否则一条 40001-41111 的规则会因为 1111 个口被直接拒，
        # 而它实际只需要为十几个在监听的口建类。
        kept_ports=""; kept=0
        if [ "$type" != "3" ] && [ "$PORT_SOURCE" = "listen" ]; then
            kept_ports="$(expand_ports "$ports" | awk -v lp="$(local_listen_ports | tr '\n' ' ')" '
                BEGIN { c = split(lp, a, " "); for (i = 1; i <= c; i++) if (a[i] != "") L[a[i]] = 1 }
                L[$1] { print $1 }' | tr '\n' ' ')"
            kept="$(printf '%s' "$kept_ports" | wc -w)"
            if [ "$kept" -eq 0 ]; then
                warn "第 $ln 条：规则里的端口在本机都没有监听，已跳过（PORT_SOURCE=listen）" >&2
                continue
            fi
        fi

        if [ "$type" = "3" ]; then
            # 类型3 走端口范围匹配，成本按「端口段(token)数」算
            n="$(printf '%s' "$(norm_ports "$ports" | tr ',' ' ')" | wc -w)"
            unit="个端口段"
        elif [ "$kept" -gt 0 ]; then
            # 自动跟踪：成本只按「真正要建类的端口数」算
            n="$kept"
            unit="个监听端口"
        else
            # 类型1/2 一类一口，成本按「端口数」算
            n="$(count_ports "$ports")"
            unit="个端口"
        fi
        # 不再设端口数上限；只在规模偏大时提醒（WARN_CLASSES=0 可关闭）
        if [ "${WARN_CLASSES:-0}" -gt 0 ] && [ "$n" -gt "$WARN_CLASSES" ]; then
            warn "第 $ln 条计划建 $n $unit 个类 —— 每个类要配 1 个队列 + 4 条过滤器（入方向翻倍），内核对象与构建时间随端口数线性增长；请确认符合预期（WARN_CLASSES 可调，0 = 关闭提醒）。" >&2
        fi
        if [ "$type" = "3" ]; then
            # 类型3 = 整段共享额度 → 共用一个桶。
            # 这里保留「端口 token」原样下发（含 a-b 范围）：内核 flower 支持范围匹配，
            # 因此 40001-41111 只需 1 条过滤器，而不是 1111 条（实测已验证）。
            # key 用「#首token」—— 与单端口 key（就是端口号）区分开，且由内容决定，
            # 与规则顺序、端口增减无关 → 增量更新时槽位可以稳定沿用。
            first="$(norm_ports "$ports" | tr ',' ' ' | awk '{print $1}')"
            for tok in $(norm_ports "$ports" | tr ',' ' '); do
                [ -n "$tok" ] && echo "#$first $mbps $tok"
            done
        else
            # 类型1/2 = 每端口独立额度 → 每端口一个桶（数学决定，无法用范围合并）
            if [ "$kept" -gt 0 ]; then
                total_ports="$(count_ports "$ports")"
                [ "$kept" -lt "$total_ports" ] && \
                    info "第 $ln 条：规则写 $total_ports 个端口 → 本机在监听 $kept 个，只为这 $kept 个建类（省 $((total_ports - kept)) 个）" >&2
                for p in $kept_ports; do echo "$p $mbps $p"; done
            else
                for p in $(expand_ports "$ports"); do echo "$p $mbps $p"; done
            fi
        fi
    done < "$RULE_FILE" | awk '!seen[$3]++'
}

tc_do()  { if [ "${DRY_RUN:-0}" = "1" ]; then echo "    $*"; return 0; fi; "$@"; }
tc_doq() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "    $*   # 允许失败（幂等清理）"; return 0; fi; "$@" 2>/dev/null || true; }

# 判断某接口是否挂有指定 qdisc。
# 千万别写成 `tc qdisc show ... | grep -q ...`：grep -q 命中即退出，会让 tc 收到
# SIGPIPE（退出码 141），在 set -o pipefail 下整条管道被判失败 → 明明已生效却报"未生效"。
tc_qdisc_has() {
    local out
    out="$(tc qdisc show dev "$1" 2>/dev/null)" || return 1
    case "$out" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ 构建一棵整形树
# 生成命令清单 → 一次性批量下发（tc -batch，单进程），比逐条 fork tc 快约 40 倍
# （实测：202 条命令 逐条 397ms → batch 9ms）
# 注意：batch 是「遇错即停」，所以"删除旧对象"这类注定可能失败的命令，
#       必须先判断存在性再决定是否写入清单，否则一条无害的 del 会中断整批。
BATCH_OK=0
probe_batch() {
    BATCH_OK=0
    need_cmd tc || return 1
    if tc -batch /dev/null >/dev/null 2>&1; then BATCH_OK=1; return 0; fi
    return 1
}

# 设备 root qdisc 的句柄（如 "1:"、"0:"；空 = 设备不存在）
# 注意：句柄为 0: 的是内核「隐式队列」（noqueue/fq/pfifo_fast/mq），
# 它不允许被 del（会报 "Cannot delete qdisc with handle of zero"），
# 这种设备必须用 qdisc replace 顶替，而不是 del + add。
tc_root_handle() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$0 ~ / root /{print $3; exit}'
}

# 执行 tc 命令清单（从 stdin 读）：优先 batch，老版本 tc 不支持时逐条执行
run_tc_cmds() {
    local f err line
    if [ "${DRY_RUN:-0}" = "1" ]; then sed 's/^/    tc /'; return 0; fi
    if [ "${BATCH_OK:-0}" = "1" ]; then
        f="$(mktemp)"; err="$(mktemp)"
        cat > "$f"
        if tc -batch "$f" >"$err" 2>&1; then rm -f "$f" "$err"; return 0; fi
        err "tc 批量下发失败（已停在出错处，后续命令未执行）：" >&2
        sed 's/^/    /' "$err" >&2
        rm -f "$f" "$err"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        tc $line || return 1
    done
    return 0
}

# ---------------------------------------------------------------- 单元与槽位（增量更新的基础）
# 「单元」= 内核里一个桶（1 个 HTB 类 + 1 个 cake 队列 + 若干过滤器）。
#   类型1/2 的每个端口是一个单元；类型3 的一整段端口共享一个单元。
# 单元用「内容派生的 key」标识：单端口 key = 端口号；类型3 key = "#首token"。
#   → 与规则顺序、端口增减无关，是增量更新的前提。
# 「槽位」slot = 该单元在树里的编号：classid 1:slot、cake handle (slot+1):、
#   过滤器 prio = slot*2（ip）/ slot*2+1（ipv6）。
# 槽位随状态文件持久保存：端口集合变化时沿用旧槽位 → 该端口的内核对象不被销毁
#   → 统计连续、无「未整形」空窗；只有真正新增/删除/改速率的端口才动内核。
units_from_specs() {
    awk '
        { if ($1 in seen) { tok[$1] = tok[$1] "," $3 } else { n++; seen[$1] = 1; order[n] = $1; tok[$1] = $3 } rate[$1] = $2 }
        END { for (i = 1; i <= n; i++) { k = order[i]; printf "%s %s %s\n", k, rate[k], tok[k] } }' "$1"
}

# 映射（UNITS，形如 "40000=1;40000;30 #40001-40111=2;40001-40111;20"）取值：
# $1=key $2=字段号（2=slot 3=tokens 4=rate）
map_get() {
    printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' -v k="$1" -v f="$2" 'NF && $1 == k { print $f; exit }'
}
map_has() { [ -n "$(map_get "$1" 2)" ]; }
# 新映射（NEWMAP）包含的 key 列表 / 取值
new_keys() { printf '%s\n' ${1:-} | tr ' ' '\n' | awk -F'[=;]' 'NF && $1 != "" { printf "%s ", $1 }'; }
new_slot() { printf '%s\n' ${1:-} | tr ' ' '\n' | awk -F'[=;]' -v k="$2" 'NF && $1 == k { print $2; exit }'; }
new_rate() { printf '%s\n' ${1:-} | tr ' ' '\n' | awk -F'[=;]' -v k="$2" 'NF && $1 == k { print $4; exit }'; }

# 为本次集合规划槽位：key 与覆盖端口都没变的沿用旧槽位；新增/变动的取「已有最大槽位+1」。
# 只增不复用 → 同一批里不会出现「新增与删除撞号」。
plan_units() {
    local specs="$1" key rate toks slot next=0 out=""
    for slot in $(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' 'NF && $1 != "" { print $2 }'); do
        case "$slot" in ''|*[!0-9]*) continue ;; esac
        [ "$slot" -gt "$next" ] && next="$slot"
    done
    next=$((next + 1))
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        slot="$(map_get "$key" 2)"
        if [ -z "$slot" ] || [ "$(map_get "$key" 3)" != "$toks" ]; then
            slot="$next"; next=$((next + 1))
        fi
        out="$out$key=$slot;$toks;$rate "
    done < <(units_from_specs "$specs")
    printf '%s' "$out"
}

# 整树重建后把映射压实成 1..N（与 gen_*_cmds 的分配顺序一致）
rebuild_units_map() {
    local specs="$1" key rate toks i=0 out=""
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        i=$((i + 1)); out="$out$key=$i;$toks;$rate "
    done < <(units_from_specs "$specs")
    UNITS="$out"
}

# 类存在性判断：交给 tc 自己解析 classid，避免手写十六进制比较出错
tc_has_class() {
    local out
    out="$(tc class show dev "$1" classid "$2" 2>/dev/null)" || return 1
    case "$out" in *"class htb"*) return 0 ;; *) return 1 ;; esac
}

# 增量更新前的完整性检查：根 / 兜底类 / 入口链 / ifb 树，以及每个已登记单元的类都还在。
# 任何一项缺失就返回 1 → 调用方退回整树重建（外部动过 tc 也不会把状态搞乱）。
validate_tree() {
    local iface="$1" key slot
    tc_qdisc_has "$iface" "qdisc htb 1:" || return 1
    tc_has_class "$iface" "1:$DEFAULT_CLASS" || return 1
    if [ "$TC_DIR" = "both" ]; then
        tc_qdisc_has "$iface" "qdisc ingress" || return 1
        tc_has_class "$IFB_NAME" "1:$DEFAULT_CLASS" || return 1
    fi
    for key in $(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' 'NF && $1 != "" { print $1 }'); do
        slot="$(map_get "$key" 2)"
        [ -n "$slot" ] || continue
        tc_has_class "$iface" "1:$slot" || return 1
        if [ "$TC_DIR" = "both" ]; then tc_has_class "$IFB_NAME" "1:$slot" || return 1; fi
    done
    return 0
}

# 生成一棵整形树的命令清单；$1=设备 $2=src_port|dst_port $3=specs
gen_tree_cmds() {
    local dev="$1" kw="$2" specs="$3" slot=0 key rate toks tok fam prio rh
    rh="$(tc_root_handle "$dev")"
    if [ -z "$rh" ] || [ "$rh" = "0:" ]; then
        # 隐式队列（或尚无可删的 root）：用 replace 直接顶替，不能 del
        echo "qdisc replace dev $dev root handle 1: htb default $DEFAULT_CLASS"
    else
        echo "qdisc del dev $dev root"
        echo "qdisc add dev $dev root handle 1: htb default $DEFAULT_CLASS"
    fi
    echo "class add dev $dev parent 1: classid 1:$DEFAULT_CLASS htb rate $TC_DEFAULT_RATE ceil $TC_DEFAULT_RATE quantum 1500"
    # 每个单元一个槽位（第 1 个 = 1、第 2 个 = 2 …），与 rebuild_units_map 的分配一致
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        slot=$((slot + 1))
        echo "class add dev $dev parent 1: classid 1:$slot htb rate ${rate}mbit ceil ${rate}mbit burst 32k cburst 32k quantum 1500"
        echo "qdisc add dev $dev parent 1:$slot handle $((slot + 1)): cake bandwidth ${rate}mbit $TC_CAKE_OPTS"
        # 双栈：同一 prio 混协议族会被内核拒绝。每个单元独占一对 prio，
        # 于是「按 prio 删除」能精确删掉某个单元的过滤器 —— 这是增量更新的前提
        for tok in $(printf '%s' "$toks" | tr ',' ' '); do
            for fam in ip ipv6; do
                case "$fam" in ip) prio=$((slot * 2)) ;; *) prio=$((slot * 2 + 1)) ;; esac
                echo "filter add dev $dev parent 1: protocol $fam prio $prio flower ip_proto tcp $kw $tok classid 1:$slot"
                echo "filter add dev $dev parent 1: protocol $fam prio $prio flower ip_proto udp $kw $tok classid 1:$slot"
            done
        done
    done < <(units_from_specs "$specs")
    return 0
}

# 生成入方向重定向清单；$1=物理接口 $2=specs（只重定向我们关心的端口）
# prio 必须与 gen_tree_cmds 的槽位编号一致，这样才能按 prio 精确增删
gen_ingress_cmds() {
    local dev="$1" specs="$2" map="${3:-}" i=0 key rate toks tok fam prio slot
    tc_qdisc_has "$dev" "qdisc ingress" && echo "qdisc del dev $dev ingress"
    echo "qdisc add dev $dev handle ffff: ingress"
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        i=$((i + 1))
        slot="$(new_slot "$map" "$key")"; [ -n "$slot" ] || slot="$i"
        for tok in $(printf '%s' "$toks" | tr ',' ' '); do
            for fam in ip ipv6; do
                case "$fam" in ip) prio=$((slot * 2)) ;; *) prio=$((slot * 2 + 1)) ;; esac
                echo "filter add dev $dev parent ffff: protocol $fam prio $prio flower ip_proto tcp dst_port $tok action mirred egress redirect dev $IFB_NAME"
                echo "filter add dev $dev parent ffff: protocol $fam prio $prio flower ip_proto udp dst_port $tok action mirred egress redirect dev $IFB_NAME"
            done
        done
    done < <(units_from_specs "$specs")
    return 0
}

# 下发一棵树；失败则回滚该设备的整形配置
apply_tree() {
    local dev="$1" kw="$2" specs="$3"
    if ! gen_tree_cmds "$dev" "$kw" "$specs" | run_tc_cmds; then
        err "$dev 的整形树下发失败，正在回滚该接口"
        [ "${DRY_RUN:-0}" != "1" ] && tc qdisc del dev "$dev" root >/dev/null 2>&1
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 增量下发
# 只动「新增 / 删除 / 速率变化」的单元，其余内核对象一个都不碰：
#   - 未变化端口的类与 cake 队列保持原样 → tc 统计连续（Sent/丢弃不归零）
#   - 不删根 qdisc → 没有「未整形」窗口
#   - 命令数只与「本次变化的端口数」成正比，与总端口数无关
# $1=设备 $2=端口关键字 $3=specs $4=新映射(NEWMAP)
gen_delta_tree() {
    local dev="$1" kw="$2" specs="$3" map="$4" key rate toks slot fam prio tok nslot nrate
    # 1) 先删：旧映射里「已不需要」或「槽位变了」的单元（先删后加，避免撞号）
    for key in $(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' 'NF && $1 != "" { print $1 }'); do
        slot="$(map_get "$key" 2)"; [ -n "$slot" ] || continue
        nslot="$(new_slot "$map" "$key")"
        [ -n "$nslot" ] && [ "$nslot" = "$slot" ] && continue      # 原槽位保留 → 内核对象不动
        for fam in ip ipv6; do
            case "$fam" in ip) prio=$((slot * 2)) ;; *) prio=$((slot * 2 + 1)) ;; esac
            echo "filter del dev $dev parent 1: protocol $fam prio $prio"
        done
        echo "class del dev $dev parent 1: classid 1:$slot"
    done
    # 2) 再加：新单元建「类 + cake + 过滤器」；槽位沿用但速率变了的只改速率
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        nslot="$(new_slot "$map" "$key")"; nrate="$(new_rate "$map" "$key")"
        [ -n "$nrate" ] || nrate="$rate"
        slot="$(map_get "$key" 2)"
        if [ "$slot" = "$nslot" ]; then
            # 槽位沿用：只有速率变了才动（class change + qdisc change 都不会重置统计）
            [ "$(map_get "$key" 4)" = "$nrate" ] && continue
            echo "class change dev $dev parent 1: classid 1:$nslot htb rate ${nrate}mbit ceil ${nrate}mbit burst 32k cburst 32k quantum 1500"
            echo "qdisc change dev $dev parent 1:$nslot handle $((nslot + 1)): cake bandwidth ${nrate}mbit $TC_CAKE_OPTS"
        else
            # 新建（含槽位迁移：旧对象已在上面删掉）
            echo "class add dev $dev parent 1: classid 1:$nslot htb rate ${nrate}mbit ceil ${nrate}mbit burst 32k cburst 32k quantum 1500"
            echo "qdisc add dev $dev parent 1:$nslot handle $((nslot + 1)): cake bandwidth ${nrate}mbit $TC_CAKE_OPTS"
            for tok in $(printf '%s' "$toks" | tr ',' ' '); do
                for fam in ip ipv6; do
                    case "$fam" in ip) prio=$((nslot * 2)) ;; *) prio=$((nslot * 2 + 1)) ;; esac
                    echo "filter add dev $dev parent 1: protocol $fam prio $prio flower ip_proto tcp $kw $tok classid 1:$nslot"
                    echo "filter add dev $dev parent 1: protocol $fam prio $prio flower ip_proto udp $kw $tok classid 1:$nslot"
                done
            done
        fi
    done < <(units_from_specs "$specs")
    return 0
}

# 入方向重定向（物理接口 ingress 链）的增量：只增删变化的端口
# $1=物理接口 $2=specs $3=新映射
gen_delta_redirect() {
    local dev="$1" specs="$2" map="$3" key rate toks slot tok fam prio nslot
    for key in $(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' 'NF && $1 != "" { print $1 }'); do
        slot="$(map_get "$key" 2)"; toks="$(map_get "$key" 3)"; [ -n "$slot" ] || continue
        nslot="$(new_slot "$map" "$key")"
        [ -n "$nslot" ] && [ "$nslot" = "$slot" ] && continue
        for fam in ip ipv6; do
            case "$fam" in ip) prio=$((slot * 2)) ;; *) prio=$((slot * 2 + 1)) ;; esac
            echo "filter del dev $dev parent ffff: protocol $fam prio $prio"
        done
    done
    while read -r key rate toks; do
        [ -n "$key" ] || continue
        nslot="$(new_slot "$map" "$key")"
        [ "$(map_get "$key" 2)" = "$nslot" ] && continue      # 已存在且槽位未变 → 重定向无需变动
        for tok in $(printf '%s' "$toks" | tr ',' ' '); do
            for fam in ip ipv6; do
                case "$fam" in ip) prio=$((nslot * 2)) ;; *) prio=$((nslot * 2 + 1)) ;; esac
                echo "filter add dev $dev parent ffff: protocol $fam prio $prio flower ip_proto tcp dst_port $tok action mirred egress redirect dev $IFB_NAME"
                echo "filter add dev $dev parent ffff: protocol $fam prio $prio flower ip_proto udp dst_port $tok action mirred egress redirect dev $IFB_NAME"
            done
        done
    done < <(units_from_specs "$specs")
    return 0
}

# ------------------------------------------------------------------ 应用（幂等）
apply_all() {
    warn_if_test_mode
    [ -f "$TC_STATE" ] && . "$TC_STATE"      # 取回上次的能力探测结论与配置指纹
    ensure_deps "${QUICK:-}" || return 1
    local iface specs ORIG_ROOT="" IFB_CREATED=0
    iface="$(tc_detect_iface)"
    [ -n "$iface" ] || { err "未能识别出接口，请设置 TC_IFACE=eth0"; return 1; }
    ip link show "$iface" >/dev/null 2>&1 || { err "接口不存在：$iface"; return 1; }

    gen_err="$(mktemp)"
    specs="$(mktemp)"; gen_specs > "$specs" 2>"$gen_err"
    # 两级指纹：
    #   STATIC_SIG = 接口/方向/cake 参数/兜底速率/ifb 名/端口来源 → 变了只能整树重建
    #   UNITS_SIG  = 单元集合（端口 + 速率）→ 变了走增量更新，只动变化的那几个端口
    local static_sig units_sig stored_static stored_units need_full=0 mode=""
    static_sig="$(echo "$iface|$TC_DIR|$TC_CAKE_OPTS|$TC_DEFAULT_RATE|$IFB_NAME|$PORT_SOURCE" | md5sum | cut -d' ' -f1)"
    units_sig="$(units_from_specs "$specs" | md5sum | cut -d' ' -f1)"
    stored_static="$(sed -n "s/^STATIC_SIG='\([^']*\)'.*/\1/p" "$TC_STATE" 2>/dev/null | head -1)"
    stored_units="$(sed -n "s/^UNITS_SIG='\([^']*\)'.*/\1/p" "$TC_STATE" 2>/dev/null | head -1)"
    [ "${FORCE:-0}" = "1" ] && need_full=1
    [ -z "$stored_static" ] && need_full=1
    if [ -n "$stored_static" ] && [ "$static_sig" != "$stored_static" ]; then need_full=1; fi
    if [ "$need_full" = "0" ] && ! validate_tree "$iface"; then
        need_full=1
        warn "整形树不完整（被外部改动过或残留），本次整树重建"
    fi
    # 完全没变化 → 直接返回（巡检路径保持安静，人工执行给一句反馈）
    if [ "$need_full" = "0" ] && [ "$units_sig" = "$stored_units" ]; then
        if [ -t 1 ]; then ok "配置与上次一致，未做任何改动（如需强制重建：bash $0 apply force）"; fi
        rm -f "$specs" "$gen_err"; return 0
    fi
    [ "$need_full" = "1" ] && mode="整树重建" || mode="增量更新"

    # 确实要动了，这时才把生成阶段的告警打出来（巡检无变化时不再刷屏）
    [ -s "$gen_err" ] && sed 's/^/  /' "$gen_err" >&2
    # 每次改动都记一条事件（谁触发都记：巡检自动 / 人工 / 开机）
    if [ "${DRY_RUN:-0}" != "1" ]; then
        printf '%s %s | 接口=%s | 桶数=%s | 端口: %s\n' \
            "$(date '+%F %T')" "$mode" "$iface" \
            "$(units_from_specs "$specs" | awk 'END{print NR+0}')" \
            "$(awk '{printf "%s ", $3}' "$specs" 2>/dev/null)" >> "$EVENT_LOG" 2>/dev/null
    fi
    if [ ! -s "$specs" ]; then
        if [ ! -s "$RULE_FILE" ]; then
            warn "规则文件为空：本次只清理旧配置（请在菜单 1 添加规则）"
        else
            warn "没有可用的规则（规则里的端口当前都没在监听 / 类型或格式不合法），本次只保留兜底类；端口上线后巡检会自动建类"
        fi
    fi

    info "整形接口：$iface（方向：$TC_DIR）"
    ORIG_ROOT="$(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="qdisc"){print $(i+1); exit}}')"
    case "$ORIG_ROOT" in htb) ORIG_ROOT="";; esac   # 已是我们的（或别人的）htb，不必还原

    NEWMAP=""
    if [ "$need_full" = "1" ]; then
        # ---- 整树重建（结构变了 / 状态缺失 / 树被破坏 / force）----
        apply_tree "$iface" src_port "$specs" || { rm -f "$specs" "$gen_err"; return 1; }
    else
        # ---- 增量更新：只动变化的端口，其余端口的类与统计原样保留 ----
        NEWMAP="$(plan_units "$specs")"
        if ! gen_delta_tree "$iface" src_port "$specs" "$NEWMAP" | run_tc_cmds; then
            warn "出方向增量下发失败，改为整树重建"
            apply_tree "$iface" src_port "$specs" || { rm -f "$specs" "$gen_err"; return 1; }
            need_full=1
        fi
    fi

    # 入方向（ifb 中转；内核不能直接整形入站）
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
                if [ "$need_full" = "1" ]; then
                    # 先把 ifb 上的整形树建好，再把入站流量引流进去（避免短暂引到未配置的 ifb）
                    apply_tree "$IFB_NAME" dst_port "$specs" || warn "$IFB_NAME 整形树创建失败，入方向未限速"
                    if ! gen_ingress_cmds "$iface" "$specs" | run_tc_cmds; then
                        warn "入方向重定向下发失败，入方向未限速"
                    fi
                else
                    # 增量：ifb 内的类/过滤器 + 物理接口上的重定向，都只动变化的端口
                    if ! gen_delta_tree "$IFB_NAME" dst_port "$specs" "$NEWMAP" | run_tc_cmds; then
                        warn "入方向增量下发失败，改为重建入方向"
                        apply_tree "$IFB_NAME" dst_port "$specs" || warn "$IFB_NAME 整形树创建失败，入方向未限速"
                        gen_ingress_cmds "$iface" "$specs" | run_tc_cmds || warn "入方向重定向下发失败，入方向未限速"
                    elif ! gen_delta_redirect "$iface" "$specs" "$NEWMAP" | run_tc_cmds; then
                        warn "入方向重定向增量失败，改为重建入口链"
                        gen_ingress_cmds "$iface" "$specs" | run_tc_cmds || warn "入方向重定向下发失败，入方向未限速"
                    fi
                fi
            else
                warn "无法创建 ifb 设备，入方向未限速（出方向已生效）"
            fi
        else
            warn "本机不支持 ifb，入方向未限速（出方向已生效）；如需双向请安装 ifb 模块"
        fi
    fi

    # 更新槽位映射：整树重建 → 压实为 1..N；增量 → 采用本次规划的新映射
    if [ "$need_full" = "1" ]; then rebuild_units_map "$specs"; else UNITS="$NEWMAP"; fi

    rm -f "$specs" "$gen_err"
    mkdir -p "$STATE_DIR" 2>/dev/null
    {
        printf "IFACE='%s'\n" "$iface"
        printf "IFB='%s'\n" "$(ip link show "$IFB_NAME" >/dev/null 2>&1 && echo "$IFB_NAME")"
        printf "IFB_CREATED='%s'\n" "$IFB_CREATED"
        printf "ORIG_ROOT='%s'\n" "$ORIG_ROOT"
        printf "STATIC_SIG='%s'\n" "$static_sig"
        printf "UNITS_SIG='%s'\n" "$units_sig"
        printf "UNITS='%s'\n" "$UNITS"
        printf "CAPS_OK='%s'\n" "${CAPS_OK:-0}"
        printf "IFB_OK='%s'\n" "${IFB_OK:-0}"
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
        if tc_qdisc_has "$iface" "qdisc ingress"; then
            tc qdisc del dev "$iface" ingress >/dev/null 2>&1 && did=1
        fi
        if tc_qdisc_has "$iface" "qdisc htb 1:"; then
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
        # cake 的 parent 是 1:<槽位> → 从状态文件的 UNITS 映射反查端口与速率
        port="$(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' -v s="$idx" 'NF && $2 == s { sub(/,.*/, "", $3); print $3; exit }')"
        rate="$(printf '%s\n' ${UNITS:-} | tr ' ' '\n' | awk -F'[=;]' -v s="$idx" 'NF && $2 == s { print $4; exit }')"
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
        echo "PORT_SOURCE=\"$PORT_SOURCE\""
        echo "REFRESH_SEC=\"$REFRESH_SEC\""
        echo "WARN_CLASSES=\"$WARN_CLASSES\""
        echo "IFB_NAME=\"$IFB_NAME\""
        echo "AUTO_INSTALL=\"$AUTO_INSTALL\""
    } > "$CONFIG_FILE" 2>/dev/null
}

# ------------------------------------------------------------------ 服务 / 自启
deploy_service() {
    has_systemd || return 0
    # 版本变化时刷新单元描述（幂等：内容一致就不动）
    if [ -f "$SERVICE_FILE" ] && grep -q "port_limiter v$VERSION" "$SERVICE_FILE" 2>/dev/null; then
        return 0
    fi
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
}

has_systemd() { need_cmd systemctl && [ -d /run/systemd/system ]; }

# ---- 自动巡检定时器（默认模式）：端口上线/下线后自动建类或收回 ----
REFRESH_SERVICE_FILE="${REFRESH_SERVICE_FILE:-/etc/systemd/system/port-limiter-refresh.service}"
REFRESH_TIMER_FILE="${REFRESH_TIMER_FILE:-/etc/systemd/system/port-limiter-refresh.timer}"

deploy_refresh_timer() {
    has_systemd || return 0
    if [ "${REFRESH_SEC:-0}" -le 0 ]; then disable_refresh_timer; return 0; fi
    # 已是最新版本就不动（幂等；升级脚本后单元会自动刷新）
    if [ -f "$REFRESH_TIMER_FILE" ] && grep -q "port_limiter v$VERSION" "$REFRESH_TIMER_FILE" 2>/dev/null; then
        systemctl is-active port-limiter-refresh.timer >/dev/null 2>&1 || systemctl start port-limiter-refresh.timer >/dev/null 2>&1
        return 0
    fi
    cat > "$REFRESH_SERVICE_FILE" <<EOF
# port_limiter v$VERSION
[Unit]
Description=port_limiter auto-refresh (扫描监听端口变化并自动重建)
After=network-online.target

[Service]
Type=oneshot
# 巡检无变化时不产生日志；变更事件写入 /var/log/port_limiter.log
LogLevelMax=notice
ExecStart=$SCRIPT_PATH apply
EOF
    cat > "$REFRESH_TIMER_FILE" <<EOF
# port_limiter v$VERSION
[Unit]
Description=port_limiter 自动巡检定时器（每 ${REFRESH_SEC} 秒）

[Timer]
OnBootSec=20s
OnUnitActiveSec=${REFRESH_SEC}s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now port-limiter-refresh.timer >/dev/null 2>&1
}

disable_refresh_timer() {
    has_systemd || return 0
    systemctl disable --now port-limiter-refresh.timer >/dev/null 2>&1
    rm -f "$REFRESH_TIMER_FILE" "$REFRESH_SERVICE_FILE" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
}

# 首次运行把单元装好（幂等；配置未变时巡检本身几乎零开销）
ensure_units() {
    has_systemd || return 0
    # 两个单元都由「内容随版本刷新」的幂等写入负责，这里直接调用即可
    deploy_service
    deploy_refresh_timer
    systemctl enable port-limiter.service >/dev/null 2>&1
}

enable_autostart() {
    if has_systemd; then
        deploy_service
        deploy_refresh_timer
        systemctl enable port-limiter.service >/dev/null 2>&1 \
            && ok "已设置开机自启（systemd）" || { err "systemd 启用失败"; return 1; }
        [ "${REFRESH_SEC:-0}" -gt 0 ] && ok "自动巡检已启用（每 ${REFRESH_SEC} 秒扫描一次监听端口变化）"
        return 0
    fi
    if [ -d /etc/local.d ]; then
        printf '#!/bin/sh\n%s apply boot\n' "$SCRIPT_PATH" > /etc/local.d/port_limiter.start
        chmod +x /etc/local.d/port_limiter.start
        rc-update add local default >/dev/null 2>&1
        ok "已设置开机自启（OpenRC /etc/local.d）；非 systemd 环境无内置巡检，可自行加 cron"
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
        disable_refresh_timer
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

    read -r -p "端口（支持逗号与范围，可写一大段如 40001-41111）: " ports
    validate_ports "$ports" || { err "端口表达式非法：$ports"; return 1; }
    if [ "$PORT_SOURCE" = "listen" ]; then
        info "自动跟踪已开启：只会为「本机在监听」的端口建类，端口上线后 $REFRESH_SEC 秒内自动限速"
    fi

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
    # 表头手工对齐：awk 的 %-Ns 按「字节」补齐，中文列会错位
    printf '%s%*s%s%*s%s%*s%s%*s%s\n' "序号" 2 "" "类型" 3 "" "端口" 19 "" "Mbps" 5 "" "备注"
    awk -F'|' '{printf "%-5d %-6s %-22s %-8s %s\n", NR,$1,$2,$3,$4}' "$RULE_FILE"
    echo
    info "类型：1 离散端口各自独立 | 2 连续端口各自独立 | 3 连续端口共享额度"
    info "删除时输入「序号」即可（如输入 2 删除第 2 条）"
}

menu_settings() {
    echo
    info "=== 整形参数（写入 $CONFIG_FILE 持久化）==="
    echo " 1. 出接口          当前：$TC_IFACE"
    echo " 2. 整形方向        当前：$TC_DIR（both 双向 / egress 仅出方向）"
    echo " 3. 兜底类速率      当前：$TC_DEFAULT_RATE（未匹配流量不受限）"
    echo " 4. cake 参数       当前：$TC_CAKE_OPTS"
    echo " 5. 自动巡检间隔    当前：${REFRESH_SEC} 秒（0 = 不安装巡检定时器）"
    echo " 6. 端口来源        当前：$PORT_SOURCE（listen=只为在监听的端口建类 / config=全量建类）"
    echo " 7. 规模提醒阈值    当前：$WARN_CLASSES（计划建类数超过它只提醒不拦截；0 = 关闭）"
    echo " 8. 入方向网卡名    当前：$IFB_NAME"
    echo " 9. 自动安装依赖    当前：$AUTO_INSTALL"
    read -r -p "选择要修改的项（回车返回）: " c
    case "${c:-}" in
        1) read -r -p "出接口（auto=自动识别）: " v; [ -n "$v" ] && TC_IFACE="$v" ;;
        2) read -r -p "整形方向 both|egress: " v
           case "$v" in both|egress) TC_DIR="$v" ;; *) err "只能填 both 或 egress"; return 1 ;; esac ;;
        3) read -r -p "兜底类速率（如 10gbit）: " v; [ -n "$v" ] && TC_DEFAULT_RATE="$v" ;;
        4) read -r -p "cake 参数: " v; [ -n "$v" ] && TC_CAKE_OPTS="$v" ;;
        5) read -r -p "自动巡检间隔秒数（0=关闭）: " v
           case "$v" in ''|*[!0-9]*) err "必须是整数秒"; return 1 ;; esac
           REFRESH_SEC="$v" ;;
        6) read -r -p "端口来源 listen|config: " v
           case "$v" in listen|config) PORT_SOURCE="$v" ;; *) err "只能填 listen 或 config"; return 1 ;; esac ;;
        7) read -r -p "规模提醒阈值（0=关闭提醒）: " v
           case "$v" in ''|*[!0-9]*) err "必须是整数"; return 1 ;; esac
           WARN_CLASSES="$v" ;;
        8) read -r -p "入方向网卡名（换名后需重新 apply）: " v; [ -n "$v" ] && IFB_NAME="$v" ;;
        9) read -r -p "自动安装依赖 1/0: " v; [ -n "$v" ] && AUTO_INSTALL="$v" ;;
        "") return 0 ;;
        *) err "无效选择"; return 1 ;;
    esac
    write_config
    ok "已保存到 $CONFIG_FILE"
    has_systemd && deploy_refresh_timer
}

menu_status() {
    echo
    info "=== 运行状态 ==="
    local iface
    [ -f "$TC_STATE" ] && . "$TC_STATE"
    iface="${IFACE:-$(tc_detect_iface)}"
    echo "出接口：${iface:-未识别}   整形方向：$TC_DIR"
    if [ -n "$iface" ] && tc_qdisc_has "$iface" "qdisc htb 1:"; then
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

# 查看 + 删除合并：列表带序号，输入序号即删除
menu_view_del() {
    menu_view_rules
    [ -s "$RULE_FILE" ] || return 0
    echo
    read -r -p "输入规则序号即可删除（回车返回）: " num
    [ -n "${num:-}" ] || return 0
    case "$num" in ''|*[!0-9]*) err "请输入序号"; return 1;; esac
    resolve_line "$num" >/dev/null || { err "没有这条规则（序号需在 1..$(count_rules) 之间）"; return 1; }
    if delete_line "$num"; then
        ok "已删除第 $num 条规则，正在重新应用"
        apply_all
    else
        err "删除失败"
    fi
}

# 开机自启 + 自动巡检 的总开关
toggle_autostart() {
    echo
    if has_systemd; then
        if systemctl is-enabled port-limiter.service >/dev/null 2>&1; then
            echo "当前：开机自启=已启用，自动巡检=$([ -f "$REFRESH_TIMER_FILE" ] && echo 已启用 || echo 未启用)"
            read -r -p "要全部取消吗？(y/N): " a
            case "$a" in y|Y) disable_autostart ;; *) info "保持不变" ;; esac
        else
            echo "当前：开机自启=未启用"
            read -r -p "要启用吗？(Y/n): " a
            case "${a:-y}" in y|Y) enable_autostart; deploy_refresh_timer ;; *) info "保持不变" ;; esac
        fi
    else
        info "非 systemd 环境：自启写入 local.d / rc.local（无内置巡检，可用 cron 定时执行 apply）"
        read -r -p "要启用自启吗？(Y/n): " a
        case "${a:-y}" in y|Y) enable_autostart ;; esac
    fi
}

# 一键卸载：停服务 + 清整形 + 删单元与残留
#   默认保留规则与配置（便于重装后继续用）；`uninstall purge` 连配置目录一起删
do_uninstall() {
    local mode="${1:-}"
    info "开始卸载 port_limiter ..."
    if has_systemd; then
        systemctl disable --now port-limiter-refresh.timer >/dev/null 2>&1
        systemctl stop port-limiter-refresh.service >/dev/null 2>&1
        systemctl disable --now port-limiter.service >/dev/null 2>&1
        rm -f "$REFRESH_TIMER_FILE" "$REFRESH_SERVICE_FILE" "$SERVICE_FILE" 2>/dev/null
        systemctl daemon-reload 2>/dev/null
        ok "已停止并删除 systemd 单元"
    fi
    stop_all
    rm -f "$MODULES_FILE" 2>/dev/null
    rm -rf /run/port_limiter 2>/dev/null
    if [ "$mode" = "purge" ]; then
        rm -rf "$WORK_DIR" 2>/dev/null
        ok "已删除 $WORK_DIR（含规则、配置、脚本）"
    else
        rm -f "$TC_STATE" 2>/dev/null
        ok "已保留 $WORK_DIR（规则与配置还在；连它一起删：bash $SCRIPT_PATH uninstall purge）"
    fi
    ok "卸载完成"
}

interactive() {
    require_root
    mkdir -p "$WORK_DIR"; touch "$RULE_FILE"
    fixate_self
    ensure_units
    ensure_deps || exit 1
    ok "port_limiter v$VERSION 已就绪（tc HTB+cake / TCP+UDP 双栈 / 不限连接数）"
    if [ "${REFRESH_SEC:-0}" -gt 0 ] && has_systemd; then
        info "自动跟踪已启用：每 ${REFRESH_SEC} 秒巡检监听端口变化（规则里可放心写大范围端口）"
    fi
    while true; do
        echo
        echo "=============================================="
        echo "   端口峰值带宽管理面板  v$VERSION"
        echo "=============================================="
        echo " 1. 添加限速规则"
        echo " 2. 查看 / 删除规则（输入序号即删除）"
        echo " 3. 立即应用 / 重启整形"
        echo " 4. 停止并移除全部整形"
        echo " 5. 运行状态 + 能力自检"
        echo " 6. 统计（每端口通过量 / 排队丢弃）"
        echo " 7. 开机自启 / 自动巡检 开关"
        echo " 8. 修改整形参数（接口 / 方向 / 巡检间隔等）"
        echo " 9. 卸载（停止 + 清理残留）"
        echo " 0. 退出"
        echo "=============================================="
        read -r -p "请输入菜单数字: " choice
        case "$choice" in
            1) menu_add_rule ;;
            2) menu_view_del ;;
            3) FORCE=1 apply_all ;;
            4) stop_all ;;
            5) menu_status ;;
            6) read -r -p "采样秒数（默认 10）: " s; show_stats "${s:-10}" ;;
            7) toggle_autostart ;;
            8) menu_settings ;;
            9) read -r -p "确认卸载并清理残留？(y/N): " a; case "$a" in y|Y) do_uninstall ;; *) warn "已取消" ;; esac ;;
            0) ok "再见"; exit 0 ;;
            *) err "无效输入" ;;
        esac
    done
}

main() {
    case "${1:-}" in
        apply)  require_root
                case "${2:-}" in
                    boot|force) FORCE=1 ;;
                    *)          QUICK=quick ;;      # 巡检路径：复用上次的能力探测结论
                esac
                ensure_units
                apply_all; exit $? ;;
        stop)      require_root; stop_all; exit $? ;;
        uninstall) require_root; do_uninstall "${2:-}"; exit $? ;;
        check)     require_root; DRY_RUN=1 apply_all; exit $? ;;
        stats)     require_root; show_stats "${2:-10}"; exit $? ;;
        caps)      require_root; ensure_deps >/dev/null 2>&1; menu_status; exit 0 ;;
        "")        interactive ;;
        *)         echo "端口峰值带宽整形器 v$VERSION（tc HTB+cake）"
                   echo "用法: $0 [apply [boot|force]|stop|uninstall [purge]|check|stats [秒]|caps]"
                   exit 1 ;;
    esac
}

main "$@"
