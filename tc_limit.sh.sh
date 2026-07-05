#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 权限或 sudo 运行此脚本！"
    exit 1
fi

SCRIPT_PATH=$(readlink -f "$0")

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 依赖检测与安装
check_dependencies() {
    echo -e "${YELLOW}[*] 正在检测系统依赖...${PLAIN}"
    if ! command -v tc &> /dev/null; then
        echo -e "${YELLOW}[!] 未检测到 tc 命令，正在尝试安装 iproute2...${PLAIN}"
        apt-get update && apt-get install -y iproute2
        if [ $? -ne 0 ]; then
            echo -e "${RED}[X] iproute2 安装失败，请检查网络或软件源！${PLAIN}"
            exit 1
        fi
    fi
    echo -e "${GREEN}[✓] 依赖检测通过！${PLAIN}"
}

# 获取可用网卡列表（优化版：自动去除 @xxx 后缀，适配容器环境）
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v 'lo'
}

# 2. 限速设置
set_limit() {
    check_dependencies
    echo -e "\n--- 可用的网卡列表 ---"
    interfaces=$(get_interfaces)
    if [ -z "$interfaces" ]; then
        echo -e "${RED}[X] 未找到有效的物理网卡！${PLAIN}"
        return
    fi
    
    echo "$interfaces"
    echo "----------------------"
    read -p "请输入要限制的网卡名称: " iface
    
    if ! echo "$interfaces" | grep -q -w "$iface"; then
        echo -e "${RED}[X] 无效的网卡名称！${PLAIN}"
        return
    fi

    # 检查是否已经存在 tc 规则
    if tc qdisc show dev "$iface" | grep -q "tbf"; then
        echo -e "${YELLOW}[!] 该网卡已存在限速规则，请先移除后再设置。${PLAIN}"
        return
    fi

    echo -e "\n${YELLOW}=== 带宽速率换算说明 ===${PLAIN}"
    echo -e "网络带宽单位为 ${GREEN}Mbps${PLAIN} (兆比特每秒)，日常下载/上传速度显示为 ${GREEN}MB/s${PLAIN} (兆字节每秒)。"
    echo -e "换算公式: ${YELLOW}1 Mbps = 1000 Kbps ≈ 0.125 MB/s (即 125 KB/s)${PLAIN}"
    echo -e "常见参考值："
    echo -e "  -  ${GREEN}10 Mbps${PLAIN}  ≈  最高网速 ${YELLOW}1.25 MB/s${PLAIN}"
    echo -e "  -  ${GREEN}50 Mbps${PLAIN}  ≈  最高网速 ${YELLOW}6.25 MB/s${PLAIN}"
    echo -e "  -  ${GREEN}100 Mbps${PLAIN} ≈  最高网速 ${YELLOW}12.5 MB/s${PLAIN}"
    echo -e "========================"
    
    read -p "请输入限制的出口(上传)带宽大小 (直接输入纯数字，单位默认为 Mbps，例如限制10兆输入 10): " mbps_input
    
    # 验证是否为纯数字
    if [[ ! "$mbps_input" =~ ^[0-9]+$ ]] || [ "$mbps_input" -le 0 ]; then
        echo -e "${RED}[X] 输入错误！请输入大于 0 的纯数字。${PLAIN}"
        return
    fi

    # 将 Mbps 转换为 tc 识别的 mbit 格式
    rate="${mbps_input}mbit"

    # 执行 tc 命令 
    tc qdisc add dev "$iface" root tbf rate "$rate" burst 32kbit latency 400ms 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[✓] 成功对网卡 $iface 设置出口限速为 ${mbps_input} Mbps (约 $(awk "BEGIN {print $mbps_input*0.125}") MB/s)！${PLAIN}"
    else
        echo -e "${RED}[X] 限速设置失败，请检查网卡名称或系统内核是否支持。${PLAIN}"
    fi
}

# 3. 查看限速设置
view_limit() {
    echo -e "\n--- 当前系统网络限速状态 ---"
    interfaces=$(get_interfaces)
    has_rules=false
    
    for iface in $interfaces; do
        status=$(tc qdisc show dev "$iface" 2>/dev/null | grep "tbf")
        if [ ! -z "$status" ]; then
            echo -e "网卡 ${GREEN}$iface${PLAIN}: $status"
            has_rules=true
        fi
    done

    if [ "$has_rules" = false ]; then
        echo -e "${YELLOW}目前没有任何网卡设置了 tc 限速规则。${PLAIN}"
    fi
    echo "----------------------------"
}

# 4. 移除限速设置
remove_limit() {
    echo -e "\n--- 移除限速设置 ---"
    interfaces=$(get_interfaces)
    echo "$interfaces"
    echo "----------------------"
    read -p "请输入要移除限速的网卡名称: " iface

    if ! echo "$interfaces" | grep -q -w "$iface"; then
        echo -e "${RED}[X] 无效的网卡名称！${PLAIN}"
        return
    fi

    if ! tc qdisc show dev "$iface" | grep -q "tbf"; then
        echo -e "${YELLOW}[!] 该网卡本身就没有设置限速规则。${PLAIN}"
        return
    fi

    tc qdisc del dev "$iface" root 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[✓] 已成功移除网卡 $iface 的所有限速规则！${PLAIN}"
    else
        echo -e "${RED}[X] 移除限速失败！${PLAIN}"
    fi
}

# 5. 彻底卸载
uninstall_all() {
    echo -e "${RED}"
    read -p "⚠️ 警告：这将清除所有网卡的限速规则，并彻底删除本脚本文件！确定继续吗？(y/n): " confirm
    echo -e "${PLAIN}"
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${GREEN}[*] 已取消卸载。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}[*] 正在清理所有网卡的 tc 限速规则...${PLAIN}"
    interfaces=$(get_interfaces)
    for iface in $interfaces; do
        if tc qdisc show dev "$iface" | grep -q "tbf"; then
            tc qdisc del dev "$iface" root 2>/dev/null
            echo -e "已清理网卡: $iface"
        fi
    done

    echo -e "${YELLOW}[*] 正在自毁脚本文件...${PLAIN}"
    if [ -f "$SCRIPT_PATH" ]; then
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}[✓] 脚本文件已成功从系统抹除！再见！${PLAIN}"
        exit 0
    else
        echo -e "${RED}[X] 未找到脚本源文件路径，请手动删除。${PLAIN}"
        exit 1
    fi
}

# 交互主菜单
main_menu() {
    while true; do
        echo -e "\n============================="
        echo -e "    Debian TC 限速管理脚本   "
        echo -e "============================="
        echo -e "  ${GREEN}1.${PLAIN} 设置网卡限速"
        echo -e "  ${GREEN}2.${PLAIN} 查看限速状态"
        echo -e "  ${GREEN}3.${PLAIN} 移除网卡限速"
        echo -e "  ${RED}4.${PLAIN} 彻底卸载 (清除规则并自毁脚本)"
        echo -e "  ${GREEN}5.${PLAIN} 退出脚本"
        echo -e "============================="
        read -p "请选择操作 [1-5]: " choice
        
        case $choice in
            1) set_limit ;;
            2) view_limit ;;
            3) remove_limit ;;
            4) uninstall_all ;;
            5) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED}[X] 输入错误，请输入数字 1-5！${PLAIN}" ;;
        esac
    done
}

# 运行主菜单
main_menu