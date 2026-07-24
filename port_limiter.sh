#!/bin/bash

# ====================================================
# Nftables 端口限速交互式管理脚本 (全功能内存兼容版)
# 核心特性: 完美支持 bash <(curl...) 一键执行及开机自启
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORK_DIR="/etc/port_limiter"
RULE_FILE="${WORK_DIR}/rules.conf"
SCRIPT_PATH="${WORK_DIR}/port_limiter.sh"
SERVICE_FILE="/etc/systemd/system/port-limiter.service"

# GitHub 脚本直链 (用于内存执行时的自我固化)
REMOTE_URL="https://raw.githubusercontent.com/otaku-say/port_limiter/refs/heads/main/port_limiter.sh"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行。${NC}"
  exit 1
fi

check_env() {
    local run_mode=$1
    if ! command -v nft &> /dev/null; then
        if [ "$run_mode" == "boot" ]; then
            echo "Nftables not found during boot. Exiting."
            exit 1
        fi
        echo -e "${YELLOW}检测到未安装 nftables，正在自动安装...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y nftables >/dev/null 2>&1
    fi

    mkdir -p "$WORK_DIR"
    touch "$RULE_FILE"
    
    # 核心黑科技：自我感知与固化逻辑
    if [ "$(realpath "$0" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        # 如果 $0 是 bash 或包含 /dev/fd/，说明是通过 bash <(curl...) 在内存中运行
        if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/dev/fd/"* ]] || [ ! -f "$0" ]; then
            curl -sL "$REMOTE_URL" -o "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
        else
            # 普通的本地实体文件运行，直接复制
            cp "$0" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
        fi
    fi
}

deploy_service() {
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Advanced Port Limiter Service
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
        systemctl daemon-reload
    fi
}

apply_rules() {
    echo -e "${BLUE}正在下发 Nftables 安全限速规则...${NC}"
    
    nft add table inet port_limiter 2>/dev/null
    nft flush table inet port_limiter
    
    nft add chain inet port_limiter input '{ type filter hook input priority 0; policy accept; }'
    nft add chain inet port_limiter output '{ type filter hook output priority 0; policy accept; }'
    nft add chain inet port_limiter forward '{ type filter hook forward priority 0; policy accept; }'

    local chains=("input" "output" "forward")
    for chain in "${chains[@]}"; do
        nft add rule inet port_limiter $chain tcp flags \& \(fin\|syn\|rst\|ack\) == ack meta length \< 100 accept
    done

    local active_count=0
    while IFS='|' read -r id type ports mbps desc; do
        [ -z "$id" ] && continue
        
        local kbytes=$(( mbps * 125 ))
        local burst_kb=$(( kbytes * 2 )) 
        
        case $type in
            1) 
                local port_fmt="{ $(echo "$ports" | sed 's/,/, /g') }"
                for chain in "${chains[@]}"; do
                    nft add rule inet port_limiter $chain tcp dport "$port_fmt" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                    nft add rule inet port_limiter $chain udp dport "$port_fmt" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                    nft add rule inet port_limiter $chain tcp sport "$port_fmt" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                    nft add rule inet port_limiter $chain udp sport "$port_fmt" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                done
                ;;
            2) 
                nft add set inet port_limiter limit_in_tcp_${id} '{ type inet_service; flags dynamic; }'
                nft add set inet port_limiter limit_out_tcp_${id} '{ type inet_service; flags dynamic; }'
                
                nft add rule inet port_limiter input tcp dport "$ports" update @limit_in_tcp_${id} '{ tcp dport limit rate over '$kbytes' kbytes/second burst '$burst_kb' kbytes }' drop
                nft add rule inet port_limiter forward tcp dport "$ports" update @limit_in_tcp_${id} '{ tcp dport limit rate over '$kbytes' kbytes/second burst '$burst_kb' kbytes }' drop
                nft add rule inet port_limiter output tcp sport "$ports" update @limit_out_tcp_${id} '{ tcp sport limit rate over '$kbytes' kbytes/second burst '$burst_kb' kbytes }' drop
                nft add rule inet port_limiter forward tcp sport "$ports" update @limit_out_tcp_${id} '{ tcp sport limit rate over '$kbytes' kbytes/second burst '$burst_kb' kbytes }' drop
                
                nft add rule inet port_limiter input udp dport "$ports" limit rate over $kbytes kbytes/second drop
                nft add rule inet port_limiter output udp sport "$ports" limit rate over $kbytes kbytes/second drop
                ;;
            3) 
                for chain in "${chains[@]}"; do
                    nft add rule inet port_limiter $chain tcp dport "$ports" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                    nft add rule inet port_limiter $chain udp dport "$ports" limit rate over $kbytes kbytes/second drop
                    nft add rule inet port_limiter $chain tcp sport "$ports" limit rate over $kbytes kbytes/second burst $burst_kb kbytes drop
                    nft add rule inet port_limiter $chain udp sport "$ports" limit rate over $kbytes kbytes/second drop
                done
                ;;
        esac
        ((active_count++))
    done < "$RULE_FILE"

    if [ "$active_count" -gt 0 ]; then
        echo -e "${GREEN}✅ 成功应用 $active_count 条限速规则 (附带防断网 TCP 优化)!${NC}"
    else
        echo -e "${YELLOW}当前无生效规则，已放行全部流量。${NC}"
    fi
}

stop_rules() {
    echo -e "${BLUE}正在清空规则...${NC}"
    nft delete table inet port_limiter 2>/dev/null
    echo -e "${GREEN}✅ 规则已完全移除！${NC}"
}

menu_add_rule() {
    echo -e "\n${YELLOW}=== 添加限速规则 ===${NC}"
    echo "1. 离散端口独立限速 (例如: 80,443)"
    echo "2. 连续端口独立限速 (例如: 40000-50000 每个独享)"
    echo "3. 连续端口共享限额 (例如: 40000-50000 总共用)"
    read -p "选择: " type
    [[ ! "$type" =~ ^[1-3]$ ]] && echo -e "${RED}无效选择${NC}" && return
    
    read -p "端口范围: " ports
    read -p "带宽(Mbps): " mbps
    [[ ! "$mbps" =~ ^[0-9]+$ ]] && echo -e "${RED}带宽必须是纯数字${NC}" && return
    
    read -p "备注: " desc
    
    local id=$(date +%s)
    echo "${id}|${type}|${ports}|${mbps}|${desc:-无}" >> "$RULE_FILE"
    echo -e "${GREEN}✅ 添加成功! 规则ID: ${id}${NC}"
    
    read -p "立即应用? (y/n): " apply_now
    [[ "${apply_now:-y}" == "y" ]] && apply_rules
}

menu_view_rules() {
    echo -e "\n${YELLOW}=== 当前保存的限速规则 ===${NC}"
    if [ ! -s "$RULE_FILE" ]; then
        echo -e "${BLUE}没有任何限速记录。${NC}"
        return
    fi
    cat "$RULE_FILE" | awk -F'|' 'BEGIN{printf "%-12s | %-6s | %-15s | %-8s | %s\n","ID","模式","端口","Mbps","备注"} {printf "%-12s | %-6s | %-15s | %-8s | %s\n",$1,$2,$3,$4,$5}'
}

menu_del_rule() {
    menu_view_rules
    if [ ! -s "$RULE_FILE" ]; then return; fi
    echo ""
    read -p "输入要删除的规则 ID: " del_id
    if grep -q "^${del_id}|" "$RULE_FILE" 2>/dev/null; then
        sed -i "/^${del_id}|/d" "$RULE_FILE"
        echo -e "${GREEN}✅ 规则已删除。${NC}"
        apply_rules
    else
        echo -e "${RED}❌ 未找到匹配的 ID。${NC}"
    fi
}

menu_status() {
    echo -e "\n${YELLOW}=== 运行状态 ===${NC}"
    nft list table inet port_limiter 2>/dev/null || echo -e "${RED}未加载底层规则表。${NC}"
    echo ""
    if systemctl is-enabled port-limiter.service &>/dev/null; then
        echo -e "开机自启: ${GREEN}已启用${NC}"
    else
        echo -e "开机自启: ${RED}未启用${NC}"
    fi
}

if [ "$1" == "apply" ]; then
    check_env "$2"
    apply_rules
    exit 0
elif [ "$1" == "stop" ]; then
    stop_rules
    exit 0
fi

check_env "interactive"
deploy_service

while true; do
    echo -e "\n=============================================="
    echo -e "        ${BLUE}网络端口双栈限速管理面板${NC}        "
    echo -e "=============================================="
    echo " 1. 添加端口限速规则"
    echo " 2. 查看当前保存的规则"
    echo " 3. 删除某条限速规则"
    echo " 4. 立即生效/重启限速"
    echo " 5. 停止并移除所有限速"
    echo " 6. 查看系统运行状态"
    echo " 7. 设置限速开机自启"
    echo " 8. 取消限速开机自启"
    echo " 0. 退出脚本"
    echo "=============================================="
    read -p "请输入数字或直接粘贴 10 位 ID 删除: " choice

    if [[ "$choice" =~ ^[0-9]{10}$ ]]; then
        echo -e "\n${YELLOW}💡 智能识别：检测到您直接输入了规则 ID，正在为您执行删除...${NC}"
        if grep -q "^${choice}|" "$RULE_FILE" 2>/dev/null; then
            sed -i "/^${choice}|/d" "$RULE_FILE"
            echo -e "${GREEN}✅ 规则 ${choice} 已从记录中删除！${NC}"
            apply_rules 
        else
            echo -e "${RED}❌ 未找到匹配的规则 ID，请检查是否已被删除。${NC}"
        fi
        continue
    fi

    case $choice in
        1) menu_add_rule ;;
        2) menu_view_rules ;;
        3) menu_del_rule ;;
        4) apply_rules ;;
        5) stop_rules ;;
        6) menu_status ;;
        7) 
            systemctl enable port-limiter.service
            echo -e "${GREEN}✅ 已设置开机自启。${NC}" 
            ;;
        8) 
            systemctl disable port-limiter.service
            echo -e "${YELLOW}✅ 已取消开机自启。${NC}" 
            ;;
        0) 
            echo -e "${GREEN}感谢使用，再见！${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}输入无效，请重新选择功能序号 (0-8) 或直接粘贴 ID 删除。${NC}" 
            ;;
    esac
done
