#!/bin/sh

# ═══════════════════════════════════════════════════════════════════════════════════
# VPS流量消耗管理工具 - 原生重构版 (100% POSIX, 极致纯净, 防止溢出)
# ═══════════════════════════════════════════════════════════════════════════════════

SCRIPT_VERSION="v5.0-Native"
SCRIPT_NAME="vps_flow.sh"
SERVICE_NAME="vps_flow"
LOG_FILE="/root/vps_flow.log"
CONFIG_FILE="/root/vps_flow_config.conf"
SHORTCUT_CONFIG="/root/vps_flow_shortcut.conf"
TARGET_CONFIG_FILE="/root/vps_flow_target.conf"
PID_FILE="/var/run/vps_flow.pid"
CHILD_PID_FILE="/var/run/vps_flow_child.pids"
DEFAULT_SHORTCUT="xh"

# 统一颜色方案
PRIMARY="\033[38;5;81m"
SUCCESS="\033[38;5;114m"
WARNING="\033[38;5;179m"
DANGER="\033[38;5;203m"
INFO="\033[38;5;117m"
ACCENT="\033[38;5;180m"
WHITE="\033[38;5;255m"
GRAY="\033[38;5;244m"
MUTED="\033[38;5;240m"
PANEL="\033[38;5;238m"
LABEL="\033[38;5;109m"
VALUE="\033[38;5;253m"
KEY="\033[38;5;81m"
BOLD="\033[1m"
RESET="\033[0m"

# ──────────────────────────────── 工具函数 ────────────────────────────────────

error_exit() {
    printf "${DANGER}❌ 错误：%s${RESET}\n" "$1" >&2
    printf "按回车返回菜单..."
    read -r dummy
}

is_safe_config_value() {
    local value="$1"
    if echo "$value" | grep -q -E '["`$\\]' 2>/dev/null; then
        return 1
    fi
    local stripped
    stripped=$(echo "$value" | tr -d '\n\r')
    if [ "$value" != "$stripped" ]; then
        return 1
    fi
    return 0
}

write_config_line() {
    local key="$1" value="$2"
    echo "$key" | grep -q -E '^[A-Za-z_][A-Za-z0-9_]*$' || return 1
    is_safe_config_value "$value" || return 1
    printf '%s="%s"\n' "$key" "$value"
}

safe_source_config() {
    local file="$1"
    shift
    [ -f "$file" ] || return 1

    local allowed=" $* "
    local line key value temp_key temp_val
    while IFS= read -r line || [ -n "$line" ]; do
        if echo "$line" | grep -q -E '^[[:space:]]*$' 2>/dev/null || echo "$line" | grep -q -E '^[[:space:]]*#' 2>/dev/null; then
            continue
        fi
        if ! echo "$line" | grep -q -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="[^"]*"[[:space:]]*$' 2>/dev/null; then
            continue
        fi

        temp_key="${line%%=*}"
        key=$(echo "$temp_key" | tr -d ' ')
        temp_val="${line#*=}"
        value="${temp_val#\"}"
        value="${value%\"}"

        case "$allowed" in
            *" $key "*) ;;
            *) continue ;;
        esac

        if is_safe_config_value "$value"; then
            eval "$key=\"\$value\""
        fi
    done < "$file"
}

validate_url() {
    local url="$1"
    case "$url" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac
    if echo "$url" | grep -q '[[:space:]]' 2>/dev/null; then
        return 1
    fi
    is_safe_config_value "$url" || return 1
    return 0
}

validate_interface_name() {
    local interface="$1"
    echo "$interface" | grep -q -E '^[A-Za-z0-9_.:-]+$' 2>/dev/null
}

get_shortcut_name() {
    SHORTCUT_NAME=""
    if [ -f "$SHORTCUT_CONFIG" ]; then
        safe_source_config "$SHORTCUT_CONFIG" SHORTCUT_NAME
        echo "${SHORTCUT_NAME:-$DEFAULT_SHORTCUT}"
    else
        echo "$DEFAULT_SHORTCUT"
    fi
}

save_shortcut_config() {
    local shortcut_name="$1"
    echo "$shortcut_name" | grep -q -E '^[a-zA-Z][a-zA-Z0-9_]*$' 2>/dev/null || return 1
    {
        echo "# 快捷键配置文件"
        write_config_line "SHORTCUT_NAME" "$shortcut_name"
    } > "$SHORTCUT_CONFIG"
    chmod 600 "$SHORTCUT_CONFIG" 2>/dev/null
}

save_target_config() {
    local target_gb="$1" start_rx="$2" interface="$3" auto_stop="$4" prev_consumed="${5:-0}"
    echo "$target_gb" | grep -q -E '^[0-9]+(\.[0-9]+)?$' 2>/dev/null || return 1
    echo "$start_rx" | grep -q -E '^[0-9]+$' 2>/dev/null || start_rx=0
    validate_interface_name "$interface" || interface="eth0"
    [ "$auto_stop" = "true" ] || [ "$auto_stop" = "false" ] || auto_stop="false"
    echo "$prev_consumed" | grep -q -E '^[0-9]+$' 2>/dev/null || prev_consumed=0

    {
        echo "# 流量目标配置"
        write_config_line "TARGET_GB" "$target_gb"
        write_config_line "TARGET_START_RX" "$start_rx"
        write_config_line "TARGET_INTERFACE" "$interface"
        write_config_line "TARGET_AUTO_STOP" "$auto_stop"
        write_config_line "TARGET_PREV_CONSUMED" "$prev_consumed"
    } > "$TARGET_CONFIG_FILE"
    chmod 600 "$TARGET_CONFIG_FILE" 2>/dev/null
}

load_target_config() {
    TARGET_GB=""
    TARGET_START_RX=""
    TARGET_INTERFACE=""
    TARGET_AUTO_STOP=""
    TARGET_PREV_CONSUMED=""
    safe_source_config "$TARGET_CONFIG_FILE" TARGET_GB TARGET_START_RX TARGET_INTERFACE TARGET_AUTO_STOP TARGET_PREV_CONSUMED
}

detect_network_interface() {
    local default_interface=""
    if [ -r /proc/net/route ]; then
        default_interface=$(awk '$2 == "00000000" && $8 == "00000000" {print $1; exit}' /proc/net/route)
    fi

    if [ -z "$default_interface" ]; then
        local interfaces
        interfaces=$(ls /sys/class/net 2>/dev/null | grep -v -E "lo|docker|veth|br-")
        for interface in $interfaces; do
            if [ -r "/sys/class/net/$interface/statistics/rx_bytes" ]; then
                case "$interface" in
                    eth*|ens*|enp*|venet*)
                        default_interface="$interface"
                        break
                        ;;
                    *)
                        [ -z "$default_interface" ] && default_interface="$interface"
                        ;;
                esac
            fi
        done
        if [ -z "$default_interface" ] && [ -n "$interfaces" ]; then
            default_interface=$(echo "$interfaces" | awk '{print $1}')
        fi
    fi

    if [ -z "$default_interface" ]; then
        echo "eth0"
        return 1
    fi

    echo "$default_interface"
    return 0
}

save_config() {
    local url="$1" threads="$2" interface="$3" rate_limit="$4"
    validate_url "$url" || return 1
    echo "$threads" | grep -q -E '^[1-9][0-9]*$' 2>/dev/null || return 1
    validate_interface_name "$interface" || return 1
    echo "$rate_limit" | grep -q -E '^(0|[0-9]+(\.[0-9]+)?[a-zA-Z]*)$' 2>/dev/null || rate_limit="0"

    local usage_count="${USAGE_COUNT:-0}"
    echo "$usage_count" | grep -q -E '^[0-9]+$' 2>/dev/null || usage_count=0

    {
        echo "# VPS Flow Config"
        write_config_line "LAST_URL" "$url"
        write_config_line "LAST_THREADS" "$threads"
        write_config_line "LAST_INTERFACE" "$interface"
        write_config_line "LAST_RATE_LIMIT" "$rate_limit"
        write_config_line "USAGE_COUNT" "$((usage_count + 1))"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null
}

load_config() {
    LAST_URL=""
    LAST_THREADS=""
    LAST_INTERFACE=""
    LAST_RATE_LIMIT=""
    USAGE_COUNT=""
    safe_source_config "$CONFIG_FILE" LAST_URL LAST_THREADS LAST_INTERFACE LAST_RATE_LIMIT USAGE_COUNT || return 1
}

# ────────────────────────────── 后台守护进程控制 ────────────────────────────────

detect_init_system() {
    if [ -d /run/systemd/system ]; then
        echo "systemd"
    elif [ -d /run/openrc ] || [ -f /run/openrc/softlevel ]; then
        echo "openrc"
    else
        echo "none"
    fi
}

is_service_running() {
    local init_sys
    init_sys=$(detect_init_system)
    if [ "$init_sys" = "systemd" ]; then
        systemctl is-active --quiet $SERVICE_NAME 2>/dev/null
        return $?
    elif [ "$init_sys" = "openrc" ]; then
        rc-service $SERVICE_NAME status 2>/dev/null | grep -q "started"
        return $?
    else
        if [ -f "$PID_FILE" ]; then
            local t_pid
            t_pid=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$t_pid" ] && kill -0 "$t_pid" 2>/dev/null; then
                return 0
            fi
        fi
        return 1
    fi
}

write_systemd_service() {
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "/root/vps_flow.sh")
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=VPS Flow Background Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/bin/sh $current_script --daemon-run
ExecStop=/bin/sh $current_script --cleanup-only
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
}

write_openrc_service() {
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "/root/vps_flow.sh")
    cat > "/etc/init.d/$SERVICE_NAME" << EOF
#!/sbin/openrc-run

description="VPS Flow Brush Service"
supervisor="supervise-daemon"
command="/bin/sh"
command_args="$current_script --daemon-run"
pidfile="/run/$SERVICE_NAME.pid"
respawn_delay=5
respawn_max=10

stop_post() {
    /bin/sh $current_script --cleanup-only
}
EOF
    chmod +x "/etc/init.d/$SERVICE_NAME"
}

cleanup_threads() {
    # 只清除从属于本工具的明确 PID，不使用模糊的 pkill
    if [ -f "$CHILD_PID_FILE" ]; then
        while IFS= read -r pid || [ -n "$pid" ]; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                # 发送终止信号并等待一下
                kill "$pid" 2>/dev/null
                sleep 0.1
                # 如果没死透，发 SIGKILL (kill -9) 保证绝对干净，避免僵尸下载
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null
                fi
            fi
        done < "$CHILD_PID_FILE"
        rm -f "$CHILD_PID_FILE"
    fi
    
    # 清理那些没有写到 PID 文件里的漏网之鱼（基于完全明确的执行参数）
    local my_pid=$$
    ps -eo pid,args 2>/dev/null | awk -v mypid="$my_pid" '/curl -A "FlowBrush"/ && $1 != mypid {print $1}' | while read -r pid; do
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
}

parse_rate_limit() {
    local input="$1"
    local clean
    clean=$(echo "$input" | tr -d ' ' | tr 'a-z' 'A-Z')

    if [ "$clean" = "0" ] || [ -z "$clean" ]; then
        echo "0"
        return 0
    fi

    local num
    num=$(echo "$clean" | tr -d -c '0-9.')
    local unit
    unit=$(echo "$clean" | tr -d -c 'A-Z')

    if [ -z "$num" ] || [ "$num" = "." ]; then
        return 1
    fi

    if [ -z "$unit" ]; then
        unit="M"
    fi

    case "$unit" in
        K|KB|KB/S|K/S) unit="K" ;;
        M|MB|MB/S|M/S) unit="M" ;;
        G|GB|GB/S|G/S) unit="G" ;;
        *) return 1 ;;
    esac

    echo "${num}${unit}"
    return 0
}

get_limit_per_thread() {
    local total_limit="$1"
    local num_threads="$2"

    if [ -z "$total_limit" ] || [ "$total_limit" = "0" ]; then
        echo "0"
        return
    fi

    local num
    num=$(echo "$total_limit" | tr -d -c '0-9.')
    local unit
    unit=$(echo "$total_limit" | tr -d -c 'a-zA-Z' | tr 'A-Z' 'a-z')

    # 使用 awk 处理大整数运算，彻底避免 32 位 Shell 在 $(()) 中溢出！
    local limit_str
    limit_str=$(awk -v n="$num" -v u="$unit" -v t="$num_threads" 'BEGIN {
        bytes = 0
        if (u == "m") bytes = n * 1024 * 1024
        else if (u == "g") bytes = n * 1024 * 1024 * 1024
        else bytes = n * 1024

        limit_bytes = int(bytes / t)
        if (limit_bytes < 1024) limit_bytes = 1024
        
        # curl 支持直接传递精确的字节数
        print limit_bytes
    }')
    echo "$limit_str"
}

# 下载工作线程：通过原生 /bin/sh 执行，不依赖任何 Bash 功能
download_worker() {
    local url="$1"
    local rate="$2"

    # 处理干净残留
    trap 'exit 0' INT TERM

    while true; do
        if [ "$rate" != "0" ] && [ -n "$rate" ]; then
            curl -A "FlowBrush" -s -m 30 --connect-timeout 10 -o /dev/null --limit-rate "$rate" "$url"
        else
            curl -A "FlowBrush" -s -m 30 --connect-timeout 10 -o /dev/null "$url"
        fi
        sleep 0.1
    done
}

run_daemon() {
    load_config
    
    # 捕获异常信号并终止子并发
    trap 'cleanup_threads; exit 0' INT TERM EXIT

    cleanup_threads

    echo "$(date "+%Y-%m-%d %H:%M:%S"): [启动] ${LAST_THREADS} 线程并发下载 ${LAST_URL} (限速: ${LAST_RATE_LIMIT})" >> "$LOG_FILE"

    if [ -f "$TARGET_CONFIG_FILE" ]; then
        (
            while true; do
                if load_target_config && [ "$TARGET_AUTO_STOP" = "true" ] && echo "$TARGET_GB" | grep -q -E '^[0-9]+(\.[0-9]+)?$' 2>/dev/null; then
                    local interface="${TARGET_INTERFACE:-eth0}"
                    local current_rx
                    current_rx=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo 0)
                    local start_rx="${TARGET_START_RX:-0}"
                    local prev_consumed="${TARGET_PREV_CONSUMED:-0}"

                    # 处理网卡重启/清零的容错
                    if awk -v cur="$current_rx" -v start="$start_rx" 'BEGIN {exit !(cur < start)}'; then
                        prev_consumed=$(awk -v prev="$prev_consumed" -v start="$start_rx" 'BEGIN {printf "%.0f", prev + start}')
                        start_rx=$current_rx
                        save_target_config "$TARGET_GB" "$start_rx" "$interface" "$TARGET_AUTO_STOP" "$prev_consumed"
                    fi

                    # 统一使用 awk 处理超大整数运算（解决 32 位 Shell 下 > 2GB 直接卡死的问题）
                    local stop_flag
                    stop_flag=$(awk -v cur="$current_rx" -v start="$start_rx" -v prev="$prev_consumed" -v tgt_gb="$TARGET_GB" 'BEGIN {
                        consumed = cur - start + prev
                        target_bytes = tgt_gb * 1073741824
                        if (target_bytes > 0 && consumed >= target_bytes) {
                            print "1"
                        } else {
                            print "0"
                        }
                    }')

                    if [ "$stop_flag" = "1" ]; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S'): 流量消耗目标已达成，服务自动停止。" >> "$LOG_FILE"
                        
                        local init_sys
                        init_sys=$(detect_init_system)
                        if [ "$init_sys" = "systemd" ]; then
                            systemctl stop $SERVICE_NAME 2>/dev/null
                        elif [ "$init_sys" = "openrc" ]; then
                            rc-service $SERVICE_NAME stop 2>/dev/null
                        else
                            local p_pid
                            p_pid=$(cat "$PID_FILE" 2>/dev/null)
                            [ -n "$p_pid" ] && kill "$p_pid" 2>/dev/null
                        fi
                        exit 0
                    fi
                fi
                sleep 5
            done
        ) &
    fi

    local limit_per_thread
    limit_per_thread=$(get_limit_per_thread "$LAST_RATE_LIMIT" "$LAST_THREADS")
    
    rm -f "$CHILD_PID_FILE"

    local i=1
    while [ "$i" -le "${LAST_THREADS:-1}" ]; do
        # 直接在后台执行 download_worker 函数
        download_worker "$LAST_URL" "$limit_per_thread" &
        echo $! >> "$CHILD_PID_FILE"
        i=$((i + 1))
    done

    wait
}

# ──────────────────────────────── 控制命令交互 ────────────────────────────────

start_service() {
    clear
    printf "${PRIMARY}  ⚡ 配置流量消耗参数${RESET}\n"
    printf "${GRAY}  ─────────────────────────────────────────────────────────────────${RESET}\n\n"

    load_config

    printf "${INFO}  请选择下载URL：${RESET}\n\n"
    printf "    ${GRAY}── 亚洲节点 ──${RESET}\n"
    printf "    ${SUCCESS}[1]${RESET} ${WHITE}香港 Datapacket 100MB${RESET}      ${GRAY}(推荐，低延迟)${RESET}\n"
    printf "    ${SUCCESS}[2]${RESET} ${WHITE}日本东京 Datapacket 100MB${RESET}  ${GRAY}(亚洲优选)${RESET}\n"
    printf "    ${SUCCESS}[3]${RESET} ${WHITE}新加坡 OVH 1GB${RESET}            ${GRAY}(大文件模式)${RESET}\n\n"
    printf "    ${GRAY}── 欧美节点 ──${RESET}\n"
    printf "    ${SUCCESS}[4]${RESET} ${WHITE}德国 Hetzner 1GB${RESET}           ${GRAY}(欧洲高速)${RESET}\n"
    printf "    ${SUCCESS}[5]${RESET} ${WHITE}美西 洛杉矶 Datapacket 1GB${RESET} ${GRAY}(北美)${RESET}\n"
    printf "    ${SUCCESS}[6]${RESET} ${WHITE}法国 OVH 10GB${RESET}             ${GRAY}(超大文件)${RESET}\n\n"
    printf "    ${GRAY}── 其他 ──${RESET}\n"
    if [ -n "$LAST_URL" ]; then
        printf "    ${SUCCESS}[7]${RESET} ${WHITE}上次使用${RESET}               ${GRAY}%s${RESET}\n" "$LAST_URL"
    fi
    printf "    ${SUCCESS}[8]${RESET} ${WHITE}自定义URL${RESET}\n\n"
    
    printf "  请选择 [1]: "
    read -r url_choice
    url_choice=${url_choice:-1}

    local url=""
    case $url_choice in
        1) url="http://hkg.download.datapacket.com/100mb.bin" ;;
        2) url="http://tyo.download.datapacket.com/100mb.bin" ;;
        3) url="https://sgp.proof.ovh.net/files/1Gb.dat" ;;
        4) url="https://nbg1-speed.hetzner.com/1GB.bin" ;;
        5) url="http://lax.download.datapacket.com/1000mb.bin" ;;
        6) url="https://gra.proof.ovh.net/files/10Gb.dat" ;;
        7) url="${LAST_URL:-http://hkg.download.datapacket.com/100mb.bin}" ;;
        8)
            printf "  请输入自定义URL："
            read -r url
            url=${url:-"http://hkg.download.datapacket.com/100mb.bin"}
            ;;
        *) url="http://hkg.download.datapacket.com/100mb.bin" ;;
    esac
    if ! validate_url "$url"; then
        printf "${DANGER}❌ URL 格式错误！必须以 http:// 或 https:// 开头且无敏感字符${RESET}\n"
        printf "按回车返回菜单..."
        read -r dummy
        return
    fi

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    local recommended_threads=$((cpu_cores * 2))
    printf "${INFO}%-12s${WHITE}%-12s${RESET}    ${INFO}%-12s${WHITE}%-12s${RESET}\n" "CPU核心：" "$cpu_cores" "推荐线程：" "$recommended_threads"
    
    local default_threads=${LAST_THREADS:-1}
    printf "请输入线程数（回车默认 %s）：" "$default_threads"
    read -r threads
    threads=${threads:-$default_threads}
    if ! echo "$threads" | grep -q -E '^[1-9][0-9]*$' 2>/dev/null; then
        printf "${DANGER}❌ 线程数必须为正整数${RESET}\n"
        printf "按回车返回菜单..."
        read -r dummy
        return
    fi

    local default_rate=${LAST_RATE_LIMIT:-1M}
    [ "$default_rate" = "0" ] && default_rate="1M"
    printf "\n${INFO}  配置刷流带宽限制 (0 为不限速，回车默认 %s)：${RESET}\n" "$default_rate"
    printf "  ${GRAY}支持格式: 5 (表示 5MB/s), 10M, 500K (不带单位默认为兆字节 M)${RESET}\n"
    if [ -n "$LAST_RATE_LIMIT" ]; then
        local rate_limit_hint="$LAST_RATE_LIMIT"
        [ "$LAST_RATE_LIMIT" = "0" ] && rate_limit_hint="无限制"
        printf "  ${INFO}上次使用：${WHITE}%s${RESET}\n" "$rate_limit_hint"
    fi
    printf "  限速带宽: "
    read -r rate_limit_input
    rate_limit_input=${rate_limit_input:-$default_rate}

    local rate_limit
    rate_limit=$(parse_rate_limit "$rate_limit_input")
    if [ $? -ne 0 ] || [ -z "$rate_limit" ]; then
        printf "${DANGER}❌ 限速格式错误！请输入数字加单位（如 5M, 500K），或仅输入数字（默认 M）${RESET}\n"
        printf "按回车返回菜单..."
        read -r dummy
        return
    fi

    local interface
    interface=$(detect_network_interface)

    printf "\n${PRIMARY}配置确认${RESET}\n"
    printf "${GRAY}├─────────────────────────────────────────────────────────────────────────────┤${RESET}\n"
    printf "${INFO}%-12s${WHITE}%s${RESET}\n" "下载URL：" "$url"
    printf "${INFO}%-12s${WHITE}%s${RESET}\n" "线程数量：" "$threads"
    local display_rate="不限速"
    [ "$rate_limit" != "0" ] && display_rate="$rate_limit"
    printf "${INFO}%-12s${WHITE}%s${RESET}\n" "带宽限速：" "$display_rate"
    printf "${GRAY}└─────────────────────────────────────────────────────────────────────────────┘${RESET}\n\n"
    
    printf "确认启动？(Y/n)："
    read -r confirm
    case "$confirm" in
        [Nn]*) return ;;
    esac

    save_config "$url" "$threads" "$interface" "$rate_limit"

    local init_sys
    init_sys=$(detect_init_system)
    if [ "$init_sys" = "systemd" ]; then
        write_systemd_service
        systemctl stop $SERVICE_NAME 2>/dev/null
        systemctl start $SERVICE_NAME
    elif [ "$init_sys" = "openrc" ]; then
        write_openrc_service
        rc-service $SERVICE_NAME stop 2>/dev/null
        rc-service $SERVICE_NAME start
    else
        cleanup_threads
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null
        local current_script
        current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "/root/vps_flow.sh")
        nohup /bin/sh "$current_script" --daemon-run >/dev/null 2>&1 &
        echo $! > "$PID_FILE"
    fi

    sleep 1
    if is_service_running; then
        printf "${SUCCESS}✅ 服务启动成功${RESET}\n"
    else
        printf "${DANGER}❌ 服务启动失败，请检查日志。${RESET}\n"
    fi

    printf "按回车返回菜单..."
    read -r dummy
}

stop_service_quiet() {
    local init_sys
    init_sys=$(detect_init_system)
    if [ "$init_sys" = "systemd" ]; then
        systemctl stop $SERVICE_NAME 2>/dev/null
    elif [ "$init_sys" = "openrc" ]; then
        rc-service $SERVICE_NAME stop 2>/dev/null
    else
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
            rm -f "$PID_FILE"
        fi
    fi
    cleanup_threads
}

stop_service() {
    printf "${WARNING}正在停止服务...${RESET}\n"
    stop_service_quiet
    printf "${SUCCESS}✅ 服务已停止${RESET}\n"
    printf "按回车返回菜单..."
    read -r dummy
}

# ───────────────────────────────── 流量实时监控 ─────────────────────────────────

format_speed() {
    local bytes=$1
    if [ -z "$bytes" ] || ! echo "$bytes" | grep -q -E '^[0-9]+$' 2>/dev/null; then
        bytes=0
    fi
    awk -v b="$bytes" 'BEGIN{
        if (b >= 1048576) printf "%.2f MB/s", b/1024/1024
        else if (b >= 1024) printf "%.2f KB/s", b/1024
        else printf "%d B/s", b
    }'
}

format_total() {
    local bytes=$1
    if [ -z "$bytes" ] || ! echo "$bytes" | grep -q -E '^[0-9]+$' 2>/dev/null; then
        bytes=0
    fi
    awk -v b="$bytes" 'BEGIN{
        if (b >= 1073741824) printf "%.2f GB", b/1073741824
        else if (b >= 1048576) printf "%.2f MB", b/1048576
        else if (b >= 1024) printf "%.2f KB", b/1024
        else printf "%d B", b
    }'
}

draw_bar() {
    local rate=$1 max_rate=$2 width=${3:-50}
    if [ "$max_rate" -eq 0 ]; then
        max_rate=1
    fi
    local fill
    fill=$(awk -v r="$rate" -v m="$max_rate" -v w="$width" 'BEGIN{ f = int(r * w / m); if(f > w) f = w; if(f < 0) f = 0; print f }')

    printf "["
    local i=0
    while [ $i -lt "$fill" ]; do
        printf "█"
        i=$((i + 1))
    done
    i=$fill
    while [ $i -lt "$width" ]; do
        printf "░"
        i=$((i + 1))
    done
    printf "]"
}

show_target_progress() {
    if load_target_config; then
        if echo "$TARGET_GB" | grep -q -E '^[0-9]+(\.[0-9]+)?$' 2>/dev/null && [ "$TARGET_GB" != "0" ]; then
            local current_rx
            current_rx=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
            local start_rx="${TARGET_START_RX:-0}"
            local prev_consumed="${TARGET_PREV_CONSUMED:-0}"
            echo "$start_rx" | grep -q -E '^[0-9]+$' 2>/dev/null || start_rx=0
            echo "$prev_consumed" | grep -q -E '^[0-9]+$' 2>/dev/null || prev_consumed=0

            if awk -v cur="$current_rx" -v start="$start_rx" 'BEGIN{exit !(cur < start)}'; then
                current_rx=$(awk -v cur="$current_rx" -v start="$start_rx" 'BEGIN{printf "%.0f", cur + start}')
            fi

            local res
            res=$(awk -v cur="$current_rx" -v start="$start_rx" -v prev="$prev_consumed" -v tgt_gb="$TARGET_GB" 'BEGIN{
                consumed = cur >= start ? cur - start + prev : prev
                consumed_gb = consumed / 1073741824
                target_bytes = tgt_gb * 1073741824
                percent = target_bytes > 0 ? (consumed * 100 / target_bytes) : 0
                if(percent > 100) percent = 100
                printf "%.2f %d", consumed_gb, percent
            }')
            local consumed_gb
            consumed_gb=$(echo "$res" | awk '{print $1}')
            local percent
            percent=$(echo "$res" | awk '{print $2}')

            local mini_bar_len=20
            local fill
            fill=$(awk -v p="$percent" -v l="$mini_bar_len" 'BEGIN{f = int(p * l / 100); if(f>l) f=l; print f}')

            printf "  ${ACCENT}${BOLD}🎯 目标进度:${RESET} ${WHITE}%-6s GB${RESET} / ${WHITE}%-6s GB${RESET} (${WHITE}%d%%${RESET})  " "$consumed_gb" "$TARGET_GB" "$percent"
            printf "${ACCENT}["
            local i=0
            while [ $i -lt "$fill" ]; do
                printf "█"
                i=$((i + 1))
            done
            i=$fill
            while [ $i -lt "$mini_bar_len" ]; do
                printf "░"
                i=$((i + 1))
            done
            printf "]${RESET}\n"
        fi
    fi
}

run_monitor_loop() {
    local interface="$1"
    if [ -z "$interface" ] || [ ! -d "/sys/class/net/$interface" ]; then
        printf "${DANGER}❌ 网卡接口无效或未指定！${RESET}\n"
        exit 1
    fi

    trap 'printf "\033[2J\033[H"; printf "${WARNING}已退出流量监控${RESET}\n"; exit 0' INT TERM

    local RX_PREV
    RX_PREV=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo 0)
    local TX_PREV
    TX_PREV=$(cat "/sys/class/net/$interface/statistics/tx_bytes" 2>/dev/null || echo 0)
    local RX_TOTAL=0 TX_TOTAL=0 DURATION=0
    local RX_PEAK=0 TX_PEAK=0

    INTERFACE="$interface"

    while true; do
        sleep 1
        DURATION=$((DURATION + 1))

        local RX_CUR
        RX_CUR=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo 0)
        local TX_CUR
        TX_CUR=$(cat "/sys/class/net/$interface/statistics/tx_bytes" 2>/dev/null || echo 0)

        local rates
        rates=$(awk -v rc="$RX_CUR" -v rp="$RX_PREV" -v tc="$TX_CUR" -v tp="$TX_PREV" 'BEGIN{
            rr = rc >= rp ? rc - rp : 0
            tr = tc >= tp ? tc - tp : 0
            if(rr > 10737418240) rr = 0
            if(tr > 10737418240) tr = 0
            printf "%.0f %.0f", rr, tr
        }')
        local RX_RATE
        RX_RATE=$(echo "$rates" | awk '{print $1}')
        local TX_RATE
        TX_RATE=$(echo "$rates" | awk '{print $2}')

        RX_PREV=$RX_CUR; TX_PREV=$TX_CUR
        RX_TOTAL=$(awk -v t="$RX_TOTAL" -v r="$RX_RATE" 'BEGIN{printf "%.0f", t + r}')
        TX_TOTAL=$(awk -v t="$TX_TOTAL" -v r="$TX_RATE" 'BEGIN{printf "%.0f", t + r}')
        
        RX_PEAK=$(awk -v peak="$RX_PEAK" -v rate="$RX_RATE" 'BEGIN{print (rate > peak ? rate : peak)}')
        TX_PEAK=$(awk -v peak="$TX_PEAK" -v rate="$TX_RATE" 'BEGIN{print (rate > peak ? rate : peak)}')

        local RX_SPEED
        RX_SPEED=$(format_speed "$RX_RATE")
        local TX_SPEED
        TX_SPEED=$(format_speed "$TX_RATE")
        local RX_TOTAL_FMT
        RX_TOTAL_FMT=$(format_total "$RX_TOTAL")
        local TX_TOTAL_FMT
        TX_TOTAL_FMT=$(format_total "$TX_TOTAL")

        local MAX_SPEED
        MAX_SPEED=$(awk -v rr="$RX_RATE" -v tr="$TX_RATE" 'BEGIN{m = rr > tr ? rr : tr; if(m < 10485760) m = 10485760; print m}')

        local RX_BAR
        RX_BAR=$(draw_bar "$RX_RATE" "$MAX_SPEED" 50)
        local TX_BAR
        TX_BAR=$(draw_bar "$TX_RATE" "$MAX_SPEED" 50)

        local HOURS=$((DURATION / 3600))
        local MINS=$(((DURATION % 3600) / 60))
        local SECS=$((DURATION % 60))
        local AVG_RX
        AVG_RX=$(awk -v t="$RX_TOTAL" -v d="$DURATION" 'BEGIN{print int(d > 0 ? t / d : 0)}')
        local AVG_TX
        AVG_TX=$(awk -v t="$TX_TOTAL" -v d="$DURATION" 'BEGIN{print int(d > 0 ? t / d : 0)}')

        printf "\033[2J\033[H"
        printf "  ${PRIMARY}${BOLD}═══════════════════════════════════════════════════════════${RESET}\n"
        printf "  ${WHITE}${BOLD}              实时流量监控${RESET}  ${INFO}接口: ${WHITE}%s${RESET}\n" "$interface"
        printf "  ${PRIMARY}${BOLD}═══════════════════════════════════════════════════════════${RESET}\n\n"
        printf "  ${SUCCESS}${BOLD}↓ 下载${RESET}  ${WHITE}${BOLD}%-14s${RESET}" "$RX_SPEED"
        printf "  ${INFO}累计: ${WHITE}%s${RESET}\n" "$RX_TOTAL_FMT"
        printf "    ${PRIMARY}%s${RESET}\n\n" "$RX_BAR"
        printf "  ${WARNING}${BOLD}↑ 上传${RESET}  ${WHITE}${BOLD}%-14s${RESET}" "$TX_SPEED"
        printf "  ${INFO}累计: ${WHITE}%s${RESET}\n" "$TX_TOTAL_FMT"
        printf "    ${INFO}%s${RESET}\n\n" "$TX_BAR"
        printf "  ${GRAY}───────────────────────────────────────────────────────────${RESET}\n"
        printf "  ${INFO}平均下载: ${WHITE}%-14s${RESET}" "$(format_speed "$AVG_RX")"
        printf "  ${INFO}平均上传: ${WHITE}%s${RESET}\n" "$(format_speed "$AVG_TX")"
        printf "  ${INFO}峰值下载: ${WHITE}%-14s${RESET}" "$(format_speed "$RX_PEAK")"
        printf "  ${INFO}峰值上传: ${WHITE}%s${RESET}\n\n" "$(format_speed "$TX_PEAK")"
        printf "  ${PRIMARY}运行时长: ${WHITE}${BOLD}%02d:%02d:%02d${RESET}\n" $HOURS $MINS $SECS
        show_target_progress
        printf "  ${GRAY}───────────────────────────────────────────────────────────${RESET}\n"
        printf "  ${GRAY}Ctrl+C 退出监控${RESET}\n"
    done
}

show_monitor() {
    printf "${INFO}正在启动实时流量监控...${RESET}\n"
    load_config

    local interface=""
    if [ -n "$LAST_INTERFACE" ] && [ -d "/sys/class/net/$LAST_INTERFACE" ]; then
        interface="$LAST_INTERFACE"
    else
        interface=$(detect_network_interface)
    fi

    if [ ! -d "/sys/class/net/$interface" ]; then
        error_exit "未找到有效网卡，无法启动监控！"
        return
    fi

    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "/root/vps_flow.sh")
    
    # 忽略父进程的 SIGINT，使 Ctrl+C 只退出子进程的监控循环而不退出主菜单
    trap ':' INT
    /bin/sh "$current_script" --monitor-run "$interface"
    trap - INT
}

# ───────────────────────────────── 环境检测与依赖 ─────────────────────────────────

detect_system_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
    else
        OS_ID="unknown"
    fi
}

install_missing_deps() {
    local required_commands="curl nproc free df ps grep awk sed less bc"
    local missing_cmds=""
    local cmd
    
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds="$missing_cmds $cmd"
        fi
    done

    if [ -n "$missing_cmds" ]; then
        printf "${WARNING}⚠️  正在检测到必需命令缺失，尝试进行依赖环境自动部署...${RESET}\n"

        case "$OS_ID" in
            ubuntu|debian|linuxmint)
                apt-get update >/dev/null 2>&1
                apt-get install -y curl procps coreutils less bc >/dev/null 2>&1
                ;;
            alpine)
                apk update >/dev/null 2>&1
                apk add curl procps coreutils less bc >/dev/null 2>&1
                ;;
            *)
                printf "${WARNING}⚠️  未能自动部署依赖包，请手动安装: curl procps coreutils less bc${RESET}\n"
                ;;
        esac

        local still_missing=""
        for cmd in $required_commands; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                still_missing="$still_missing $cmd"
            fi
        done

        if [ -n "$still_missing" ]; then
            printf "${DANGER}❌ 部分依赖部署失败：${still_missing}${RESET}\n"
            printf "${INFO}请在系统安装完毕对应命令后，重新执行此脚本。${RESET}\n"
            exit 1
        fi
    fi
}

check_environment() {
    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        printf "${DANGER}❌ 需要 root 权限运行此脚本${RESET}\n"
        exit 1
    fi

    detect_system_type
    install_missing_deps

    if [ ! -d "/sys/class/net" ]; then
        printf "${DANGER}❌ 系统网络网卡目录 /sys/class/net 异常，无法进行流量检测！${RESET}\n"
        exit 1
    fi
}

# ───────────────────────────────── 附加功能交互 ─────────────────────────────────

set_traffic_target() {
    clear
    printf "${PRIMARY}  🎯 设定流量目标（到达自动停止）${RESET}\n"
    printf "${GRAY}  ─────────────────────────────────────────────────────────────────${RESET}\n\n"
    
    local interface
    interface=$(detect_network_interface)
    
    printf "  ${INFO}当前网卡接口: ${WHITE}%s${RESET}\n" "$interface"
    
    local current_rx
    current_rx=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo 0)
    printf "  ${INFO}当前已跑流量: ${WHITE}%s${RESET}\n\n" "$(format_total "$current_rx")"
    
    load_target_config
    if [ "$TARGET_AUTO_STOP" = "true" ] && [ -n "$TARGET_GB" ]; then
        printf "  ${SUCCESS}当前已开启目标：${WHITE}%s GB${RESET}\n\n" "$TARGET_GB"
    else
        printf "  ${MUTED}当前未开启流量目标功能${RESET}\n\n"
    fi
    
    printf "  请输入您期望的流量目标 (单位: GB，输入 0 或回车关闭此功能): "
    read -r target_gb
    target_gb=${target_gb:-0}
    
    if [ "$target_gb" = "0" ]; then
        save_target_config "0" "0" "$interface" "false" "0"
        printf "  ${SUCCESS}✅ 流量目标功能已关闭。${RESET}\n"
    else
        if ! echo "$target_gb" | grep -q -E '^[0-9]+(\.[0-9]+)?$' 2>/dev/null; then
            error_exit "输入的流量目标格式无效，必须是数字！"
            return
        fi
        save_target_config "$target_gb" "$current_rx" "$interface" "true" "0"
        printf "  ${SUCCESS}✅ 已设定流量目标: ${WHITE}%s GB${RESET}\n" "$target_gb"
        printf "  ${INFO}当网卡 %s 的新增流量达到此值时，服务将自动停止。${RESET}\n" "$interface"
    fi
    printf "按回车返回菜单..."
    read -r dummy
}

enable_autostart() {
    clear
    printf "${PRIMARY}  🚀 开机自启守护${RESET}\n"
    printf "${GRAY}  ─────────────────────────────────────────────────────────────────${RESET}\n\n"
    
    local init_sys
    init_sys=$(detect_init_system)
    
    if [ "$init_sys" = "systemd" ]; then
        write_systemd_service
        systemctl enable $SERVICE_NAME 2>/dev/null
        printf "  ${SUCCESS}✅ 已通过 Systemd 成功配置开机自启。${RESET}\n"
    elif [ "$init_sys" = "openrc" ]; then
        write_openrc_service
        rc-update add $SERVICE_NAME default 2>/dev/null
        printf "  ${SUCCESS}✅ 已通过 OpenRC 成功配置开机自启。${RESET}\n"
    else
        printf "  ${WARNING}⚠️ 当前系统未检测到 Systemd 或 OpenRC，开机自启可能需要手动配置 cron 或 rc.local。${RESET}\n"
    fi
    printf "按回车返回菜单..."
    read -r dummy
}

uninstall_script() {
    clear
    printf "${DANGER}  🗑️ 卸载脚本及服务${RESET}\n"
    printf "${GRAY}  ─────────────────────────────────────────────────────────────────${RESET}\n\n"
    
    printf "  ${WARNING}确定要完全卸载 vps_flow 服务和配置文件吗？(y/N): ${RESET}"
    read -r confirm
    case "$confirm" in
        [Yy]*) ;;
        *) return ;;
    esac
    
    stop_service_quiet >/dev/null 2>&1
    
    local init_sys
    init_sys=$(detect_init_system)
    if [ "$init_sys" = "systemd" ]; then
        systemctl disable $SERVICE_NAME 2>/dev/null
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload 2>/dev/null
    elif [ "$init_sys" = "openrc" ]; then
        rc-update del $SERVICE_NAME default 2>/dev/null
        rm -f "/etc/init.d/$SERVICE_NAME"
    fi
    
    rm -f "$LOG_FILE" "$CONFIG_FILE" "$TARGET_CONFIG_FILE" "$SHORTCUT_CONFIG"
    
    local current_shortcut
    current_shortcut=$(get_shortcut_name)
    if [ -n "$current_shortcut" ] && [ -f "/usr/bin/$current_shortcut" ]; then
        rm -f "/usr/bin/$current_shortcut"
    fi
    
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    rm -f "/root/vps_flow.sh"
    if [ "$current_script" != "/root/vps_flow.sh" ] && [ -f "$current_script" ]; then
        rm -f "$current_script"
    fi
    
    printf "  ${SUCCESS}✅ 卸载完成。后会有期！${RESET}\n"
    exit 0
}

create_shortcut() {
    clear
    printf "${PRIMARY}  ⚡ 创建快捷执行指令${RESET}\n"
    printf "${GRAY}  ─────────────────────────────────────────────────────────────────${RESET}\n\n"
    
    local current_shortcut
    current_shortcut=$(get_shortcut_name)
    printf "  ${INFO}当前快捷指令: ${WHITE}%s${RESET}\n" "$current_shortcut"
    
    printf "  请输入新的快捷指令 (留空保持原样): "
    read -r new_shortcut
    
    if [ -n "$new_shortcut" ]; then
        if ! echo "$new_shortcut" | grep -q -E '^[a-zA-Z][a-zA-Z0-9_]*$' 2>/dev/null; then
            error_exit "快捷指令只能包含字母、数字和下划线，且必须以字母开头！"
            return
        fi
        
        if [ -f "/usr/bin/$current_shortcut" ] && [ "$current_shortcut" != "$new_shortcut" ]; then
            rm -f "/usr/bin/$current_shortcut"
        fi
        
        save_shortcut_config "$new_shortcut"
        local current_script
        current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "/root/vps_flow.sh")
        cat > "/usr/bin/$new_shortcut" << EOF
#!/bin/sh
exec "$current_script" "\$@"
EOF
        chmod +x "/usr/bin/$new_shortcut"
        printf "  ${SUCCESS}✅ 快捷指令已更新为: ${WHITE}%s${RESET}\n" "$new_shortcut"
        printf "  ${INFO}今后您可以在任意终端直接输入 %s 来启动本控制台。${RESET}\n" "$new_shortcut"
    fi
    printf "按回车返回菜单..."
    read -r dummy
}

# ───────────────────────────────── 程序主菜单 ─────────────────────────────────

show_menu() {
    clear
    printf "\n"
    printf "  ${PANEL}╭────────────────────────────────────────────────────────────╮${RESET}\n"
    printf "  ${PANEL}│${RESET} ${PRIMARY}${BOLD}VPS 流量控制台${RESET} ${MUTED}${SCRIPT_VERSION}${RESET}                                   ${PANEL}│${RESET}\n"
    printf "  ${PANEL}╰────────────────────────────────────────────────────────────╯${RESET}\n\n"

    local status_badge
    if is_service_running; then
        status_badge="${SUCCESS}● 运行中${RESET}"
    else
        status_badge="${DANGER}○ 已停止${RESET}"
    fi
    
    local pid_value="--"
    local init_sys
    init_sys=$(detect_init_system)
    if is_service_running; then
        if [ "$init_sys" = "systemd" ]; then
            pid_value=$(systemctl show -p MainPID --value $SERVICE_NAME 2>/dev/null)
        elif [ "$init_sys" = "openrc" ]; then
            pid_value=$(cat "/run/$SERVICE_NAME.pid" 2>/dev/null)
        else
            pid_value=$(cat "$PID_FILE" 2>/dev/null)
        fi
    fi

    local hostname
    hostname=$(hostname 2>/dev/null || echo "未知")
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "?")
    
    local mem_used="?"
    local mem_total="?"
    if [ -r /proc/meminfo ]; then
        mem_total=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
        local mem_avail
        mem_avail=$(awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
        if [ -n "$mem_avail" ] && [ -n "$mem_total" ]; then
            mem_used=$(awk -v t="$mem_total" -v a="$mem_avail" 'BEGIN{printf "%.1f", t - a}' 2>/dev/null || echo "?")
        fi
    fi

    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR>1 {if(NF>=5) {print $(NF-3)"/"$(NF-4)" ("$(NF-1)")"} else if(NF==4) {print $2"/"$1" ("$4")"}}' | head -n 1)
    if [ -z "$disk_usage" ]; then disk_usage="未知"; fi
    
    local load_avg
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo "未知")

    load_config || true
    local last_line="${MUTED}暂无历史启动配置${RESET}"
    if [ -n "$LAST_URL" ]; then
        local short_url="$LAST_URL"
        [ ${#short_url} -gt 42 ] && short_url="$(echo "$short_url" | awk '{print substr($0, 1, 39)}')..."
        local limit_str="无限制"
        if [ -n "$LAST_RATE_LIMIT" ] && [ "$LAST_RATE_LIMIT" != "0" ]; then
            limit_str="$LAST_RATE_LIMIT"
        fi
        last_line="${LABEL}上次${RESET} ${VALUE}${LAST_THREADS:-?}线程 / 限速 ${limit_str} / ${LAST_INTERFACE:-网卡}${RESET} ${MUTED}\n   └─ ${short_url}${RESET}"
    fi

    printf "  ${MUTED}STATUS${RESET}\n"
    printf "  ${LABEL}服务${RESET} %b   ${LABEL}PID${RESET} ${VALUE}%s${RESET}\n" "$status_badge" "${pid_value:-N/A}"
    printf "  ${LABEL}主机${RESET} ${VALUE}%s${RESET}   ${LABEL}CPU${RESET} ${VALUE}%s核${RESET}   ${LABEL}内存${RESET} ${VALUE}%s/%sGB${RESET}\n" "$hostname" "$cpu_cores" "$mem_used" "$mem_total"
    printf "  ${LABEL}磁盘${RESET} ${VALUE}%s${RESET}   ${LABEL}负载${RESET} ${VALUE}%s${RESET}\n" "$disk_usage" "$load_avg"
    printf "  %b\n\n" "$last_line"

    printf "  ${MUTED}ACTIONS${RESET}\n"
    printf "  ${PANEL}────────────────────────────────────────────────────────────${RESET}\n"
    printf "    ${KEY}1${RESET} ${WHITE}启动/重配${RESET}       ${KEY}2${RESET} ${WHITE}停止后台${RESET}       ${KEY}3${RESET} ${WHITE}实时监控${RESET}       ${KEY}4${RESET} ${WHITE}设定流量目标${RESET}\n\n"
    printf "    ${KEY}5${RESET} ${WHITE}开机自启守护${RESET}    ${KEY}6${RESET} ${WHITE}卸载脚本及服务${RESET} ${KEY}7${RESET} ${WHITE}创建快捷执行指令${RESET} ${GRAY}0${RESET} ${WHITE}退出控制${RESET}\n"
    printf "  ${PANEL}────────────────────────────────────────────────────────────${RESET}\n\n"

    printf "  ${LABEL}选择操作${RESET} ${MUTED}(0-7)${RESET} ${PRIMARY}>${RESET} "
    read -r choice

    case $choice in
        1) start_service ;;
        2) stop_service ;;
        3) show_monitor ;;
        4) set_traffic_target ;;
        5) enable_autostart ;;
        6) uninstall_script ;;
        7) create_shortcut ;;
        0) clear; exit 0 ;;
        *)
            printf "  ${DANGER}无效选项${RESET}\n"
            sleep 1
            ;;
    esac
}

# ───────────────────────────────── 程序控制分支 ───────────────────────────────────

if [ "$1" = "--daemon-run" ]; then
    run_daemon
    exit 0
fi

if [ "$1" = "--monitor-run" ]; then
    run_monitor_loop "$2"
    exit 0
fi

if [ "$1" = "--cleanup-only" ]; then
    cleanup_threads
    exit 0
fi

check_environment

# 自我复制到 /root 下以保证启动路径统一
current_script_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
if [ "$current_script_path" != "/root/vps_flow.sh" ]; then
    cp "$current_script_path" "/root/vps_flow.sh"
    chmod +x "/root/vps_flow.sh"
fi

touch "$LOG_FILE" 2>/dev/null && chmod 644 "$LOG_FILE" 2>/dev/null

while true; do
    show_menu
done
