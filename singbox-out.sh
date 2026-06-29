#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SINGBOX_VERSION="${SINGBOX_VERSION:-latest}"
SINGBOX_INSTALL_SOURCE="${SINGBOX_INSTALL_SOURCE:-github}"
SINGBOX_LOCAL_DIR="${SINGBOX_LOCAL_DIR:-/root}"
SINGBOX_LOCAL_PACKAGE="${SINGBOX_LOCAL_PACKAGE:-}"
CONF_DIR="/etc/sing-box-out"
CONF_FILE="$CONF_DIR/config.json"
LEGACY_CONF_DIR="/etc/sing-box"
LEGACY_CONF_FILE="$LEGACY_CONF_DIR/config.json"

RUNTIME_DIR="/usr/local/lib/sing-box-out"
BIN_FILE="$RUNTIME_DIR/sing-box"
STATE_DIR="/var/lib/sing-box-out"
TEMPLATE_FILE="$STATE_DIR/config.template.json"
STATE_FILE="$STATE_DIR/proxy_ip"
META_FILE="$STATE_DIR/config.env"
RENDER_FILE="$RUNTIME_DIR/render_config.sh"
GUARD_FILE="$RUNTIME_DIR/guard.sh"

SINGBOX_UNIT="sing-box-out"
SINGBOX_SERVICE="/etc/systemd/system/${SINGBOX_UNIT}.service"
GUARD_SERVICE="/etc/systemd/system/sing-box-out-guard.service"
LEGACY_SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
OLD_KEEP_ALIVE_SERVICE="/etc/systemd/system/keep-alive.service"
OLD_KEEP_ALIVE_FILE="/root/keep_alive.sh"

TABLE_TUN="100"
MARK_OUTBOUND_HEX="0x29a"
MARK_INBOUND_HEX="0x114"
PRE_CHAIN="SBOX_OUT_PRE"
OUT_CHAIN="SBOX_OUT_OUT"
NFT_TABLE="singbox_out"
NFT_STATE_FILE="/run/sing-box-out-nft.state"
TUN_IPV4="10.255.0.1/30"
TUN_IPV6="fdfe:dcba:9876::1/126"
DEFAULT_DDNS_INTERVAL="30"
DEFAULT_PROXY_HOST_TRAFFIC="false"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请以 root 身份运行此脚本。${NC}"
  exit 1
fi

function info() { echo -e "${GREEN}$*${NC}"; }
function warn() { echo -e "${YELLOW}$*${NC}"; }
function err() { echo -e "${RED}$*${NC}"; }
function die() { err "$*"; exit 1; }
function pause() { read -r -p "按回车键返回主菜单..."; }

function json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

function shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

function is_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
    done
    return 0
}

function is_ipv6() {
    [[ "$1" == *:* ]]
}

function cidr_for_ip() {
    if is_ipv4 "$1"; then
        printf '%s/32\n' "$1"
    else
        printf '%s/128\n' "$1"
    fi
}

function validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

function validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

function is_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || [[ "$1" =~ :.*\/[0-9]{1,3}$ ]]
}

function normalize_cidr_list() {
    local input="$1" item result=""
    input=${input//,/ }
    for item in $input; do
        is_cidr "$item" || die "代理源网段无效: $item"
        if [ -n "$result" ]; then
            result="$result $item"
        else
            result="$item"
        fi
    done
    printf '%s\n' "$result"
}

function append_cidr() {
    local cidr="$1"
    [ -n "$cidr" ] || return 0
    case " $DETECTED_CIDRS " in
        *" $cidr "*) return 0 ;;
    esac
    if [ -n "$DETECTED_CIDRS" ]; then
        DETECTED_CIDRS="$DETECTED_CIDRS $cidr"
    else
        DETECTED_CIDRS="$cidr"
    fi
}

function is_public_container_ip() {
    local ip="$1"
    case "$ip" in
        ""|127.*|10.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|::1|fe80:*|fc*|fd*)
            return 1
            ;;
    esac
    return 0
}

function detect_container_public_cidrs_from() {
    local client="$1" csv names name ip
    csv=$("$client" list --format csv -c 4,6 2>/dev/null || true)
    while read -r ip; do
        [ -n "$ip" ] || continue
        is_public_container_ip "$ip" || continue
        if is_ipv4 "$ip"; then
            append_cidr "$ip/32"
        elif is_ipv6 "$ip"; then
            append_cidr "$ip/128"
        fi
    done <<EOF
$(printf '%s\n' "$csv" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F:]*:[0-9a-fA-F:]+')
EOF

    names=$("$client" list --format csv -c n 2>/dev/null || true)
    for name in $names; do
        [ -n "$name" ] || continue
        while read -r ip; do
            [ -n "$ip" ] || continue
            is_public_container_ip "$ip" || continue
            if is_ipv4 "$ip"; then
                append_cidr "$ip/32"
            elif is_ipv6 "$ip"; then
                append_cidr "$ip/128"
            fi
        done <<EOF
$("$client" config show "$name" --expanded 2>/dev/null | awk '/^[[:space:]]*ipv[46]\.address:/ {print $2}')
EOF
    done
}

function detect_proxy_source_cidrs() {
    local ifaces iface cidr
    DETECTED_CIDRS=""
    ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(incusbr|lxcbr|virbr|br-|docker)/ {print $2}')
    for iface in $ifaces; do
        while read -r cidr; do
            [ -n "$cidr" ] || continue
            case "$cidr" in
                default|127.*|169.254.*|::1/*|fe80:*|fdfe:dcba:9876::*)
                    continue
                    ;;
            esac
            append_cidr "$cidr"
        done <<EOF
$(ip -o -4 route show table main dev "$iface" scope link 2>/dev/null | awk '$1 ~ /\// {print $1}')
$(ip -o -6 route show table main dev "$iface" 2>/dev/null | awk '$1 ~ /\// {print $1}')
EOF
    done

    if command -v incus >/dev/null 2>&1; then
        detect_container_public_cidrs_from incus
    fi
    if command -v lxc >/dev/null 2>&1 && { [ -S /var/snap/lxd/common/lxd/unix.socket ] || [ -S /var/lib/lxd/unix.socket ]; }; then
        detect_container_public_cidrs_from lxc
    fi

    printf '%s\n' "$DETECTED_CIDRS"
}

function resolve_host_ipv4() {
    local host="$1" ip
    if is_ipv4 "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    fi
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short A "$host" @1.1.1.1 2>/dev/null | grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
        ip=$(dig +short A "$host" @8.8.8.8 2>/dev/null | grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    fi
    if command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup -type=A "$host" 1.1.1.1 2>/dev/null | awk '/^Address: / {print $2}' | grep -m1 -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    fi
    return 1
}

function resolve_host_ipv6() {
    local host="$1" ip
    if is_ipv6 "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | grep -m1 ':')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    fi
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short AAAA "$host" @2606:4700:4700::1111 2>/dev/null | grep -m1 ':')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
        ip=$(dig +short AAAA "$host" @2001:4860:4860::8888 2>/dev/null | grep -m1 ':')
        if [ -n "$ip" ]; then printf '%s\n' "$ip"; return 0; fi
    fi
    return 1
}

function resolve_host_ip() {
    local host="$1" ip
    ip=$(resolve_host_ipv4 "$host" 2>/dev/null) && { printf '%s\n' "$ip"; return 0; }
    ip=$(resolve_host_ipv6 "$host" 2>/dev/null) && { printf '%s\n' "$ip"; return 0; }
    return 1
}

function default_iface() {
    local iface
    iface=$(ip -4 route show table main default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$iface" ]; then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(ip -6 route show table main default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -n "$iface" ]; then
        printf '%s\n' "$iface"
        return 0
    fi
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev" && $(i+1) !~ /^tun/) {print $(i+1); exit}}'
}

function saved_meta_value() {
    local key="$1"
    [ -f "$META_FILE" ] || return 1
    awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$META_FILE"
}

function is_wan_candidate() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip link show "$iface" >/dev/null 2>&1 || return 1
    [[ "$iface" =~ ^(lo|tun|docker|veth|br-|lxc|virbr|incusbr) ]] && return 1
    return 0
}

function detect_ssh_client_ip() {
    local ip
    ip=$(printf '%s\n' "$SSH_CLIENT" | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')
    fi
    printf '%s\n' "$ip"
}

function detect_ssh_port() {
    local port
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
    fi
    port=${port:-22}
    printf '%s\n' "$port"
}

function require_commands() {
    local missing=()
    for cmd in ip nft curl tar awk sed grep systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "缺少必要命令: ${missing[*]}"
    fi
}

function require_install_commands() {
    local missing=()
    for cmd in tar awk sed grep install mktemp uname head find ls cp; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${SINGBOX_INSTALL_SOURCE:-github}" = "github" ]; then
        command -v curl >/dev/null 2>&1 || missing+=("curl")
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        die "缺少安装 sing-box 所需命令: ${missing[*]}"
    fi
}

function singbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' "amd64" ;;
        aarch64|arm64) printf '%s\n' "arm64" ;;
        armv7l) printf '%s\n' "armv7" ;;
        *) return 1 ;;
    esac
}

function resolve_singbox_version() {
    local requested="${1:-$SINGBOX_VERSION}" version latest_url
    if [ "$requested" = "latest" ]; then
        version=$(curl -fsSL --connect-timeout 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
        if [ -z "$version" ]; then
            latest_url=$(curl -fsSIL --connect-timeout 15 -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
            version=$(printf '%s\n' "$latest_url" | sed -n 's|.*/tag/v\([^/?#]*\).*|\1|p' | head -1)
        fi
        [ -n "$version" ] || return 1
        printf '%s\n' "$version"
    else
        printf '%s\n' "${requested#v}"
    fi
}

function installed_singbox_version() {
    [ -x "$BIN_FILE" ] || return 1
    "$BIN_FILE" version 2>/dev/null | awk 'NR==1 {print $3}'
}

function version_from_singbox_package() {
    local package="$1" base
    base=$(basename -- "$package")
    printf '%s\n' "$base" | sed -n 's/^sing-box-v\{0,1\}\([0-9][0-9A-Za-z._-]*\)-linux-[^.]*\.tar\.gz$/\1/p'
}

function find_local_singbox_package() {
    local arch="$1" requested="${2:-latest}" package version
    if [ -n "$SINGBOX_LOCAL_PACKAGE" ]; then
        [ -f "$SINGBOX_LOCAL_PACKAGE" ] || die "指定的本地 sing-box 压缩包不存在: $SINGBOX_LOCAL_PACKAGE"
        case "$(basename -- "$SINGBOX_LOCAL_PACKAGE")" in
            *"-linux-${arch}.tar.gz") ;;
            *) die "本地 sing-box 压缩包架构不匹配，当前机器需要 linux-${arch}: $SINGBOX_LOCAL_PACKAGE" ;;
        esac
        printf '%s\n' "$SINGBOX_LOCAL_PACKAGE"
        return 0
    fi

    if [ "$requested" != "latest" ]; then
        version="${requested#v}"
        package=$(ls -t \
            "$SINGBOX_LOCAL_DIR/sing-box-${version}-linux-${arch}.tar.gz" \
            "$SINGBOX_LOCAL_DIR/sing-box-v${version}-linux-${arch}.tar.gz" \
            2>/dev/null | head -1)
        [ -n "$package" ] || die "未在 $SINGBOX_LOCAL_DIR 找到 sing-box v${version} 的 linux-${arch} 压缩包。"
        printf '%s\n' "$package"
        return 0
    fi

    package=$(ls -t "$SINGBOX_LOCAL_DIR"/sing-box-*-linux-"${arch}".tar.gz 2>/dev/null | head -1)
    [ -n "$package" ] || die "未在 $SINGBOX_LOCAL_DIR 找到 sing-box-*-linux-${arch}.tar.gz。请先上传官方压缩包到该目录。"
    printf '%s\n' "$package"
}

function version_ge() {
    local ver="$1" min="$2" IFS=.
    local va vb i
    read -r -a va <<< "${ver#v}"
    read -r -a vb <<< "${min#v}"
    for i in 0 1 2; do
        local a="${va[$i]:-0}" b="${vb[$i]:-0}"
        a=${a%%[^0-9]*}
        b=${b%%[^0-9]*}
        a=${a:-0}
        b=${b:-0}
        if [ "$a" -gt "$b" ]; then return 0; fi
        if [ "$a" -lt "$b" ]; then return 1; fi
    done
    return 0
}

function print_menu() {
    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${GREEN}       Sing-Box 透明出口代理部署脚本 (SOCKS5/SS/VLESS + DDNS)${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo
    echo -e " ${YELLOW}1.${NC} 一键部署 / 重新配置 (SOCKS5 / Shadowsocks / VLESS+TCP)"
    echo -e " ${YELLOW}2.${NC} 安装 / 更新 Sing-box 核心 (${SINGBOX_VERSION}，可自定义版本)"
    echo -e " ${YELLOW}3.${NC} 查看运行状态、DDNS 状态与日志"
    echo -e " ${YELLOW}4.${NC} 停止服务并彻底卸载清理"
    echo -e " ${YELLOW}0.${NC} 退出脚本"
    echo
    echo -e "${BLUE}======================================================${NC}"
}

function check_status() {
    clear
    echo -e "${BLUE}=== Sing-box 出口代理状态 ===${NC}"
    echo

    if systemctl is-active --quiet "$SINGBOX_UNIT"; then
        echo -e "Sing-box 出口服务: ${GREEN}运行中${NC}"
    else
        echo -e "Sing-box 出口服务: ${RED}未运行${NC}"
    fi

    if systemctl is-active --quiet sing-box-out-guard; then
        echo -e "路由/DDNS 守护: ${GREEN}运行中${NC}"
    else
        echo -e "路由/DDNS 守护: ${RED}未运行${NC}"
    fi

    if [ -f "$BIN_FILE" ]; then
        echo -e "当前核心: ${YELLOW}$($BIN_FILE version | head -1)${NC}"
    else
        echo -e "当前核心: ${RED}未安装${NC}"
    fi

    if [ -f "$META_FILE" ]; then
        echo
        echo "部署参数:"
        grep -E '^(PROTOCOL|PROXY_HOST|PROXY_PORT|WAN_IFACE|DDNS_INTERVAL|SSH_PORT|ENABLE_SPLIT|PROXY_SOURCE_CIDRS|PROXY_HOST_TRAFFIC|SINGBOX_VERSION|SINGBOX_INSTALL_SOURCE|SINGBOX_LOCAL_PACKAGE|VLESS_TLS|VLESS_SERVER_NAME|VLESS_ALPN|VLESS_FLOW)=' "$META_FILE" 2>/dev/null | sed 's/^/  /'
    fi

    if [ -f "$STATE_FILE" ]; then
        echo -e "当前落地节点 IP: ${GREEN}$(cat "$STATE_FILE")${NC}"
    fi

    echo
    echo "当前公网出口检测:"
    IPV4=$(curl -4 -s --connect-timeout 8 https://api.ipify.org 2>/dev/null)
    IPV6=$(curl -6 -s --connect-timeout 8 https://api64.ipify.org 2>/dev/null)
    [ -n "$IPV4" ] && echo -e "  IPv4: ${GREEN}$IPV4${NC}" || echo -e "  IPv4: ${RED}检测失败${NC}"
    [ -n "$IPV6" ] && echo -e "  IPv6: ${GREEN}$IPV6${NC}" || echo -e "  IPv6: ${YELLOW}不可用或未代理${NC}"

    echo
    echo "策略路由摘要:"
    ip rule show | grep -E 'lookup 100|fwmark 0x29a|fwmark 0x114|priority (10|15|20|50|60|70|100)' || true
    ip -6 rule show | grep -E 'lookup 100|fwmark 0x29a|fwmark 0x114|priority (10|15|20|50|60|70|100)' || true
    ip route show table "$TABLE_TUN" 2>/dev/null || true
    ip -6 route show table "$TABLE_TUN" 2>/dev/null || true
    nft list table inet "$NFT_TABLE" 2>/dev/null || true

    echo
    echo "最近 sing-box 出口服务日志:"
    journalctl -u "$SINGBOX_UNIT" -n 12 --no-pager 2>/dev/null || true
    echo
    echo "最近守护进程日志:"
    journalctl -u sing-box-out-guard -n 12 --no-pager 2>/dev/null || true
    echo
    pause
}

function cleanup_policy_rules() {
    local prio
    ip route flush table "$TABLE_TUN" 2>/dev/null || true
    ip -6 route flush table "$TABLE_TUN" 2>/dev/null || true
    for prio in 10 15 20 50 60 70 100; do
        while ip rule del priority "$prio" 2>/dev/null; do :; done
        while ip -6 rule del priority "$prio" 2>/dev/null; do :; done
    done
}

function flush_route_cache() {
    ip route flush cache 2>/dev/null || true
    ip -6 route flush cache 2>/dev/null || true
}

function cleanup_conntrack_state() {
    command -v conntrack >/dev/null 2>&1 || return 0
    conntrack -D -m "$MARK_INBOUND_HEX" 2>/dev/null || true
    conntrack -D -m "$MARK_OUTBOUND_HEX" 2>/dev/null || true
}

function cleanup_nftables() {
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    rm -f "$NFT_STATE_FILE" 2>/dev/null || true
}

function cleanup_new_iptables() {
    command -v iptables >/dev/null 2>&1 || return 0
    while iptables -t mangle -D PREROUTING -j "$PRE_CHAIN" 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -j "$OUT_CHAIN" 2>/dev/null; do :; done
    iptables -t mangle -F "$PRE_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$PRE_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$OUT_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$OUT_CHAIN" 2>/dev/null || true
}

function cleanup_legacy_iptables() {
    command -v iptables-save >/dev/null 2>&1 || return 0
    iptables-save -t mangle 2>/dev/null | while read -r line; do
        case "$line" in
            *"CONNMARK --set-xmark 0x114"*|*"CONNMARK --restore-mark"*|*"-p tcp -m tcp --dport 22 -j ACCEPT"*|*"-p tcp -m tcp --sport 22 -j ACCEPT"*|*"-d 140.82.112.0/20"*|*"-d 143.55.64.0/20"*|*"-d 185.199.108.0/22"*|*"-d 192.30.252.0/22"*|*"-d 44.205.64.0/20"*|*"-d 52.1.184.0/21"*)
                rule=${line#-A }
                chain=${rule%% *}
                rest=${rule#* }
                # shellcheck disable=SC2086
                iptables -t mangle -D "$chain" $rest 2>/dev/null || true
                ;;
        esac
    done
}

function legacy_singbox_service_owned_by_script() {
    [ -f "$LEGACY_SINGBOX_SERVICE" ] || return 1
    grep -q '/usr/local/lib/sing-box-out/sing-box' "$LEGACY_SINGBOX_SERVICE" && return 0
    if grep -Eq '^ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config\.json[[:space:]]*$' "$LEGACY_SINGBOX_SERVICE"; then
        legacy_keep_alive_service_owned_by_script && return 0
        legacy_keep_alive_file_owned_by_script && return 0
        legacy_singbox_config_owned_by_script && return 0
    fi
    return 1
}

function cleanup_legacy_singbox_service() {
    if legacy_singbox_service_owned_by_script; then
        warn "检测到旧版脚本创建的 sing-box.service，正在清理旧服务；不会删除 /usr/local/bin/sing-box。"
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f "$LEGACY_SINGBOX_SERVICE"
    fi
}

function legacy_keep_alive_service_owned_by_script() {
    [ -f "$OLD_KEEP_ALIVE_SERVICE" ] || return 1
    grep -q '/root/keep_alive.sh' "$OLD_KEEP_ALIVE_SERVICE" && return 0
    grep -q 'Sing-box Routing Keep Alive Daemon' "$OLD_KEEP_ALIVE_SERVICE" && return 0
    return 1
}

function legacy_keep_alive_file_owned_by_script() {
    [ -f "$OLD_KEEP_ALIVE_FILE" ] || return 1
    grep -q 'MARK_INBOUND_HEX="0x114"' "$OLD_KEEP_ALIVE_FILE" && return 0
    grep -q 'TABLE_TUN="100"' "$OLD_KEEP_ALIVE_FILE" && return 0
    grep -q 'ip rule add from all lookup' "$OLD_KEEP_ALIVE_FILE" && return 0
    return 1
}

function cleanup_legacy_keep_alive_service() {
    if legacy_keep_alive_service_owned_by_script || legacy_keep_alive_file_owned_by_script; then
        warn "检测到旧版脚本创建的 keep-alive 保活服务，正在清理。"
        systemctl stop keep-alive 2>/dev/null || true
        systemctl disable keep-alive 2>/dev/null || true
        rm -f "$OLD_KEEP_ALIVE_SERVICE"
        if legacy_keep_alive_file_owned_by_script; then
            rm -f "$OLD_KEEP_ALIVE_FILE"
        fi
    fi
}

function legacy_singbox_config_owned_by_script() {
    [ -f "$LEGACY_CONF_FILE" ] || return 1
    grep -q '"interface_name": "tun0"' "$LEGACY_CONF_FILE" || return 1
    grep -q '"routing_mark": 666' "$LEGACY_CONF_FILE" || return 1
    grep -q '"tag": "tun-in"' "$LEGACY_CONF_FILE" && return 0
    return 1
}

function cleanup_runtime() {
    systemctl stop sing-box-out-guard "$SINGBOX_UNIT" 2>/dev/null || true
    cleanup_legacy_singbox_service
    cleanup_legacy_keep_alive_service
    cleanup_nftables
    cleanup_new_iptables
    cleanup_legacy_iptables
    cleanup_policy_rules
    cleanup_conntrack_state
    flush_route_cache
    ip link set dev tun0 down 2>/dev/null || true
}

function uninstall() {
    warn "正在停止服务并清理 Sing-box 出口代理..."
    systemctl stop sing-box-out-guard "$SINGBOX_UNIT" 2>/dev/null || true
    systemctl disable sing-box-out-guard "$SINGBOX_UNIT" 2>/dev/null || true
    cleanup_legacy_singbox_service
    cleanup_legacy_keep_alive_service

    cleanup_nftables
    cleanup_new_iptables
    cleanup_legacy_iptables
    cleanup_policy_rules

    rm -f "$SINGBOX_SERVICE" "$GUARD_SERVICE"
    systemctl daemon-reload 2>/dev/null || true

    rm -rf "$CONF_DIR" "$RUNTIME_DIR" "$STATE_DIR"
    if legacy_keep_alive_file_owned_by_script; then
        rm -f "$OLD_KEEP_ALIVE_FILE"
    fi
    cleanup_conntrack_state
    flush_route_cache
    ip link set dev tun0 down 2>/dev/null || true

    case "$(basename -- "$0")" in
        bash|sh|dash|busybox) ;;
        *) rm -f -- "$0" 2>/dev/null || true ;;
    esac

    info "卸载完成。服务、配置、守护脚本、策略路由、nftables/iptables 专用规则和脚本文件已清理。"
    exit 0
}

function prompt_singbox_version() {
    local version_choice
    read -r -p "Sing-box 版本 (默认 latest，可填 1.13.14 或 v1.13.14): " version_choice
    SINGBOX_VERSION=${version_choice:-$SINGBOX_VERSION}
    SINGBOX_VERSION=${SINGBOX_VERSION:-latest}
}

function prompt_singbox_install_source() {
    local source_choice package_choice
    echo "安装来源:"
    echo " 1. GitHub 官方 release 下载 (默认)"
    echo " 2. 本地 /root 目录下的 sing-box 压缩包"
    read -r -p "请选择安装来源 (1-2，默认: 1): " source_choice
    case "${source_choice:-1}" in
        1)
            SINGBOX_INSTALL_SOURCE="github"
            SINGBOX_LOCAL_PACKAGE=""
            ;;
        2)
            SINGBOX_INSTALL_SOURCE="local"
            read -r -p "本地压缩包路径 (默认自动检测 /root/sing-box-*-linux-当前架构.tar.gz): " package_choice
            SINGBOX_LOCAL_PACKAGE=${package_choice:-}
            ;;
        *) die "安装来源选择无效。" ;;
    esac
}

function install_singbox_interactive() {
    prompt_singbox_install_source
    prompt_singbox_version
    install_singbox
}

function install_singbox() {
    local arch file_name tar_name url proxy_url tmp_dir target_version installed_version package source extracted_bin
    require_install_commands
    source=${SINGBOX_INSTALL_SOURCE:-github}
    [ "$source" = "github" ] || [ "$source" = "local" ] || die "SINGBOX_INSTALL_SOURCE 只能是 github 或 local。"
    arch=$(singbox_arch) || die "暂不支持的架构: $(uname -m)"

    tmp_dir=$(mktemp -d)
    installed_version=$(installed_singbox_version || true)

    if [ "$source" = "local" ]; then
        package=$(find_local_singbox_package "$arch" "$SINGBOX_VERSION")
        target_version=$(version_from_singbox_package "$package")
        [ -n "$target_version" ] || {
            rm -rf "$tmp_dir"
            die "无法从压缩包文件名解析 sing-box 版本: $package"
        }
        tar_name=$(basename -- "$package")
        file_name="${tar_name%.tar.gz}"
        echo -e "安装来源: ${GREEN}本地压缩包${NC}"
        echo "本地压缩包: $package"
        cp "$package" "$tmp_dir/$tar_name" || {
            rm -rf "$tmp_dir"
            die "复制本地压缩包失败。"
        }
    else
        target_version=$(resolve_singbox_version "$SINGBOX_VERSION") || {
            rm -rf "$tmp_dir"
            die "无法解析 sing-box 目标版本: $SINGBOX_VERSION"
        }
        file_name="sing-box-${target_version}-linux-${arch}"
        tar_name="${file_name}.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/v${target_version}/${tar_name}"
        proxy_url="https://mirror.ghproxy.com/${url}"
        echo -e "安装来源: ${GREEN}GitHub release${NC}"
        echo "开始下载: $url"
        if ! curl -fL --connect-timeout 20 --retry 2 -o "$tmp_dir/$tar_name" "$url"; then
            warn "直接下载失败，尝试使用代理镜像下载..."
            curl -fL --connect-timeout 20 --retry 2 -o "$tmp_dir/$tar_name" "$proxy_url" || {
                rm -rf "$tmp_dir"
                die "下载失败，请检查网络连接，或选择本地压缩包安装。"
            }
        fi
    fi

    version_ge "$target_version" "1.12.0" || {
        rm -rf "$tmp_dir"
        die "当前配置要求 sing-box >= 1.12.0，请使用 1.12.0 以上版本。"
    }

    echo -e "目标版本: ${GREEN}${target_version}${NC}"
    [ -n "$installed_version" ] && echo "当前版本: $installed_version"
    if [ -n "$installed_version" ] && [ "$installed_version" = "$target_version" ]; then
        rm -rf "$tmp_dir"
        info "Sing-box v${target_version} 已安装，无需重复安装。"
        return 0
    fi

    tar -xzf "$tmp_dir/$tar_name" -C "$tmp_dir" || {
        rm -rf "$tmp_dir"
        die "解压失败，下载文件可能损坏。"
    }
    extracted_bin="$tmp_dir/$file_name/sing-box"
    if [ ! -f "$extracted_bin" ]; then
        extracted_bin=$(find "$tmp_dir" -mindepth 2 -maxdepth 3 -type f -name sing-box 2>/dev/null | head -1)
    fi
    [ -f "$extracted_bin" ] || {
        rm -rf "$tmp_dir"
        die "压缩包内未找到 sing-box 二进制。"
    }

    mkdir -p "$RUNTIME_DIR" || {
        rm -rf "$tmp_dir"
        die "创建运行目录失败。"
    }
    install -m 0755 "$extracted_bin" "$BIN_FILE"
    rm -rf "$tmp_dir"
    info "Sing-box v${target_version} 安装/更新成功。"
}

function generate_outbound_json() {
    local server="$1"
    local server_esc port user pass method auth_json uuid flow flow_json tls_enabled tls_json server_name alpn_json alpn_items item
    server_esc=$(json_escape "$server")
    port="$PROXY_PORT"

    if [ "$PROTOCOL" = "socks" ]; then
        auth_json=""
        if [ -n "$PROXY_USER" ] || [ -n "$PROXY_PASS" ]; then
            user=$(json_escape "$PROXY_USER")
            pass=$(json_escape "$PROXY_PASS")
            auth_json=$(cat <<EOF
,
      "username": "$user",
      "password": "$pass"
EOF
)
        fi
        OUTBOUND_JSON=$(cat <<EOF
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "version": "5",
      "routing_mark": 666$auth_json
    }
EOF
)
    elif [ "$PROTOCOL" = "shadowsocks" ]; then
        method=$(json_escape "$SS_METHOD")
        pass=$(json_escape "$PROXY_PASS")
        OUTBOUND_JSON=$(cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "method": "$method",
      "password": "$pass",
      "routing_mark": 666
    }
EOF
)
    elif [ "$PROTOCOL" = "vless" ]; then
        uuid=$(json_escape "$VLESS_UUID")
        flow_json=""
        if [ -n "${VLESS_FLOW:-}" ]; then
            flow=$(json_escape "$VLESS_FLOW")
            flow_json=$(cat <<EOF
,
      "flow": "$flow"
EOF
)
        fi

        tls_json=""
        tls_enabled="${VLESS_TLS:-false}"
        if [ "$tls_enabled" = "true" ]; then
            server_name="${VLESS_SERVER_NAME:-$PROXY_HOST}"
            server_name=$(json_escape "$server_name")
            alpn_json=""
            if [ -n "${VLESS_ALPN:-}" ]; then
                alpn_items=""
                IFS=',' read -ra __vless_alpn_list <<< "$VLESS_ALPN"
                for item in "${__vless_alpn_list[@]}"; do
                    item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [ -n "$item" ] || continue
                    item=$(json_escape "$item")
                    if [ -n "$alpn_items" ]; then
                        alpn_items="$alpn_items, \"$item\""
                    else
                        alpn_items="\"$item\""
                    fi
                done
                [ -n "$alpn_items" ] && alpn_json=", \"alpn\": [$alpn_items]"
            fi
            tls_json=$(cat <<EOF
,
      "tls": {
        "enabled": true,
        "server_name": "$server_name"$alpn_json
      }
EOF
)
        fi

        OUTBOUND_JSON=$(cat <<EOF
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$server_esc",
      "server_port": $port,
      "uuid": "$uuid",
      "network": "tcp",
      "routing_mark": 666$flow_json$tls_json
    }
EOF
)
    else
        die "不支持的协议: $PROTOCOL"
    fi
}

function build_split_rules() {
    if [ "$ENABLE_SPLIT" = "true" ]; then
        SPLIT_RULES=$(cat <<'EOF'
      { "domain_suffix": ["github.com", "githubusercontent.com", "githubassets.com", "github.io"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["docker.io", "docker.com", "dockerhub.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["debian.org", "ubuntu.com", "canonical.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["centos.org", "fedoraproject.org", "redhat.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["alpinelinux.org", "archlinux.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["npmjs.org", "npmjs.com", "yarnpkg.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["pypi.org", "pythonhosted.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["golang.org", "go.dev", "proxy.golang.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["maven.org", "mvnrepository.com"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["rubygems.org", "crates.io", "packagist.org"], "action": "route", "outbound": "direct" },
      { "domain_suffix": ["cloudflare.com", "fastly.net", "akamai.net"], "action": "route", "outbound": "direct" },
EOF
)
    else
        SPLIT_RULES=""
    fi
}

function write_config_template() {
    local host_esc iface_esc domain_route private_cidr
    host_esc=$(json_escape "$PROXY_HOST")
    iface_esc=$(json_escape "$WAN_IFACE")
    private_cidr='"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"'

    domain_route=""
    if ! is_ipv4 "$PROXY_HOST" && ! is_ipv6 "$PROXY_HOST"; then
        domain_route="      { \"domain\": [\"$host_esc\"], \"action\": \"route\", \"outbound\": \"direct\" },"
    fi

    build_split_rules
    generate_outbound_json "__PROXY_IP__"

    mkdir -p "$CONF_DIR" "$STATE_DIR"
    cat > "$TEMPLATE_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "cf_v4", "server": "1.1.1.1", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "google_v4", "server": "8.8.8.8", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "cf_v6", "server": "2606:4700:4700::1111", "server_port": 53, "detour": "direct" },
      { "type": "udp", "tag": "google_v6", "server": "2001:4860:4860::8888", "server_port": 53, "detour": "direct" }
    ],
    "rules": [],
    "final": "cf_v4",
    "strategy": "prefer_ipv4",
    "cache_capacity": 4096
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["$TUN_IPV4", "$TUN_IPV6"],
      "mtu": 1400,
      "stack": "mixed",
      "auto_route": false,
      "strict_route": false,
      "endpoint_independent_nat": true
    }
  ],
  "outbounds": [
$OUTBOUND_JSON,
    {
      "type": "direct",
      "tag": "direct",
      "bind_interface": "$iface_esc"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "cf_v4", "strategy": "prefer_ipv4" },
    "rules": [
      { "inbound": ["tun-in"], "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_cidr": ["__PROXY_CIDR__"], "action": "route", "outbound": "direct" },
$domain_route
$SPLIT_RULES
      { "ip_cidr": [$private_cidr], "action": "route", "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF
    chmod 600 "$TEMPLATE_FILE"
}

function write_renderer() {
    mkdir -p "$RUNTIME_DIR"
    cat > "$RENDER_FILE" <<EOF
#!/bin/bash
set -e
CONF_FILE=$(shell_quote "$CONF_FILE")
TEMPLATE_FILE=$(shell_quote "$TEMPLATE_FILE")
STATE_FILE=$(shell_quote "$STATE_FILE")

is_ipv4() {
    [[ "\$1" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]]
}

cidr_for_ip() {
    if is_ipv4 "\$1"; then
        printf '%s/32\\n' "\$1"
    else
        printf '%s/128\\n' "\$1"
    fi
}

proxy_ip="\$1"
[ -n "\$proxy_ip" ] || { echo "missing proxy ip" >&2; exit 1; }
proxy_cidr=\$(cidr_for_ip "\$proxy_ip")
tmp="\${CONF_FILE}.tmp.\$\$"
sed -e "s|__PROXY_IP__|\$proxy_ip|g" -e "s|__PROXY_CIDR__|\$proxy_cidr|g" "\$TEMPLATE_FILE" > "\$tmp"
install -m 0600 "\$tmp" "\$CONF_FILE"
rm -f "\$tmp"
printf '%s\\n' "\$proxy_ip" > "\$STATE_FILE"
chmod 600 "\$STATE_FILE"
EOF
    chmod +x "$RENDER_FILE"
}

function write_meta() {
    cat > "$META_FILE" <<EOF
PROTOCOL=$PROTOCOL
PROXY_HOST=$PROXY_HOST
PROXY_PORT=$PROXY_PORT
WAN_IFACE=$WAN_IFACE
ENABLE_SPLIT=$ENABLE_SPLIT
PROXY_SOURCE_CIDRS=$PROXY_SOURCE_CIDRS
PROXY_HOST_TRAFFIC=$PROXY_HOST_TRAFFIC
DDNS_INTERVAL=$DDNS_INTERVAL
SSH_PORT=$SSH_PORT
SSH_CLIENT_IP=$SSH_CLIENT_IP
SINGBOX_VERSION=$SINGBOX_VERSION
SINGBOX_INSTALL_SOURCE=$SINGBOX_INSTALL_SOURCE
SINGBOX_LOCAL_PACKAGE=$SINGBOX_LOCAL_PACKAGE
VLESS_UUID=${VLESS_UUID:-}
VLESS_TLS=${VLESS_TLS:-}
VLESS_SERVER_NAME=${VLESS_SERVER_NAME:-}
VLESS_ALPN=${VLESS_ALPN:-}
VLESS_FLOW=${VLESS_FLOW:-}
EOF
    chmod 600 "$META_FILE"
}

function write_guard() {
    mkdir -p "$RUNTIME_DIR"
    cat > "$GUARD_FILE" <<EOF
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROXY_HOST=$(shell_quote "$PROXY_HOST")
WAN_IFACE=$(shell_quote "$WAN_IFACE")
SSH_CLIENT_IP=$(shell_quote "$SSH_CLIENT_IP")
SSH_PORT=$(shell_quote "$SSH_PORT")
DDNS_INTERVAL=$(shell_quote "$DDNS_INTERVAL")
ENABLE_SPLIT=$(shell_quote "$ENABLE_SPLIT")
PROXY_SOURCE_CIDRS=$(shell_quote "$PROXY_SOURCE_CIDRS")
PROXY_HOST_TRAFFIC=$(shell_quote "$PROXY_HOST_TRAFFIC")
SINGBOX_UNIT=$(shell_quote "$SINGBOX_UNIT")

CONF_FILE=$(shell_quote "$CONF_FILE")
STATE_FILE=$(shell_quote "$STATE_FILE")
RENDER_FILE=$(shell_quote "$RENDER_FILE")
BIN_FILE=$(shell_quote "$BIN_FILE")
TABLE_TUN=$(shell_quote "$TABLE_TUN")
MARK_OUTBOUND_HEX=$(shell_quote "$MARK_OUTBOUND_HEX")
MARK_INBOUND_HEX=$(shell_quote "$MARK_INBOUND_HEX")
NFT_TABLE=$(shell_quote "$NFT_TABLE")
NFT_STATE_FILE=$(shell_quote "$NFT_STATE_FILE")

log() {
    logger -t sing-box-out-guard -- "\$*"
    echo "\$(date '+%F %T') \$*"
}

is_ipv4() {
    local ip="\$1" a b c d
    [[ "\$ip" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "\$ip"
    for n in "\$a" "\$b" "\$c" "\$d"; do
        [[ "\$n" =~ ^[0-9]+$ ]] || return 1
        [ "\$n" -ge 0 ] && [ "\$n" -le 255 ] || return 1
    done
}

is_ipv6() {
    [[ "\$1" == *:* ]]
}

resolve_host_ipv4() {
    local host="\$1" ip
    if is_ipv4 "\$host"; then printf '%s\\n' "\$host"; return 0; fi
    if command -v getent >/dev/null 2>&1; then
        ip=\$(getent ahostsv4 "\$host" 2>/dev/null | awk '{print \$1}' | grep -m1 -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}$')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
    fi
    if command -v dig >/dev/null 2>&1; then
        ip=\$(dig +short A "\$host" @1.1.1.1 2>/dev/null | grep -m1 -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}$')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
        ip=\$(dig +short A "\$host" @8.8.8.8 2>/dev/null | grep -m1 -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}$')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
    fi
    if command -v nslookup >/dev/null 2>&1; then
        ip=\$(nslookup -type=A "\$host" 1.1.1.1 2>/dev/null | awk '/^Address: / {print \$2}' | grep -m1 -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}$')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
    fi
    return 1
}

resolve_host_ipv6() {
    local host="\$1" ip
    if is_ipv6 "\$host"; then printf '%s\\n' "\$host"; return 0; fi
    if command -v getent >/dev/null 2>&1; then
        ip=\$(getent ahostsv6 "\$host" 2>/dev/null | awk '{print \$1}' | grep -m1 ':')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
    fi
    if command -v dig >/dev/null 2>&1; then
        ip=\$(dig +short AAAA "\$host" @2606:4700:4700::1111 2>/dev/null | grep -m1 ':')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
        ip=\$(dig +short AAAA "\$host" @2001:4860:4860::8888 2>/dev/null | grep -m1 ':')
        [ -n "\$ip" ] && { printf '%s\\n' "\$ip"; return 0; }
    fi
    return 1
}

resolve_host_ip() {
    local ip
    ip=\$(resolve_host_ipv4 "\$PROXY_HOST" 2>/dev/null) && { printf '%s\\n' "\$ip"; return 0; }
    ip=\$(resolve_host_ipv6 "\$PROXY_HOST" 2>/dev/null) && { printf '%s\\n' "\$ip"; return 0; }
    return 1
}

cleanup_managed_rules() {
    local prio
    for prio in 10 15 20 50 60 70 100; do
        while ip rule del priority "\$prio" 2>/dev/null; do :; done
        while ip -6 rule del priority "\$prio" 2>/dev/null; do :; done
    done
}

rule_exists() {
    local family="\$1" prio="\$2" pattern="\$3"
    if [ "\$family" = "6" ]; then
        ip -6 rule show
    else
        ip rule show
    fi | awk -v prio="\${prio}:" -v pattern="\$pattern" 'index(\$0, prio) == 1 && index(\$0, pattern) > 0 {found=1} END {exit found ? 0 : 1}'
}

add_rule_once() {
    local family="\$1" prio="\$2" pattern="\$3"
    shift 3
    rule_exists "\$family" "\$prio" "\$pattern" && return 0
    if [ "\$family" = "6" ]; then
        ip -6 rule add "\$@" priority "\$prio" 2>/dev/null || true
    else
        ip rule add "\$@" priority "\$prio" 2>/dev/null || true
    fi
}

rule_addr_pattern() {
    local cidr="\$1"
    case "\$cidr" in
        */32|*/128) printf '%s\\n' "\${cidr%/*}" ;;
        *) printf '%s\\n' "\$cidr" ;;
    esac
}

add_main_rule_to_ip() {
    local ip="\$1" prio="\$2"
    if is_ipv4 "\$ip"; then
        add_rule_once 4 "\$prio" "to \$ip lookup main" to "\$ip" lookup main
    else
        add_rule_once 6 "\$prio" "to \$ip lookup main" to "\$ip" lookup main
    fi
}

add_ssh_port_rules() {
    add_rule_once 4 15 "ipproto tcp sport \$SSH_PORT lookup main" ipproto tcp sport "\$SSH_PORT" lookup main
    add_rule_once 4 15 "ipproto tcp dport \$SSH_PORT lookup main" ipproto tcp dport "\$SSH_PORT" lookup main
    add_rule_once 6 15 "ipproto tcp sport \$SSH_PORT lookup main" ipproto tcp sport "\$SSH_PORT" lookup main
    add_rule_once 6 15 "ipproto tcp dport \$SSH_PORT lookup main" ipproto tcp dport "\$SSH_PORT" lookup main
}

add_main_rule_to_cidr() {
    local cidr="\$1" prio="\$2" match_cidr
    match_cidr=\$(rule_addr_pattern "\$cidr")
    if [[ "\$cidr" == *:* ]]; then
        add_rule_once 6 "\$prio" "to \$match_cidr lookup main" to "\$cidr" lookup main
    else
        add_rule_once 4 "\$prio" "to \$match_cidr lookup main" to "\$cidr" lookup main
    fi
}

add_tun_rule_from_cidr() {
    local cidr="\$1" prio="\$2" match_cidr
    match_cidr=\$(rule_addr_pattern "\$cidr")
    if [[ "\$cidr" == *:* ]]; then
        add_rule_once 6 "\$prio" "from \$match_cidr lookup \$TABLE_TUN" from "\$cidr" lookup "\$TABLE_TUN"
    else
        add_rule_once 4 "\$prio" "from \$match_cidr lookup \$TABLE_TUN" from "\$cidr" lookup "\$TABLE_TUN"
    fi
}

ensure_policy_routes() {
    local proxy_ip cidr added_source_rule
    proxy_ip=\$(cat "\$STATE_FILE" 2>/dev/null || true)

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.\${WAN_IFACE}.accept_ra=2" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.conf.\${WAN_IFACE}.rp_filter=2" >/dev/null 2>&1 || true

    if ip link show tun0 >/dev/null 2>&1; then
        ip link set dev tun0 up 2>/dev/null || true
        ip route replace default dev tun0 table "\$TABLE_TUN" 2>/dev/null || true
        ip -6 route replace default dev tun0 table "\$TABLE_TUN" 2>/dev/null || true
    fi

    if [ -n "\$SSH_CLIENT_IP" ]; then
        if is_ipv4 "\$SSH_CLIENT_IP"; then
            add_rule_once 4 10 "from \$SSH_CLIENT_IP lookup main" from "\$SSH_CLIENT_IP" lookup main
            add_rule_once 4 10 "to \$SSH_CLIENT_IP lookup main" to "\$SSH_CLIENT_IP" lookup main
        else
            add_rule_once 6 10 "from \$SSH_CLIENT_IP lookup main" from "\$SSH_CLIENT_IP" lookup main
            add_rule_once 6 10 "to \$SSH_CLIENT_IP lookup main" to "\$SSH_CLIENT_IP" lookup main
        fi
    fi

    add_ssh_port_rules
    [ -n "\$proxy_ip" ] && add_main_rule_to_ip "\$proxy_ip" 20

    add_rule_once 4 50 "fwmark \$MARK_INBOUND_HEX lookup main" fwmark "\$MARK_INBOUND_HEX" lookup main
    add_rule_once 6 50 "fwmark \$MARK_INBOUND_HEX lookup main" fwmark "\$MARK_INBOUND_HEX" lookup main
    add_rule_once 4 60 "fwmark \$MARK_OUTBOUND_HEX lookup main" fwmark "\$MARK_OUTBOUND_HEX" lookup main
    add_rule_once 6 60 "fwmark \$MARK_OUTBOUND_HEX lookup main" fwmark "\$MARK_OUTBOUND_HEX" lookup main

    for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 ::1/128 fc00::/7 fe80::/10; do
        add_main_rule_to_cidr "\$cidr" 70
    done

    if [ "\$ENABLE_SPLIT" = "true" ]; then
        for cidr in 140.82.112.0/20 143.55.64.0/20 185.199.108.0/22 192.30.252.0/22 44.205.64.0/20 52.1.184.0/21; do
            add_main_rule_to_cidr "\$cidr" 70
        done
    fi

    added_source_rule=false
    for cidr in \$PROXY_SOURCE_CIDRS; do
        add_tun_rule_from_cidr "\$cidr" 100
        added_source_rule=true
    done

    if [ "\$PROXY_HOST_TRAFFIC" = "true" ]; then
        add_rule_once 4 100 "from all lookup \$TABLE_TUN" from all lookup "\$TABLE_TUN"
        add_rule_once 6 100 "from all lookup \$TABLE_TUN" from all lookup "\$TABLE_TUN"
    elif [ "\$added_source_rule" != "true" ]; then
        log "未检测到容器/KVM 源网段，未接管宿主机自身流量；如需全局接管宿主机，请设置 PROXY_HOST_TRAFFIC=true，或用 PROXY_SOURCE_CIDRS 手动指定源网段。"
    fi
}

ensure_nftables() {
    local tmp check_tmp check_table desired_state current_state
    desired_state="iface=\$WAN_IFACE ssh=\$SSH_PORT mark_in=\$MARK_INBOUND_HEX"
    current_state=\$(cat "\$NFT_STATE_FILE" 2>/dev/null || true)
    if [ "\$current_state" = "\$desired_state" ] && nft list table inet "\$NFT_TABLE" >/dev/null 2>&1; then
        return 0
    fi

    tmp=\$(mktemp)
    check_tmp=\$(mktemp)
    check_table="\${NFT_TABLE}_check"
    cat > "\$tmp" <<NFT
table inet \$NFT_TABLE {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "\$WAN_IFACE" tcp dport \$SSH_PORT return comment "sing-box-out \$desired_state"
    iifname "\$WAN_IFACE" ct state new ct mark set \$MARK_INBOUND_HEX meta mark set \$MARK_INBOUND_HEX
    ct mark \$MARK_INBOUND_HEX meta mark set \$MARK_INBOUND_HEX
  }

  chain output {
    type route hook output priority mangle; policy accept;
    tcp sport \$SSH_PORT return
    ct mark \$MARK_INBOUND_HEX meta mark set \$MARK_INBOUND_HEX
  }
}
NFT
    sed "s/table inet \$NFT_TABLE/table inet \$check_table/" "\$tmp" > "\$check_tmp"
    if ! nft -c -f "\$check_tmp" 2>/tmp/sing-box-out-nft.log; then
        log "nftables 规则预检查失败: \$(cat /tmp/sing-box-out-nft.log 2>/dev/null)"
        rm -f "\$tmp" "\$check_tmp"
        return 1
    fi

    nft delete table inet "\$NFT_TABLE" 2>/dev/null || true
    if ! nft -f "\$tmp" 2>/tmp/sing-box-out-nft.log; then
        log "nftables 规则加载失败: \$(cat /tmp/sing-box-out-nft.log 2>/dev/null)"
        rm -f "\$NFT_STATE_FILE"
        rm -f "\$tmp" "\$check_tmp"
        return 1
    fi
    printf '%s\\n' "\$desired_state" > "\$NFT_STATE_FILE"
    rm -f "\$tmp" "\$check_tmp"
}

refresh_proxy_ip() {
    local old_ip new_ip backup
    old_ip=\$(cat "\$STATE_FILE" 2>/dev/null || true)
    if ! new_ip=\$(resolve_host_ip); then
        log "DDNS 解析失败: \$PROXY_HOST"
        return 1
    fi

    if [ "\$new_ip" = "\$old_ip" ]; then
        return 0
    fi

    log "检测到出口节点 IP 变化: \${old_ip:-none} -> \$new_ip"
    backup="\${CONF_FILE}.bak.\$\$"
    [ -f "\$CONF_FILE" ] && cp -f "\$CONF_FILE" "\$backup"

    if "\$RENDER_FILE" "\$new_ip" && "\$BIN_FILE" check -c "\$CONF_FILE" >/tmp/sing-box-out-check.log 2>&1; then
        add_main_rule_to_ip "\$new_ip" 20
        if systemctl restart "\$SINGBOX_UNIT"; then
            rm -f "\$backup"
            log "已更新 \$SINGBOX_UNIT 配置并重启服务，新出口节点 IP: \$new_ip"
            return 0
        fi
        log "\$SINGBOX_UNIT 重启失败，准备回滚配置"
    else
        log "新配置校验失败，准备回滚配置: \$(cat /tmp/sing-box-out-check.log 2>/dev/null)"
    fi

    if [ -f "\$backup" ]; then
        install -m 0600 "\$backup" "\$CONF_FILE"
        rm -f "\$backup"
        [ -n "\$old_ip" ] && printf '%s\\n' "\$old_ip" > "\$STATE_FILE"
        systemctl restart "\$SINGBOX_UNIT" 2>/dev/null || true
    fi
    return 1
}

log "守护进程启动: host=\$PROXY_HOST interval=\${DDNS_INTERVAL}s iface=\$WAN_IFACE"

for i in {1..30}; do
    ip link show tun0 >/dev/null 2>&1 && break
    sleep 1
done

last_check=0
while true; do
    now=\$(date +%s)
    if [ \$((now - last_check)) -ge "\$DDNS_INTERVAL" ]; then
        refresh_proxy_ip || true
        last_check="\$now"
    fi
    ensure_policy_routes
    ensure_nftables
    sleep 2
done
EOF
    chmod +x "$GUARD_FILE"
}

function write_services() {
    cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=sing-box Out Proxy Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$BIN_FILE check -c $CONF_FILE
ExecStart=$BIN_FILE run -c $CONF_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    cat > "$GUARD_SERVICE" <<EOF
[Unit]
Description=Sing-box Out Routing and DDNS Guard
After=network-online.target ${SINGBOX_UNIT}.service
Wants=network-online.target ${SINGBOX_UNIT}.service

[Service]
Type=simple
ExecStart=/bin/bash $GUARD_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

function interactive_config() {
    local interfaces iface i selection proto_choice split_choice default_wan detected_ssh_port
    clear
    echo -e "${BLUE}=== 1. 物理网卡选择 ===${NC}"
    default_wan=$(default_iface)
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|tun|docker|veth|br-|lxc|virbr|incusbr)')
    declare -a iface_list
    i=1
    for iface in $interfaces; do
        iface_list[$i]=$iface
        if [ "$iface" = "$default_wan" ]; then
            default_index="$i"
        fi
        i=$((i+1))
    done
    default_index=${default_index:-1}

    if [ "${#iface_list[@]}" -eq 0 ]; then
        die "未检测到有效物理网卡。"
    fi

    for index in "${!iface_list[@]}"; do
        if [ "${iface_list[$index]}" = "$default_wan" ]; then
            echo " [$index] ${iface_list[$index]} (默认路由)"
        else
            echo " [$index] ${iface_list[$index]}"
        fi
    done
    read -r -p "请输入要绑定直连出口的网卡序号 (默认: $default_index): " selection
    selection=${selection:-$default_index}
    WAN_IFACE="${iface_list[$selection]}"
    [ -n "$WAN_IFACE" ] || die "网卡选择无效。"
    is_wan_candidate "$WAN_IFACE" || die "网卡 $WAN_IFACE 不适合作为物理出口网卡。"
    info "已选择出网网卡: $WAN_IFACE"
    echo

    echo -e "${BLUE}=== 2. 代理协议选择 ===${NC}"
    echo " 1. SOCKS5"
    echo " 2. Shadowsocks"
    echo " 3. VLESS + TCP"
    read -r -p "请输入序号 (1-3): " proto_choice
    case "$proto_choice" in
        1)
            PROTOCOL="socks"
            echo -e "${YELLOW}[SOCKS5]${NC} 请输入节点信息:"
            read -r -p "地址 / DDNS 域名: " PROXY_HOST
            read -r -p "端口: " PROXY_PORT
            read -r -p "用户名 (可选): " PROXY_USER
            read -r -s -p "密码 (可选): " PROXY_PASS
            echo
            ;;
        2)
            PROTOCOL="shadowsocks"
            echo -e "${YELLOW}[Shadowsocks]${NC} 请输入节点信息:"
            read -r -p "地址 / DDNS 域名: " PROXY_HOST
            read -r -p "端口: " PROXY_PORT
            read -r -s -p "密码: " PROXY_PASS
            echo
            echo "常用加密方式: aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305"
            read -r -p "请输入加密方式名称 (默认 chacha20-ietf-poly1305): " SS_METHOD
            SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}
            ;;
        3)
            PROTOCOL="vless"
            echo -e "${YELLOW}[VLESS+TCP]${NC} 请输入节点信息:"
            read -r -p "地址 / DDNS 域名: " PROXY_HOST
            read -r -p "端口: " PROXY_PORT
            read -r -p "UUID: " VLESS_UUID
            read -r -p "是否启用 TLS (true/false，默认 false): " VLESS_TLS
            VLESS_TLS=${VLESS_TLS:-false}
            if [ "$VLESS_TLS" = "true" ]; then
                read -r -p "TLS server_name (默认使用节点地址): " VLESS_SERVER_NAME
                read -r -p "ALPN (可选，逗号分隔，如 h2,http/1.1): " VLESS_ALPN
            fi
            read -r -p "flow (可选，如 xtls-rprx-vision): " VLESS_FLOW
            ;;
        *) die "协议选择无效。" ;;
    esac

    [ -n "$PROXY_HOST" ] || die "代理地址不能为空。"
    validate_port "$PROXY_PORT" || die "代理端口无效。"
    if [ "$PROTOCOL" = "vless" ]; then
        validate_uuid "$VLESS_UUID" || die "VLESS UUID 无效。"
        [ "$VLESS_TLS" = "true" ] || [ "$VLESS_TLS" = "false" ] || die "VLESS_TLS 只能是 true 或 false。"
    fi

    echo
    echo -e "${BLUE}=== 3. 路由与分流规则 ===${NC}"
    echo " 1. 推荐分流 (沿用当前脚本的 GitHub、Docker、常见源直连规则)"
    echo " 2. 全局代理 (除内网、SSH、代理节点自身外全部走代理)"
    read -r -p "请选择分流模式 (1-2，默认: 1): " split_choice
    split_choice=${split_choice:-1}
    if [ "$split_choice" = "1" ]; then
        ENABLE_SPLIT="true"
    else
        ENABLE_SPLIT="false"
    fi

    echo
    echo -e "${BLUE}=== 4. 代理源网段 ===${NC}"
    PROXY_SOURCE_CIDRS=$(detect_proxy_source_cidrs)
    if [ -n "$PROXY_SOURCE_CIDRS" ]; then
        echo "检测到容器/KVM 网段: $PROXY_SOURCE_CIDRS"
    else
        warn "未自动检测到 incusbr/lxcbr/virbr/br-/docker 网桥网段。"
    fi
    read -r -p "需要走出口机的源网段 (默认使用检测结果，可空格/逗号分隔): " input_source_cidrs
    PROXY_SOURCE_CIDRS=$(normalize_cidr_list "${input_source_cidrs:-$PROXY_SOURCE_CIDRS}")

    read -r -p "是否也代理入口机宿主机自身流量 (true/false，默认 $DEFAULT_PROXY_HOST_TRAFFIC): " PROXY_HOST_TRAFFIC
    PROXY_HOST_TRAFFIC=${PROXY_HOST_TRAFFIC:-$DEFAULT_PROXY_HOST_TRAFFIC}
    [ "$PROXY_HOST_TRAFFIC" = "true" ] || [ "$PROXY_HOST_TRAFFIC" = "false" ] || die "PROXY_HOST_TRAFFIC 只能是 true 或 false。"

    echo
    echo -e "${BLUE}=== 5. DDNS 与 SSH 保护 ===${NC}"
    read -r -p "DDNS 检测间隔秒数 (默认: $DEFAULT_DDNS_INTERVAL): " DDNS_INTERVAL
    DDNS_INTERVAL=${DDNS_INTERVAL:-$DEFAULT_DDNS_INTERVAL}
    [[ "$DDNS_INTERVAL" =~ ^[0-9]+$ ]] && [ "$DDNS_INTERVAL" -ge 5 ] || die "DDNS 检测间隔不能小于 5 秒。"

    detected_ssh_port=$(detect_ssh_port)
    read -r -p "SSH 保护端口 (默认: $detected_ssh_port): " SSH_PORT
    SSH_PORT=${SSH_PORT:-$detected_ssh_port}
    validate_port "$SSH_PORT" || die "SSH 端口无效。"

    SSH_CLIENT_IP=$(detect_ssh_client_ip)
    read -r -p "当前 SSH 客户端 IP 保护 (默认: ${SSH_CLIENT_IP:-跳过}): " input_ssh_ip
    SSH_CLIENT_IP=${input_ssh_ip:-$SSH_CLIENT_IP}

    echo
    echo -e "${BLUE}=== 6. Sing-box 核心版本 ===${NC}"
    prompt_singbox_install_source
    prompt_singbox_version
}

function load_env_config() {
    local saved_wan saved_singbox_version saved_singbox_install_source saved_singbox_local_package
    saved_wan=$(saved_meta_value WAN_IFACE 2>/dev/null || true)
    saved_singbox_version=$(saved_meta_value SINGBOX_VERSION 2>/dev/null || true)
    saved_singbox_install_source=$(saved_meta_value SINGBOX_INSTALL_SOURCE 2>/dev/null || true)
    saved_singbox_local_package=$(saved_meta_value SINGBOX_LOCAL_PACKAGE 2>/dev/null || true)
    if [ -n "${WAN_IFACE:-}" ]; then
        :
    elif is_wan_candidate "$saved_wan"; then
        WAN_IFACE="$saved_wan"
    else
        WAN_IFACE=$(default_iface)
    fi
    PROTOCOL=${PROTOCOL:-${PROXY_PROTOCOL:-}}
    PROXY_HOST=${PROXY_HOST:-${PROXY_ADDR:-}}
    PROXY_PORT=${PROXY_PORT:-}
    ENABLE_SPLIT=${ENABLE_SPLIT:-true}
    PROXY_SOURCE_CIDRS=${PROXY_SOURCE_CIDRS:-$(detect_proxy_source_cidrs)}
    PROXY_SOURCE_CIDRS=$(normalize_cidr_list "$PROXY_SOURCE_CIDRS")
    PROXY_HOST_TRAFFIC=${PROXY_HOST_TRAFFIC:-$DEFAULT_PROXY_HOST_TRAFFIC}
    DDNS_INTERVAL=${DDNS_INTERVAL:-$DEFAULT_DDNS_INTERVAL}
    SSH_PORT=${SSH_PORT:-$(detect_ssh_port)}
    SSH_CLIENT_IP=${SSH_CLIENT_IP:-$(detect_ssh_client_ip)}
    SINGBOX_VERSION=${SINGBOX_VERSION:-${saved_singbox_version:-latest}}
    SINGBOX_INSTALL_SOURCE=${SINGBOX_INSTALL_SOURCE:-${saved_singbox_install_source:-github}}
    SINGBOX_LOCAL_PACKAGE=${SINGBOX_LOCAL_PACKAGE:-${saved_singbox_local_package:-}}
    VLESS_UUID=${VLESS_UUID:-${PROXY_UUID:-${UUID:-}}}
    VLESS_TLS=${VLESS_TLS:-false}
    VLESS_SERVER_NAME=${VLESS_SERVER_NAME:-}
    VLESS_ALPN=${VLESS_ALPN:-}
    VLESS_FLOW=${VLESS_FLOW:-}

    [ -n "$WAN_IFACE" ] || die "未指定 WAN_IFACE，且无法自动检测默认网卡。"
    is_wan_candidate "$WAN_IFACE" || die "WAN_IFACE=$WAN_IFACE 不适合作为物理出口网卡。"
    [ "$PROTOCOL" = "socks" ] || [ "$PROTOCOL" = "shadowsocks" ] || [ "$PROTOCOL" = "vless" ] || die "PROTOCOL 只支持 socks、shadowsocks 或 vless。"
    [ -n "$PROXY_HOST" ] || die "未指定 PROXY_HOST。"
    validate_port "$PROXY_PORT" || die "PROXY_PORT 无效。"
    [ "$PROXY_HOST_TRAFFIC" = "true" ] || [ "$PROXY_HOST_TRAFFIC" = "false" ] || die "PROXY_HOST_TRAFFIC 只能是 true 或 false。"
    [[ "$DDNS_INTERVAL" =~ ^[0-9]+$ ]] && [ "$DDNS_INTERVAL" -ge 5 ] || die "DDNS_INTERVAL 不能小于 5。"
    validate_port "$SSH_PORT" || die "SSH_PORT 无效。"
    [ "$SINGBOX_INSTALL_SOURCE" = "github" ] || [ "$SINGBOX_INSTALL_SOURCE" = "local" ] || die "SINGBOX_INSTALL_SOURCE 只能是 github 或 local。"

    if [ "$PROTOCOL" = "shadowsocks" ]; then
        [ -n "$PROXY_PASS" ] || die "Shadowsocks 需要 PROXY_PASS。"
        SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}
    elif [ "$PROTOCOL" = "vless" ]; then
        validate_uuid "$VLESS_UUID" || die "VLESS 需要有效的 VLESS_UUID。"
        [ "$VLESS_TLS" = "true" ] || [ "$VLESS_TLS" = "false" ] || die "VLESS_TLS 只能是 true 或 false。"
        PROXY_USER=${PROXY_USER:-}
        PROXY_PASS=${PROXY_PASS:-}
    else
        PROXY_USER=${PROXY_USER:-}
        PROXY_PASS=${PROXY_PASS:-}
    fi
}

function deploy() {
    local mode="$1" initial_ip stage_dir
    local real_conf_file real_template_file real_state_file real_render_file
    require_commands

    if [ "$mode" = "auto" ]; then
        load_env_config
    else
        interactive_config
    fi

    echo
    echo -e "${BLUE}=== 解析出口节点 DDNS/IP ===${NC}"
    initial_ip=$(resolve_host_ip "$PROXY_HOST") || die "无法解析出口节点地址: $PROXY_HOST"
    info "当前出口节点解析结果: $PROXY_HOST -> $initial_ip"

    install_singbox

    real_conf_file="$CONF_FILE"
    real_template_file="$TEMPLATE_FILE"
    real_state_file="$STATE_FILE"
    real_render_file="$RENDER_FILE"
    stage_dir=$(mktemp -d) || die "创建临时配置目录失败。"
    CONF_FILE="$stage_dir/config.json"
    TEMPLATE_FILE="$stage_dir/config.template.json"
    STATE_FILE="$stage_dir/proxy_ip"
    RENDER_FILE="$stage_dir/render_config.sh"

    write_config_template
    write_renderer
    "$RENDER_FILE" "$initial_ip" || {
        rm -rf "$stage_dir"
        die "生成 sing-box 配置失败，已停止部署。"
    }

    "$BIN_FILE" check -c "$CONF_FILE" || {
        rm -rf "$stage_dir"
        die "sing-box 配置校验失败，已停止部署。"
    }

    cleanup_runtime

    CONF_FILE="$real_conf_file"
    TEMPLATE_FILE="$real_template_file"
    STATE_FILE="$real_state_file"
    RENDER_FILE="$real_render_file"
    mkdir -p "$CONF_DIR" "$STATE_DIR" "$RUNTIME_DIR" || {
        rm -rf "$stage_dir"
        die "创建正式配置目录失败。"
    }
    install -m 0600 "$stage_dir/config.json" "$CONF_FILE" || {
        rm -rf "$stage_dir"
        die "安装 sing-box 配置失败。"
    }
    install -m 0600 "$stage_dir/config.template.json" "$TEMPLATE_FILE" || {
        rm -rf "$stage_dir"
        die "安装配置模板失败。"
    }
    install -m 0600 "$stage_dir/proxy_ip" "$STATE_FILE" || {
        rm -rf "$stage_dir"
        die "写入出口节点状态失败。"
    }
    rm -rf "$stage_dir"
    stage_dir=""
    write_renderer
    write_meta

    write_guard
    write_services

    cleanup_legacy_keep_alive_service
    systemctl daemon-reload || die "systemd daemon-reload 失败。"
    systemctl enable "$SINGBOX_UNIT" sing-box-out-guard >/dev/null || die "启用 systemd 服务失败。"
    systemctl restart "$SINGBOX_UNIT" || die "启动 $SINGBOX_UNIT 失败，请查看 journalctl -u $SINGBOX_UNIT。"
    systemctl restart sing-box-out-guard || die "启动 sing-box-out-guard 失败，请查看 journalctl -u sing-box-out-guard。"

    info "部署完成。$SINGBOX_UNIT 已启动，DDNS/路由守护进程已启用。"
    echo "当前落地节点 IP: $initial_ip"
    [ "$mode" = "auto" ] || pause
}

case "${1:-}" in
    --deploy)
        deploy auto
        ;;
    --install-core)
        install_singbox
        ;;
    --status)
        check_status
        ;;
    --uninstall)
        uninstall
        ;;
    *)
        while true; do
            print_menu
            read -r -p "请输入选项: " CHOICE
            case "$CHOICE" in
                1) deploy interactive ;;
                2) install_singbox_interactive; pause ;;
                3) check_status ;;
                4) uninstall ;;
                0) info "退出脚本。"; exit 0 ;;
                *) err "无效选项，请重新输入。"; sleep 1 ;;
            esac
        done
        ;;
esac
