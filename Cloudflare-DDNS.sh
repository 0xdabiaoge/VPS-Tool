#!/bin/sh

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 脚本路径和日志文件
SCRIPT_PATH="/root/cf_ddns.sh"
LOG_FILE="/var/log/cf_ddns.log"
SYSTEMD_PATH="/etc/systemd/system/cf-ddns.service"
OPENRC_PATH="/etc/init.d/cf-ddns"

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    printf "%b\n" "${RED}错误: 此脚本必须以 root 用户权限运行。${NC}"
    exit 1
fi

# 检查系统并安装依赖
check_and_install_deps() {
    printf "%b\n" "${YELLOW}正在检查并安装核心依赖...${NC}"
    if command -v apt >/dev/null 2>&1; then
        # Debian/Ubuntu
        apt-get update >/dev/null 2>&1
        apt-get install -y curl jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL
        yum install -y curl jq >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora
        dnf install -y curl jq >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        # Alpine
        apk update >/dev/null 2>&1
        apk add curl jq >/dev/null 2>&1
    else
        printf "%b\n" "${RED}无法识别的包管理器。请手动安装 'curl' 和 'jq'。${NC}"
        exit 1
    fi

    for cmd in curl jq; do
        if ! command -v $cmd >/dev/null 2>&1; then
            printf "%b\n" "${RED}错误: 依赖 '$cmd' 安装失败。请检查您的网络或手动安装。${NC}"
            exit 1
        fi
    done
    printf "%b\n" "${GREEN}依赖检查完成。${NC}"
}

# 获取用户输入
get_user_input() {
    printf "%b" "${YELLOW}请输入您的 Cloudflare API 令牌 (Token): ${NC}"
    read CF_API_TOKEN
    while [ -z "$CF_API_TOKEN" ]; do
        printf "%b" "${RED}API 令牌不能为空，请重新输入: ${NC}"
        read CF_API_TOKEN
    done

    printf "%b" "${YELLOW}请输入您的根域名 (例如: 1687.xyz): ${NC}"
    read ZONE_NAME
    while [ -z "$ZONE_NAME" ]; do
        printf "%b" "${RED}根域名不能为空，请重新输入: ${NC}"
        read ZONE_NAME
    done

    printf "%b" "${YELLOW}请输入要用于 DDNS 的完整域名 (例如: ddns.1687.xyz): ${NC}"
    read RECORD_NAME
    while [ -z "$RECORD_NAME" ]; do
        printf "%b" "${RED}完整域名不能为空，请重新输入: ${NC}"
        read RECORD_NAME
    done
}

# 创建核心DDNS脚本
create_core_script() {
    printf "%b\n" "${YELLOW}正在创建核心 DDNS 更新脚本...${NC}"
    # 使用 cat 和 EOF 创建文件，避免转义问题
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh

# --- Cloudflare DDNS 配置 ---
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_NAME="$ZONE_NAME"
RECORD_NAME="$RECORD_NAME"
LOG_FILE="$LOG_FILE"
# -----------------------------

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# 循环运行，实现守护进程检测（每2分钟）
while true; do
    # 获取当前公网 IP
    CURRENT_IP=\$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep "ip=" | cut -f2 -d'=')

    if [ -z "\$CURRENT_IP" ]; then
        log "获取当前公网 IP 失败，将在下一次循环中重试。"
    else
        API_URL="https://api.cloudflare.com/client/v4"
        AUTH_HEADER="Authorization: Bearer \$CF_API_TOKEN"
        CONTENT_HEADER="Content-Type: application/json"

        # 获取 Zone ID
        ZONE_INFO=\$(curl -s -X GET "\$API_URL/zones?name=\$ZONE_NAME" -H "\$AUTH_HEADER" -H "\$CONTENT_HEADER")
        ZONE_ID=\$(echo "\$ZONE_INFO" | jq -r '.result[0].id')

        if [ "\$ZONE_ID" = "null" ] || [ -z "\$ZONE_ID" ]; then
            log "错误: 无法找到域名 '\$ZONE_NAME' 的 Zone ID。请检查域名是否正确以及 API 令牌权限。"
        else
            # 获取 DNS 记录信息 (ID 和 IP)
            RECORD_INFO=\$(curl -s -X GET "\$API_URL/zones/\$ZONE_ID/dns_records?type=A&name=\$RECORD_NAME" -H "\$AUTH_HEADER" -H "\$CONTENT_HEADER")
            RECORD_ID=\$(echo "\$RECORD_INFO" | jq -r '.result[0].id')
            OLD_IP=\$(echo "\$RECORD_INFO" | jq -r '.result[0].content')

            if [ "\$RECORD_ID" = "null" ] || [ -z "\$RECORD_ID" ]; then
                log "错误: 无法找到记录 '\$RECORD_NAME' 的 Record ID。请确保该 A 记录已在 Cloudflare 上创建。"
            else
                # 比较 IP 地址并更新
                if [ "\$CURRENT_IP" = "\$OLD_IP" ]; then
                    log "IP 地址未变化 (\$CURRENT_IP)，无需更新。"
                else
                    log "IP 地址已从 \$OLD_IP 变为 \$CURRENT_IP，正在更新..."
                    UPDATE_DATA="{\\"type\\":\\"A\\",\\"name\\":\\"\$RECORD_NAME\\",\\"content\\":\\"\$CURRENT_IP\\",\\"ttl\\":120,\\"proxied\\":false}"
                    RESPONSE=\$(curl -s -X PUT "\$API_URL/zones/\$ZONE_ID/dns_records/\$RECORD_ID" \\
                                   -H "\$AUTH_HEADER" \\
                                   -H "\$CONTENT_HEADER" \\
                                   --data "\$UPDATE_DATA")

                    SUCCESS=\$(echo "\$RESPONSE" | jq -r '.success')

                    if [ "\$SUCCESS" = "true" ]; then
                        log "DNS 记录更新成功！"
                    else
                        log "更新失败！Cloudflare API 返回信息: \$RESPONSE"
                    fi
                fi
            fi
        fi
    fi
    # 2分钟循环一次
    sleep 120
done
EOF
    chmod +x "$SCRIPT_PATH"
    printf "%b\n" "${GREEN}核心脚本创建成功: ${SCRIPT_PATH}${NC}"
}

# 检测并启用守护进程
setup_daemon() {
    if [ -f "/sbin/init" ] && command -v systemctl >/dev/null 2>&1; then
        setup_systemd
    elif command -v rc-status >/dev/null 2>&1; then
        setup_openrc
    else
        printf "%b\n" "${RED}无法识别系统服务管理器（支持 Systemd 或 OpenRC），将无法设置开机自启和进程守护！${NC}"
        # 尝试直接后台运行
        nohup sh "$SCRIPT_PATH" >/dev/null 2>&1 &
        printf "%b\n" "${YELLOW}已尝试使用 nohup 后台运行。${NC}"
    fi
}

# 设置 Systemd (Debian/Ubuntu/CentOS 等)
setup_systemd() {
    printf "%b\n" "${YELLOW}正在配置 Systemd 服务...${NC}"
    cat > "$SYSTEMD_PATH" <<EOF
[Unit]
Description=Cloudflare DDNS Daemon
After=network.target

[Service]
Type=simple
ExecStart=/bin/sh $SCRIPT_PATH
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cf-ddns >/dev/null 2>&1
    systemctl restart cf-ddns >/dev/null 2>&1
    printf "%b\n" "${GREEN}Systemd 服务配置完成并已启动。${NC}"
}

# 设置 OpenRC (Alpine 等)
setup_openrc() {
    printf "%b\n" "${YELLOW}正在配置 OpenRC 服务...${NC}"
    cat > "$OPENRC_PATH" <<EOF
#!/sbin/openrc-run

name="cf-ddns"
description="Cloudflare DDNS Daemon"
command="/bin/sh"
command_args="$SCRIPT_PATH"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
    chmod +x "$OPENRC_PATH"
    rc-update add cf-ddns default >/dev/null 2>&1
    rc-service cf-ddns restart >/dev/null 2>&1
    printf "%b\n" "${GREEN}OpenRC 服务配置完成并已启动。${NC}"
}

# 查看服务状态
view_status() {
    if command -v systemctl >/dev/null 2>&1 && [ -f "$SYSTEMD_PATH" ]; then
        systemctl status cf-ddns
    elif command -v rc-service >/dev/null 2>&1 && [ -f "$OPENRC_PATH" ]; then
        rc-service cf-ddns status
    else
        printf "%b\n" "${RED}服务未安装或当前系统不支持服务状态查询。${NC}"
    fi
}

# 查看日志
view_logs() {
    if [ -f "$LOG_FILE" ]; then
        printf "%b\n" "${GREEN}=== 最近 20 行日志 ===${NC}"
        tail -n 20 "$LOG_FILE"
        printf "%b\n" "${GREEN}=====================${NC}"
    else
        printf "%b\n" "${YELLOW}暂无日志文件。${NC}"
    fi
}

# 卸载功能
uninstall_all() {
    printf "%b\n" "${YELLOW}正在开始彻底卸载 Cloudflare DDNS 服务...${NC}"

    # 停止并删除 Systemd 服务
    if [ -f "$SYSTEMD_PATH" ]; then
        printf "%b\n" "${YELLOW}正在卸载 Systemd 服务...${NC}"
        systemctl stop cf-ddns >/dev/null 2>&1
        systemctl disable cf-ddns >/dev/null 2>&1
        rm -f "$SYSTEMD_PATH"
        systemctl daemon-reload
    fi

    # 停止并删除 OpenRC 服务
    if [ -f "$OPENRC_PATH" ]; then
        printf "%b\n" "${YELLOW}正在卸载 OpenRC 服务...${NC}"
        rc-service cf-ddns stop >/dev/null 2>&1
        rc-update del cf-ddns default >/dev/null 2>&1
        rm -f "$OPENRC_PATH"
    fi

    # 清理相关文件
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && printf "%b\n" "${GREEN}已删除核心脚本: ${SCRIPT_PATH}${NC}"
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE" && printf "%b\n" "${GREEN}已删除日志文件: ${LOG_FILE}${NC}"

    printf "%b\n" "${GREEN}相关服务及文件已完全卸载！${NC}"

    # 自毁脚本本身
    SCRIPT_SELF="$0"
    printf "%b\n" "${YELLOW}正在删除安装脚本自身...${NC}"
    rm -f "$SCRIPT_SELF"
    printf "%b\n" "${GREEN}自毁完成，再见！${NC}"
    exit 0
}

# 安装/更新主流程
install_ddns() {
    check_and_install_deps
    get_user_input
    create_core_script
    setup_daemon
    printf "%b\n" "${GREEN}🎉 Cloudflare DDNS 守护服务安装/更新并启动成功！${NC}"
}

# 主菜单
main_menu() {
    while true; do
        printf "\n"
        printf "%b\n" "${GREEN}=====================================================${NC}"
        printf "%b\n" "${GREEN}    Cloudflare DDNS 守护进程管理脚本 (Debian/Alpine)  ${NC}"
        printf "%b\n" "${GREEN}=====================================================${NC}"
        printf "%b\n" "${YELLOW} 1. 安装/更新 Cloudflare DDNS 守护服务${NC}"
        printf "%b\n" "${YELLOW} 2. 查看服务运行状态${NC}"
        printf "%b\n" "${YELLOW} 3. 查看 DDNS 运行日志${NC}"
        printf "%b\n" "${YELLOW} 4. 彻底卸载 DDNS 及其服务 (包含本脚本)${NC}"
        printf "%b\n" "${YELLOW} 0. 退出${NC}"
        printf "%b\n" "${GREEN}=====================================================${NC}"
        printf "%b" "请输入选项 [0-4]: "
        read choice

        case "$choice" in
            1)
                install_ddns
                ;;
            2)
                view_status
                ;;
            3)
                view_logs
                ;;
            4)
                printf "%b" "${RED}确定要彻底卸载并删除安装脚本本身吗？(y/n): ${NC}"
                read confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    uninstall_all
                else
                    printf "%b\n" "${YELLOW}已取消卸载。${NC}"
                fi
                ;;
            0)
                printf "%b\n" "${GREEN}退出脚本。${NC}"
                exit 0
                ;;
            *)
                printf "%b\n" "${RED}无效选项，请重新选择！${NC}"
                ;;
        esac
    done
}

# 启动主菜单
main_menu