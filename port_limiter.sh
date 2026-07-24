#!/bin/bash

# ====================================================
# Nftables 端口限速交互式管理脚本 (纯内存/无残留版)
# 特性: 运行于 /dev/shm, 无硬盘 I/O, 重启自动销毁
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 使用 /dev/shm (内存盘) 替代硬盘存储
WORK_DIR="/dev/shm/.port_limiter_mem"
RULE_FILE="${WORK_DIR}/rules.conf"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行。${NC}"
  exit 1
fi

check_env() {
    if ! command -v nft &> /dev/null; then
        echo -e "${YELLOW}检测到未安装 nftables，正在自动补全环境...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -y nftables >/dev/null 2>&1
    fi

    # 在内存盘创建隐藏工作目录
    if [ ! -d "$WORK_DIR" ]; then
        mkdir -p "$WORK_DIR"
        touch "$RULE_FILE"
    fi
}

apply_rules() {
    echo -e "${BLUE}正在将安全限速规则注入内核...${NC}"
    
    nft add table inet port_limiter 2>/dev/null
    nft flush table inet port_limiter
    
    nft add chain inet port_limiter input '{ type filter hook input priority 0; policy accept; }'
    nft add chain inet port_limiter output '{ type filter hook output priority 0; policy accept; }'
    nft add chain inet port_limiter forward '{ type filter hook forward priority 0; policy accept; }'

    # 放行纯 TCP 控制帧
    local chains=("input" "output" "forward")
    for chain in "${chains[@]}"; do
        nft add rule inet port_limiter $chain tcp flags \& \(fin\|syn\|rst\|ack\) == ack meta length \< 100 accept
    done

    local active_count=0
    if [ -f "$RULE_FILE" ]; then
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
    fi

    if [ "$active_count" -gt 0 ]; then
        echo -e "${GREEN}✅ 成功应用 $active_count 条限速规则!${NC}"
    else
        echo -e "${YELLOW}当前无生效规则，已放行全部流量。${NC}"
    fi
}

stop_rules() {
    echo -e "${BLUE}正在清空规则并彻底销毁内存残留...${NC}"
    nft delete table inet port_limiter 2>/dev/null
    rm -rf "$WORK_DIR"
    echo -e "${GREEN}✅ Nftables 规则已清除，内存记录已销毁，系统已恢复无痕状态！${NC}"
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
    echo -e "\n${YELLOW}=== 当前保存在内存中的规则 ===${NC}"
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
    echo -e "\n${YELLOW}=== Nftables 运行状态 ===${NC}"
    nft list table inet port_limiter 2>/dev/null || echo -e "${RED}未加载底层规则表。${NC}"
    echo -e "\n${YELLOW}提示: 此为纯内存版本，重启服务器后所有限制与记录将自动消失。${NC}"
}

check_env

while true; do
    echo -e "\n=============================================="
    echo -e "      ${BLUE}网络限速管理面板 (纯内存无痕版)${NC}      "
    echo -e "=============================================="
    echo " 1. 添加端口限速规则"
    echo " 2. 查看当前保存的规则"
    echo " 3. 删除某条限速规则"
    echo " 4. 立即生效/重启限速"
    echo " 5. 停止限速并销毁所有内存记录"
    echo " 6. 查看系统运行状态"
    echo " 0. 退出面板 (后台继续限速)"
    echo "=============================================="
    read -p "请输入数字或直接粘贴 10 位 ID 删除: " choice

    # 智能防呆识别 (直接输入 10 位纯数字 ID 判定为快捷删除)
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
        0) echo -e "${GREEN}已退出。限速在后台运行中，下次可重新执行内存脚本管理。${NC}"; exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择。${NC}" ;;
    esac
done
