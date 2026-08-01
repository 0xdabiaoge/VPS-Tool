#!/bin/sh

set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE="/etc/cloudflare-ddns.env"
RUNTIME_SCRIPT="/usr/local/sbin/cloudflare-ddns-update"
COMPAT_SCRIPT="/root/cf_ddns.sh"
LOG_FILE="/var/log/cf_ddns.log"
SYSTEMD_SERVICE="/etc/systemd/system/cf-ddns.service"
SYSTEMD_TIMER="/etc/systemd/system/cf-ddns.timer"
OPENRC_SERVICE="/etc/init.d/cf-ddns"
OPENRC_LOOP="/usr/local/sbin/cloudflare-ddns-loop"
LOGROTATE_FILE="/etc/logrotate.d/cf-ddns"

if [ "$(id -u)" -ne 0 ]; then
    printf "%b\n" "${RED}错误：请使用 root 运行。${NC}"
    exit 1
fi

pause() {
    printf "按回车继续..."
    read _pause
}

install_deps() {
    printf "%b\n" "${YELLOW}正在检查依赖：curl、jq、flock...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq util-linux
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq util-linux
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq util-linux
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl jq util-linux
    else
        printf "%b\n" "${RED}无法识别包管理器，请先安装 curl、jq、flock。${NC}"
        return 1
    fi

    for command_name in curl jq flock; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf "%b\n" "${RED}缺少命令：$command_name${NC}"
            return 1
        fi
    done
}

valid_domain() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

load_existing_config() {
    [ -r "$CONFIG_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    [ -n "${CF_API_TOKEN:-}" ] && valid_domain "${ZONE_NAME:-}" && valid_domain "${RECORD_NAME:-}"
}

get_user_input() {
    if load_existing_config; then
        printf "%b\n" "${GREEN}检测到现有配置：${RECORD_NAME}${NC}"
        printf "直接保留现有配置吗？[Y/n]: "
        read keep_existing
        case "${keep_existing:-Y}" in
            n|N) ;;
            *) return 0 ;;
        esac
    fi

    while :; do
        printf "%b" "${YELLOW}Cloudflare API Token（输入时不显示）：${NC}"
        stty -echo 2>/dev/null || true
        read CF_API_TOKEN
        stty echo 2>/dev/null || true
        printf "\n"
        case "$CF_API_TOKEN" in
            ""|*[!A-Za-z0-9_-]*) printf "%b\n" "${RED}Token 为空或包含异常字符，请重输。${NC}" ;;
            *) break ;;
        esac
    done

    while :; do
        printf "%b" "${YELLOW}Cloudflare Zone，例如 incushlii.ccwu.cc：${NC}"
        read ZONE_NAME
        valid_domain "$ZONE_NAME" && break
        printf "%b\n" "${RED}Zone 格式不正确。${NC}"
    done

    while :; do
        printf "%b" "${YELLOW}完整 DDNS 域名，例如 hkbn1.incushlii.ccwu.cc：${NC}"
        read RECORD_NAME
        valid_domain "$RECORD_NAME" && break
        printf "%b\n" "${RED}域名格式不正确。${NC}"
    done
}

write_config() {
    umask 077
    {
        printf "CF_API_TOKEN='%s'\n" "$CF_API_TOKEN"
        printf "ZONE_NAME='%s'\n" "$ZONE_NAME"
        printf "RECORD_NAME='%s'\n" "$RECORD_NAME"
        printf "LOG_FILE='%s'\n" "$LOG_FILE"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

create_runtime() {
    cat > "$RUNTIME_SCRIPT" <<'RUNTIME'
#!/bin/sh

set -u

CONFIG_FILE="/etc/cloudflare-ddns.env"
STATE_DIR="/var/lib/cloudflare-ddns"
LOCK_FILE="/run/lock/cloudflare-ddns.lock"

if [ ! -r "$CONFIG_FILE" ]; then
    echo "[ERROR] missing config: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

LOG_FILE="${LOG_FILE:-/var/log/cf_ddns.log}"
API_URL="https://api.cloudflare.com/client/v4"

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")"
touch "$LOG_FILE"
chmod 600 "$CONFIG_FILE"

log() {
    level=$1
    shift
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    logger -t cf-ddns -- "[$level] $*" 2>/dev/null || true
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        BEGIN { ok = 1 }
        NF != 4 { ok = 0 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) ok = 0
            }
        }
        END { exit(ok ? 0 : 1) }
    '
}

fetch_public_ip() {
    for url in \
        "https://cloudflare.com/cdn-cgi/trace" \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com"
    do
        value=$(curl -4 -fsS --connect-timeout 2 --max-time 5 "$url" 2>/dev/null || true)
        case "$url" in
            *cdn-cgi/trace) value=$(printf '%s\n' "$value" | sed -n 's/^ip=//p' | head -n 1) ;;
            *) value=$(printf '%s' "$value" | tr -d '[:space:]') ;;
        esac
        if is_ipv4 "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

stable_ip=""
previous=""
attempt=0
while [ "$attempt" -lt 8 ]; do
    attempt=$((attempt + 1))
    current=$(fetch_public_ip || true)
    if [ -n "$current" ] && [ "$current" = "$previous" ]; then
        stable_ip=$current
        break
    fi
    previous=$current
    sleep 3
done

if [ -z "$stable_ip" ]; then
    log ERROR "public IPv4 did not become stable after $attempt checks"
    exit 1
fi

auth_header="Authorization: Bearer $CF_API_TOKEN"
content_header="Content-Type: application/json"

zone_info=$(curl -4 -fsS --connect-timeout 4 --max-time 15 --retry 2 --retry-delay 1 \
    -X GET "$API_URL/zones?name=$ZONE_NAME" -H "$auth_header" -H "$content_header" 2>/dev/null || true)
zone_id=$(printf '%s' "$zone_info" | jq -er '.result[0].id // empty' 2>/dev/null || true)
if [ -z "$zone_id" ]; then
    message=$(printf '%s' "$zone_info" | jq -r '.errors[0].message // "invalid API response"' 2>/dev/null || printf '%s' 'invalid API response')
    log ERROR "Cloudflare zone lookup failed: $message"
    exit 1
fi

record_info=$(curl -4 -fsS --connect-timeout 4 --max-time 15 --retry 2 --retry-delay 1 \
    -X GET "$API_URL/zones/$zone_id/dns_records?type=A&name=$RECORD_NAME" \
    -H "$auth_header" -H "$content_header" 2>/dev/null || true)
record_id=$(printf '%s' "$record_info" | jq -er '.result[0].id // empty' 2>/dev/null || true)
old_ip=$(printf '%s' "$record_info" | jq -r '.result[0].content // empty' 2>/dev/null || true)
ttl=$(printf '%s' "$record_info" | jq -r '.result[0].ttl // 120' 2>/dev/null || printf '%s' 120)
proxied=$(printf '%s' "$record_info" | jq -r '.result[0].proxied // false' 2>/dev/null || printf '%s' false)

if [ -z "$record_id" ]; then
    message=$(printf '%s' "$record_info" | jq -r '.errors[0].message // "A record not found"' 2>/dev/null || printf '%s' 'A record not found')
    log ERROR "Cloudflare record lookup failed for $RECORD_NAME: $message"
    exit 1
fi

printf '%s\n' "$stable_ip" > "$STATE_DIR/last-public-ip"
date -Is > "$STATE_DIR/last-check"

if [ "$stable_ip" = "$old_ip" ]; then
    printf '%s\n' "$stable_ip" > "$STATE_DIR/last-cloudflare-ip"
    exit 0
fi

update_data=$(jq -nc --arg type A --arg name "$RECORD_NAME" --arg content "$stable_ip" \
    --argjson ttl "$ttl" --argjson proxied "$proxied" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')

response=$(curl -4 -fsS --connect-timeout 4 --max-time 15 --retry 2 --retry-delay 1 \
    -X PUT "$API_URL/zones/$zone_id/dns_records/$record_id" \
    -H "$auth_header" -H "$content_header" --data "$update_data" 2>/dev/null || true)
success=$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || printf '%s' false)
updated_ip=$(printf '%s' "$response" | jq -r '.result.content // empty' 2>/dev/null || true)

if [ "$success" != "true" ] || [ "$updated_ip" != "$stable_ip" ]; then
    message=$(printf '%s' "$response" | jq -r '.errors[0].message // "invalid API response"' 2>/dev/null || printf '%s' 'invalid API response')
    log ERROR "Cloudflare update failed for $RECORD_NAME: $message"
    exit 1
fi

printf '%s\n' "$updated_ip" > "$STATE_DIR/last-cloudflare-ip"
date -Is > "$STATE_DIR/last-update"
log INFO "$RECORD_NAME updated: $old_ip -> $updated_ip"

check=0
while [ "$check" -lt 6 ]; do
    check=$((check + 1))
    resolved=$(getent ahostsv4 "$RECORD_NAME" 2>/dev/null | awk 'NR == 1 { print $1 }')
    if [ "$resolved" = "$updated_ip" ]; then
        log INFO "public DNS verified: $RECORD_NAME -> $resolved"
        exit 0
    fi
    sleep 5
done

log WARN "Cloudflare API is updated, but recursive DNS cache has not refreshed yet"
exit 0
RUNTIME

    chmod 755 "$RUNTIME_SCRIPT"
    ln -sfn "$RUNTIME_SCRIPT" "$COMPAT_SCRIPT"

    cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    size 10M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

remove_legacy_cron() {
    old_cron=$(mktemp)
    (crontab -l 2>/dev/null || true) | grep -v '/root/cf_ddns.sh' > "$old_cron" || true
    crontab "$old_cron"
    rm -f "$old_cron"
}

setup_systemd() {
    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Cloudflare DDNS one-shot updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNTIME_SCRIPT
TimeoutStartSec=90s
User=root
EOF

    cat > "$SYSTEMD_TIMER" <<EOF
[Unit]
Description=Run Cloudflare DDNS updater every 30 seconds

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=1s
Persistent=true
Unit=cf-ddns.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cf-ddns.timer
    systemctl start cf-ddns.service
}

setup_openrc() {
    cat > "$OPENRC_LOOP" <<EOF
#!/bin/sh
while :; do
    $RUNTIME_SCRIPT
    sleep 30
done
EOF
    chmod 755 "$OPENRC_LOOP"

    cat > "$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
name="cf-ddns"
description="Cloudflare DDNS updater"
command="$OPENRC_LOOP"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
    chmod 755 "$OPENRC_SERVICE"
    rc-update add cf-ddns default
    rc-service cf-ddns restart
}

install_ddns() {
    install_deps || return 1
    get_user_input || return 1
    write_config
    create_runtime
    remove_legacy_cron

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now cf-ddns.service >/dev/null 2>&1 || true
        setup_systemd
    elif command -v rc-service >/dev/null 2>&1; then
        setup_openrc
    else
        printf "%b\n" "${RED}仅支持 systemd 或 OpenRC。${NC}"
        return 1
    fi

    printf "%b\n" "${GREEN}DDNS 已安装：单实例运行，每 30 秒检查一次。${NC}"
}

view_status() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status cf-ddns.timer --no-pager || true
        printf "\n最近一次执行：\n"
        systemctl status cf-ddns.service --no-pager || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service cf-ddns status || true
    fi

    if load_existing_config; then
        printf "\n域名：%s\n" "$RECORD_NAME"
        printf "公网 IPv4：%s\n" "$(cat /var/lib/cloudflare-ddns/last-public-ip 2>/dev/null || printf '未检测')"
        printf "Cloudflare：%s\n" "$(cat /var/lib/cloudflare-ddns/last-cloudflare-ip 2>/dev/null || printf '未检测')"
    fi
}

view_logs() {
    tail -n 50 "$LOG_FILE" 2>/dev/null || printf "%b\n" "${YELLOW}暂无日志。${NC}"
}

manual_check() {
    if [ ! -x "$RUNTIME_SCRIPT" ]; then
        printf "%b\n" "${RED}尚未安装。${NC}"
        return 1
    fi
    "$RUNTIME_SCRIPT"
    view_status
}

uninstall_all() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now cf-ddns.timer >/dev/null 2>&1 || true
        systemctl disable --now cf-ddns.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_TIMER" "$SYSTEMD_SERVICE"
        systemctl daemon-reload
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service cf-ddns stop >/dev/null 2>&1 || true
        rc-update del cf-ddns default >/dev/null 2>&1 || true
    fi
    remove_legacy_cron
    rm -f "$OPENRC_SERVICE" "$OPENRC_LOOP" "$RUNTIME_SCRIPT" "$COMPAT_SCRIPT" "$CONFIG_FILE" "$LOGROTATE_FILE"
    rm -rf /var/lib/cloudflare-ddns
    printf "%b\n" "${GREEN}Cloudflare DDNS 已彻底卸载。${NC}"
}

main_menu() {
    while :; do
        printf "\n"
        printf "%b\n" "${GREEN}=====================================================${NC}"
        printf "%b\n" "${GREEN}       Cloudflare DDNS 管理（单实例防冲突版）${NC}"
        printf "%b\n" "${GREEN}=====================================================${NC}"
        printf " 1. 安装或更新 DDNS\n"
        printf " 2. 查看服务状态\n"
        printf " 3. 查看运行日志\n"
        printf " 4. 立即检测并同步\n"
        printf " 5. 彻底卸载 DDNS\n"
        printf " 0. 退出\n"
        printf "请选择 [0-5]: "
        read choice

        case "$choice" in
            1) install_ddns; pause ;;
            2) view_status; pause ;;
            3) view_logs; pause ;;
            4) manual_check; pause ;;
            5)
                printf "%b" "${RED}确认彻底卸载？[y/N]: ${NC}"
                read confirm
                case "$confirm" in y|Y) uninstall_all ;; *) printf "已取消。\n" ;; esac
                pause
                ;;
            0) exit 0 ;;
            *) printf "%b\n" "${RED}无效选项。${NC}" ;;
        esac
    done
}

main_menu
