#!/usr/bin/env bash
# Freshly deploy, discover, inspect, and completely remove HE/SIT IPv6 tunnels.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.1.2"
readonly MARKER="Managed by he-tunnel.sh"
readonly ROOT_PREFIX="${HE_TUNNEL_ROOT:-}"

COLOR_RESET=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_CYAN=""
COLOR_DIM=""
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_CYAN=$'\033[36m'
    COLOR_DIM=$'\033[2m'
fi

ACTION=""
TUNNEL_NAME="he-ipv6"
NAME_EXPLICIT=0
HE_SERVER_IPV4=""
HE_SERVER_IPV6=""
HE_CLIENT_IPV6=""
LOCAL_IPV4=""
OUT_INTERFACE=""
MTU="1480"
TTL="255"
ROUTE_METRIC="1024"
BACKEND="auto"
TEST_TARGET="2606:4700:4700::1111"
DRY_RUN=0
ASSUME_YES=0
ALL_TUNNELS=0
NO_CURL=0
SKIP_TESTS=0
INTERACTIVE=0
SELF_DESTRUCT=0
RUN_STAMP=""
TOUCHED_SYSTEMD=0
TOUCHED_NETWORKD=0
TOUCHED_NETPLAN=0
TOUCHED_NETWORKMANAGER=0

declare -a DISCOVERED_NAMES=()
declare -a ARTIFACT_NAMES=()
declare -a ARTIFACT_KINDS=()
declare -a ARTIFACT_TARGETS=()
declare -a ARTIFACT_DETAILS=()
declare -a BACKED_UP_FILES=()

log() {
    printf '%b[信息]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
    printf '%b[警告]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

die() {
    printf '%b[错误]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    exit 1
}

section() {
    printf '\n%b%s%b\n' "$COLOR_CYAN" "$*" "$COLOR_RESET"
}

hint() {
    printf '  %b%s%b\n' "$COLOR_DIM" "$*" "$COLOR_RESET"
}

input_error() {
    printf '  %b输入无效：%s%b\n' "$COLOR_RED" "$*" "$COLOR_RESET" >&2
}

root_path() {
    printf '%s%s' "$ROOT_PREFIX" "$1"
}

usage() {
    cat <<EOF
HE/SIT IPv6 tunnel deployment and cleanup tool v${SCRIPT_VERSION}

Usage:
  sudo ./${SCRIPT_NAME} install --server-ipv4 IP --server-ipv6 IP --client-ipv6 CIDR [options]
  sudo ./${SCRIPT_NAME} discover
  sudo ./${SCRIPT_NAME} status [--name NAME | --all]
  sudo ./${SCRIPT_NAME} uninstall [--name NAME | --all] [--yes]
  sudo ./${SCRIPT_NAME} self-destruct [--yes]
  sudo ./${SCRIPT_NAME} menu

Actions:
  install                 Fresh deployment only; refuses to overwrite a tunnel
  discover                Find live and persistent HE/SIT tunnel installations
  status                  Show discovered configuration and live interface state
  uninstall, purge        Back up and completely remove selected tunnel installs
  self-destruct           Remove all tunnels, managed dirs, backups, and this script
  menu                    Open the interactive Chinese management menu

Install options:
  --name NAME             Interface name (default: he-ipv6)
  --server-ipv4 ADDRESS   HE Server IPv4 Address; required for install
  --server-ipv6 ADDRESS   HE Server IPv6 Address; required for install
  --client-ipv6 ADDR[/N]  HE Client IPv6 Address; omitted prefix defaults to /64
  --local-ipv4 ADDRESS    NIC IPv4 behind any EIP/NAT; auto-detected by default
  --out-interface NAME    IPv4 egress interface; auto-detected by default
  --mtu NUMBER            Tunnel MTU (default: 1480; range: 1280-1480)
  --ttl NUMBER            Outer IPv4 TTL (default: 255)
  --metric NUMBER         IPv6 default-route metric (default: 1024)
  --backend TYPE          auto, systemd, ifupdown, or none (default: auto)
  --test-target ADDRESS   Public IPv6 ping target
  --skip-tests            Skip gateway, MTU, and public IPv6 tests
  --no-curl               Skip public address lookup

Removal and common options:
  --all                    Select every discovered SIT tunnel
  --yes, -y                Confirm a non-interactive uninstall
  --dry-run                Show changes without applying them
  -h, --help              Show this help

Examples:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} discover
  sudo ./${SCRIPT_NAME} uninstall --name he-ipv6 --yes
  sudo ./${SCRIPT_NAME} uninstall --all --yes
  sudo ./${SCRIPT_NAME} self-destruct --yes

Notes:
  * HE uses IPv4 protocol 41, not TCP/UDP port 41.
  * Install never takes over an existing interface or configuration.
  * Uninstall discovers configurations not created by this script, backs up
    persistent files under /var/backups/he-tunnel.sh, and then removes them.
  * Cloud security groups and host firewall rules are not modified.
EOF
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少必需命令：$1"
}

need_discovery_commands() {
    need_command awk
    need_command basename
    need_command find
    need_command grep
    need_command head
    need_command sed
}

run() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

try_run() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@" || {
        warn "Command failed and cleanup will continue: $*"
        return 0
    }
}

confirm() {
    local prompt="$1" answer
    (( ASSUME_YES )) && return 0
    [[ -t 0 ]] || die "Confirmation required; rerun with --yes or use --dry-run"
    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

prompt_required() {
    local label="$1" answer=""
    while [[ -z "$answer" ]]; do
        read -r -p "${label}: " answer
    done
    printf '%s' "$answer"
}

prompt_value() {
    local label="$1" current="$2" answer
    read -r -p "${label} [${current}]: " answer
    printf '%s' "${answer:-$current}"
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_ipv6_literal() {
    local address="$1" part compact compressed=0 count=0
    local -a parts=()
    [[ -n "$address" && "$address" == *:* ]] || return 1
    [[ "$address" != *[!0-9A-Fa-f:]* && "$address" != *:::* ]] || return 1
    if [[ "$address" == *::* ]]; then
        compressed=1
        compact="${address/::/X}"
        [[ "$compact" != *::* ]] || return 1
    fi
    IFS=':' read -r -a parts <<<"$address"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( count += 1 ))
    done
    if (( compressed )); then
        (( count < 8 ))
    else
        (( count == 8 ))
    fi
}

normalize_client_ipv6() {
    local value prefix
    value="$(trim_value "$1")"
    if [[ "$value" == */* ]]; then
        prefix="${value##*/}"
    else
        prefix="64"
        value="${value}/64"
    fi
    is_uint "$prefix" && (( prefix >= 1 && prefix <= 128 )) || return 1
    is_ipv6_literal "${value%/*}" || return 1
    printf '%s' "$value"
}

normalize_server_ipv6() {
    local value
    value="$(trim_value "$1")"
    value="${value%/*}"
    is_ipv6_literal "$value" || return 1
    printf '%s' "$value"
}

derive_he_server_ipv6() {
    local client="${1%/*}"
    if [[ "$client" == *:2 ]]; then
        printf '%s1' "${client%2}"
    fi
}

prompt_ipv4_required() {
    local answer
    while true; do
        read -r -p "  HE Server IPv4 Address: " answer
        answer="$(trim_value "$answer")"
        if is_ipv4 "$answer"; then
            printf '%s' "$answer"
            return 0
        fi
        input_error "请输入 HE 页面中的 Server IPv4 Address，例如 216.218.221.6"
    done
}

prompt_client_ipv6() {
    local answer normalized
    while true; do
        read -r -p "  HE Client IPv6 Address: " answer
        answer="$(trim_value "$answer")"
        if normalized="$(normalize_client_ipv6 "$answer")"; then
            if [[ "$answer" != */* ]]; then
                printf '  %b已自动补全为 %s%b\n' "$COLOR_GREEN" "$normalized" "$COLOR_RESET" >&2
            fi
            printf '%s' "$normalized"
            return 0
        fi
        input_error "请粘贴 HE 页面中的 Client IPv6 Address；可以只填裸地址，脚本会自动补 /64"
    done
}

prompt_server_ipv6() {
    local client="$1" suggested="$2" answer normalized prompt
    while true; do
        if [[ -n "$suggested" ]]; then
            prompt="  HE Server IPv6 Address [$suggested]: "
        else
            prompt="  HE Server IPv6 Address: "
        fi
        read -r -p "$prompt" answer
        answer="$(trim_value "${answer:-$suggested}")"
        if ! normalized="$(normalize_server_ipv6 "$answer")"; then
            input_error "请输入 HE 页面中的 Server IPv6 Address，通常以 ::1 结尾"
            continue
        fi
        if [[ "$normalized" == "${client%/*}" ]]; then
            input_error "Server IPv6 与 Client IPv6 不能相同；HE 服务端通常是 ::1，本机通常是 ::2"
            continue
        fi
        printf '%s' "$normalized"
        return 0
    done
}

prompt_uint_range() {
    local label="$1" current="$2" minimum="$3" maximum="$4" answer
    while true; do
        answer="$(prompt_value "$label" "$current")"
        if is_uint "$answer" && (( answer >= minimum && answer <= maximum )); then
            printf '%s' "$answer"
            return 0
        fi
        input_error "$label 必须是 ${minimum}-${maximum} 之间的整数"
    done
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_ipv4() {
    local address="$1" octet
    local -a octets
    IFS='.' read -r -a octets <<<"$address"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
}

validate_name() {
    [[ "$TUNNEL_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "隧道名称包含无效字符：$TUNNEL_NAME"
    (( ${#TUNNEL_NAME} <= 15 )) || die "Linux 接口名称不能超过 15 个字符"
    [[ "$TUNNEL_NAME" != "sit0" ]] || die "sit0 是内核保留接口，不能作为隧道名称"
}

validate_install_arguments() {
    local normalized
    validate_name
    HE_SERVER_IPV4="$(trim_value "$HE_SERVER_IPV4")"
    [[ -n "$HE_SERVER_IPV4" ]] || die "全新部署必须提供 --server-ipv4"
    [[ -n "$HE_SERVER_IPV6" ]] || die "全新部署必须提供 --server-ipv6"
    [[ -n "$HE_CLIENT_IPV6" ]] || die "全新部署必须提供 --client-ipv6"
    is_ipv4 "$HE_SERVER_IPV4" || die "HE Server IPv4 Address 无效：$HE_SERVER_IPV4"
    if ! normalized="$(normalize_server_ipv6 "$HE_SERVER_IPV6")"; then
        die "HE Server IPv6 Address 无效：$HE_SERVER_IPV6"
    fi
    HE_SERVER_IPV6="$normalized"
    if ! normalized="$(normalize_client_ipv6 "$HE_CLIENT_IPV6")"; then
        die "HE Client IPv6 Address 无效：$HE_CLIENT_IPV6"
    fi
    if [[ "$HE_CLIENT_IPV6" != */* ]]; then
        log "Client IPv6 未包含前缀，已自动补全为 $normalized"
    fi
    HE_CLIENT_IPV6="$normalized"
    [[ "$HE_SERVER_IPV6" != "${HE_CLIENT_IPV6%/*}" ]] || \
        die "Server IPv6 与 Client IPv6 不能相同；HE 服务端通常是 ::1，本机通常是 ::2"
    if [[ -n "$LOCAL_IPV4" ]]; then
        is_ipv4 "$LOCAL_IPV4" || die "本地 IPv4 地址无效：$LOCAL_IPV4"
    fi
    if ! is_uint "$MTU" || (( MTU < 1280 || MTU > 1480 )); then
        die "MTU 必须是 1280-1480 之间的整数"
    fi
    if ! is_uint "$TTL" || (( TTL < 1 || TTL > 255 )); then
        die "TTL 必须是 1-255 之间的整数"
    fi
    if ! is_uint "$ROUTE_METRIC" || (( ROUTE_METRIC < 1 )); then
        die "路由 metric 必须是正整数"
    fi
    case "$BACKEND" in
        auto|systemd|ifupdown|none) ;;
        *) die "不支持的持久化方式：$BACKEND" ;;
    esac
}

parse_arguments() {
    if (( $# > 0 )); then
        case "$1" in
            menu|install|discover|status|check|uninstall|purge|self-destruct|destroy|nuke)
                ACTION="$1"
                shift
                ;;
        esac
    fi

    [[ "$ACTION" == "check" ]] && ACTION="status"
    [[ "$ACTION" == "purge" ]] && ACTION="uninstall"
    [[ "$ACTION" == "destroy" || "$ACTION" == "nuke" ]] && ACTION="self-destruct"

    while (( $# > 0 )); do
        case "$1" in
            --name)
                (( $# >= 2 )) || die "--name requires a value"
                TUNNEL_NAME="$2"
                NAME_EXPLICIT=1
                shift 2
                ;;
            --server-ipv4)
                (( $# >= 2 )) || die "--server-ipv4 requires a value"
                HE_SERVER_IPV4="$2"
                shift 2
                ;;
            --server-ipv6)
                (( $# >= 2 )) || die "--server-ipv6 requires a value"
                HE_SERVER_IPV6="$2"
                shift 2
                ;;
            --client-ipv6)
                (( $# >= 2 )) || die "--client-ipv6 requires a value"
                HE_CLIENT_IPV6="$2"
                shift 2
                ;;
            --local-ipv4)
                (( $# >= 2 )) || die "--local-ipv4 requires a value"
                LOCAL_IPV4="$2"
                shift 2
                ;;
            --out-interface)
                (( $# >= 2 )) || die "--out-interface requires a value"
                OUT_INTERFACE="$2"
                shift 2
                ;;
            --mtu)
                (( $# >= 2 )) || die "--mtu requires a value"
                MTU="$2"
                shift 2
                ;;
            --ttl)
                (( $# >= 2 )) || die "--ttl requires a value"
                TTL="$2"
                shift 2
                ;;
            --metric)
                (( $# >= 2 )) || die "--metric requires a value"
                ROUTE_METRIC="$2"
                shift 2
                ;;
            --backend)
                (( $# >= 2 )) || die "--backend requires a value"
                BACKEND="$2"
                shift 2
                ;;
            --test-target)
                (( $# >= 2 )) || die "--test-target requires a value"
                TEST_TARGET="$2"
                shift 2
                ;;
            --all) ALL_TUNNELS=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --skip-tests) SKIP_TESTS=1; shift ;;
            --no-curl) NO_CURL=1; shift ;;
            --menu) ACTION="menu"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

require_root() {
    if [[ -n "$ROOT_PREFIX" ]]; then
        [[ "$ROOT_PREFIX" == /* ]] || die "HE_TUNNEL_ROOT must be an absolute path"
        return
    fi
    (( EUID == 0 )) || die "此操作需要 root 权限，请使用：sudo ./${SCRIPT_NAME} $ACTION"
}

add_discovered_name() {
    local candidate="$1" existing
    [[ -n "$candidate" && "$candidate" != "sit0" ]] || return 0
    for existing in "${DISCOVERED_NAMES[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    DISCOVERED_NAMES+=("$candidate")
}

add_artifact() {
    local name="$1" kind="$2" target="$3" detail="${4:-}" i
    [[ -n "$name" && "$name" != "sit0" ]] || return 0
    for i in "${!ARTIFACT_NAMES[@]}"; do
        if [[ "${ARTIFACT_NAMES[$i]}" == "$name" &&
              "${ARTIFACT_KINDS[$i]}" == "$kind" &&
              "${ARTIFACT_TARGETS[$i]}" == "$target" ]]; then
            return 0
        fi
    done
    add_discovered_name "$name"
    ARTIFACT_NAMES+=("$name")
    ARTIFACT_KINDS+=("$kind")
    ARTIFACT_TARGETS+=("$target")
    ARTIFACT_DETAILS+=("$detail")
}

reset_discovery() {
    DISCOVERED_NAMES=()
    ARTIFACT_NAMES=()
    ARTIFACT_KINDS=()
    ARTIFACT_TARGETS=()
    ARTIFACT_DETAILS=()
}

netplan_tunnel_names() {
    local file="$1"
    awk '
        function indentation(line, copy) {
            copy = line
            sub(/[^ \t].*$/, "", copy)
            return length(copy)
        }
        function clean_key(line, key) {
            key = line
            sub(/^[ \t]*/, "", key)
            sub(/:[ \t]*(#.*)?$/, "", key)
            gsub(/^["\047]|["\047]$/, "", key)
            return key
        }
        BEGIN {
            in_tunnels = 0
            tunnels_indent = -1
            entry_indent = -1
            current = ""
        }
        {
            line = $0
            stripped = line
            sub(/^[ \t]*/, "", stripped)
            if (stripped == "" || stripped ~ /^#/) {
                next
            }
            indent = indentation(line)
            if (!in_tunnels && stripped ~ /^tunnels:[ \t]*(#.*)?$/) {
                in_tunnels = 1
                tunnels_indent = indent
                entry_indent = -1
                current = ""
                next
            }
            if (in_tunnels && indent <= tunnels_indent) {
                in_tunnels = 0
                current = ""
            }
            if (!in_tunnels) {
                next
            }
            if (stripped ~ /^[^:]+:[ \t]*(#.*)?$/) {
                if (entry_indent < 0) {
                    entry_indent = indent
                }
                if (indent == entry_indent) {
                    current = clean_key(line)
                    next
                }
            }
            if (current != "" && stripped ~ /^mode:[ \t]*(sit|6in4)([ \t]*#.*)?$/) {
                print current
            }
        }
    ' "$file"
}

discover_live_tunnels() {
    local name detail
    command -v ip >/dev/null 2>&1 || return 0
    while IFS= read -r name; do
        name="${name%%@*}"
        [[ -n "$name" && "$name" != "sit0" ]] || continue
        detail="$(ip tunnel show "$name" 2>/dev/null | head -n 1 || true)"
        add_artifact "$name" "live-interface" "$name" "$detail"
    done < <(ip -d -o link show type sit 2>/dev/null | awk -F': ' '{print $2}' || true)
}

discover_ifupdown() {
    local interfaces_file interfaces_dir file name
    local -a files=()
    interfaces_file="$(root_path /etc/network/interfaces)"
    interfaces_dir="$(root_path /etc/network/interfaces.d)"
    [[ -f "$interfaces_file" ]] && files+=("$interfaces_file")
    if [[ -d "$interfaces_dir" ]]; then
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$interfaces_dir" -maxdepth 1 -type f -print0 2>/dev/null || true)
    fi
    for file in "${files[@]}"; do
        while IFS= read -r name; do
            [[ -n "$name" ]] && add_artifact "$name" "ifupdown-stanza" "$file"
        done < <(
            awk '
                $1 == "iface" && ($3 == "inet6" || $3 == "inet") &&
                ($4 == "v4tunnel" || $4 == "sit") { print $2 }
            ' "$file"
        )
    done
}

discover_systemd_units() {
    local unit_dir file name
    unit_dir="$(root_path /etc/systemd/system)"
    [[ -d "$unit_dir" ]] || return 0
    while IFS= read -r -d '' file; do
        while IFS= read -r name; do
            [[ -n "$name" ]] && add_artifact "$name" "systemd-unit" "$file" "$(basename "$file")"
        done < <(
            sed -nE \
                -e 's@(^|.*[[:space:]/])ip[[:space:]]+tunnel[[:space:]]+add[[:space:]]+([^[:space:]]+)[[:space:]]+mode[[:space:]]+sit.*@\2@p' \
                -e 's@(^|.*[[:space:]/])ip[[:space:]]+link[[:space:]]+add[[:space:]]+([^[:space:]]+).*type[[:space:]]+sit.*@\2@p' \
                "$file"
        )
    done < <(find "$unit_dir" -type f -name '*.service' -print0 2>/dev/null || true)
}

networkd_netdev_name() {
    local file="$1"
    awk -F= '
        function trim(value) {
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            return value
        }
        /^\[NetDev\][ \t]*$/ { section = "netdev"; next }
        /^\[[^]]+\][ \t]*$/ { section = ""; next }
        section == "netdev" && trim($1) == "Name" { name = trim($2) }
        section == "netdev" && trim($1) == "Kind" { kind = tolower(trim($2)) }
        END { if (kind == "sit" && name != "") print name }
    ' "$file"
}

discover_networkd() {
    local network_dir file name candidate
    network_dir="$(root_path /etc/systemd/network)"
    [[ -d "$network_dir" ]] || return 0
    while IFS= read -r -d '' file; do
        name="$(networkd_netdev_name "$file")"
        [[ -n "$name" ]] && add_artifact "$name" "networkd-netdev" "$file"
    done < <(find "$network_dir" -maxdepth 1 -type f -name '*.netdev' -print0 2>/dev/null || true)

    for name in "${DISCOVERED_NAMES[@]}"; do
        while IFS= read -r -d '' candidate; do
            if awk -F= -v wanted="$name" '
                function trim(value) {
                    gsub(/^[ \t]+|[ \t]+$/, "", value)
                    return value
                }
                /^\[Match\][ \t]*$/ { section = "match"; next }
                /^\[[^]]+\][ \t]*$/ { section = ""; next }
                section == "match" && trim($1) == "Name" && trim($2) == wanted { found = 1 }
                END { exit(found ? 0 : 1) }
            ' "$candidate"; then
                add_artifact "$name" "networkd-network" "$candidate"
            fi
        done < <(find "$network_dir" -maxdepth 1 -type f -name '*.network' -print0 2>/dev/null || true)
    done
}

discover_netplan() {
    local netplan_dir file name
    netplan_dir="$(root_path /etc/netplan)"
    [[ -d "$netplan_dir" ]] || return 0
    while IFS= read -r -d '' file; do
        while IFS= read -r name; do
            [[ -n "$name" ]] && add_artifact "$name" "netplan-tunnel" "$file"
        done < <(netplan_tunnel_names "$file")
    done < <(find "$netplan_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null || true)
}

discover_network_scripts() {
    local scripts_dir file name type
    scripts_dir="$(root_path /etc/sysconfig/network-scripts)"
    [[ -d "$scripts_dir" ]] || return 0
    while IFS= read -r -d '' file; do
        type="$(awk -F= '
            $1 ~ /^[ \t]*(TYPE|DEVICETYPE)[ \t]*$/ {
                value = $2
                gsub(/["\047 \t]/, "", value)
                print tolower(value)
            }
        ' "$file" | head -n 1)"
        grep -Eqi '(^|[[:space:]])(IPV6TUNNELIPV4|IPV6TUNNELIPV4LOCAL|IPV6TUNNELIPV4REMOTE)=' "$file" || \
            [[ "$type" == "sit" ]] || continue
        name="$(awk -F= '
            $1 ~ /^[ \t]*DEVICE[ \t]*$/ {
                value = $2
                gsub(/["\047 \t]/, "", value)
                print value
                exit
            }
        ' "$file")"
        [[ -n "$name" ]] || name="${file##*/ifcfg-}"
        add_artifact "$name" "network-script" "$file"
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name 'ifcfg-*' -print0 2>/dev/null || true)
}

discover_networkmanager() {
    local uuid connection_type mode name interface_name
    [[ -z "$ROOT_PREFIX" ]] || return 0
    command -v nmcli >/dev/null 2>&1 || return 0
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        connection_type="$(nmcli -g connection.type connection show "$uuid" 2>/dev/null || true)"
        [[ "$connection_type" == "ip-tunnel" ]] || continue
        mode="$(nmcli -g ip-tunnel.mode connection show "$uuid" 2>/dev/null || true)"
        [[ "$mode" == "sit" || "$mode" == "3" ]] || continue
        name="$(nmcli -g connection.id connection show "$uuid" 2>/dev/null || true)"
        interface_name="$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null || true)"
        [[ -n "$interface_name" && "$interface_name" != "--" ]] || interface_name="$name"
        add_artifact "$interface_name" "networkmanager-connection" "$uuid" "$name"
    done < <(nmcli -g connection.uuid connection show 2>/dev/null || true)
}

discover_managed_metadata() {
    local config_dir file name
    config_dir="$(root_path /etc/he-tunnel)"
    [[ -d "$config_dir" ]] || return 0
    while IFS= read -r -d '' file; do
        name="${file##*/}"
        name="${name%.conf}"
        add_artifact "$name" "he-metadata" "$file"
    done < <(find "$config_dir" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null || true)
}

discover_startup_scripts() {
    local file name rc_local crontab cron_dir init_dir
    local -a files=()
    rc_local="$(root_path /etc/rc.local)"
    crontab="$(root_path /etc/crontab)"
    cron_dir="$(root_path /etc/cron.d)"
    init_dir="$(root_path /etc/init.d)"
    [[ -f "$rc_local" ]] && files+=("$rc_local")
    [[ -f "$crontab" ]] && files+=("$crontab")
    for file in "$cron_dir"/* "$init_dir"/*; do
        [[ -f "$file" ]] && files+=("$file")
    done
    for file in "${files[@]}"; do
        while IFS= read -r name; do
            [[ -n "$name" ]] && add_artifact "$name" "startup-script" "$file"
        done < <(
            sed -nE \
                -e 's@(^|.*[[:space:]/])ip[[:space:]]+tunnel[[:space:]]+add[[:space:]]+([^[:space:]]+)[[:space:]]+mode[[:space:]]+sit.*@\2@p' \
                -e 's@(^|.*[[:space:]/])ip[[:space:]]+link[[:space:]]+add[[:space:]]+([^[:space:]]+).*type[[:space:]]+sit.*@\2@p' \
                "$file"
        )
    done
}

discover_all() {
    need_discovery_commands
    reset_discovery
    discover_live_tunnels
    discover_ifupdown
    discover_systemd_units
    discover_networkd
    discover_netplan
    discover_network_scripts
    discover_networkmanager
    discover_managed_metadata
    discover_startup_scripts
}

kind_label() {
    case "$1" in
        live-interface) printf '实时 SIT 接口' ;;
        ifupdown-stanza) printf 'ifupdown 配置' ;;
        systemd-unit) printf 'systemd 服务' ;;
        networkd-netdev) printf 'networkd netdev' ;;
        networkd-network) printf 'networkd network' ;;
        netplan-tunnel) printf 'Netplan 隧道' ;;
        network-script) printf '传统 network-scripts' ;;
        networkmanager-connection) printf 'NetworkManager 连接' ;;
        he-metadata) printf '脚本元数据' ;;
        startup-script) printf '启动脚本' ;;
        *) printf '%s' "$1" ;;
    esac
}

name_is_selected() {
    local name="$1"
    (( ALL_TUNNELS )) || [[ "$name" == "$TUNNEL_NAME" ]]
}

artifact_target_has_unselected_name() {
    local target="$1" i
    for i in "${!ARTIFACT_NAMES[@]}"; do
        [[ "${ARTIFACT_TARGETS[$i]}" == "$target" ]] || continue
        if ! name_is_selected "${ARTIFACT_NAMES[$i]}"; then
            return 0
        fi
    done
    return 1
}

display_discovery() {
    local selected_only="${1:-0}" i found=0 label detail
    if (( ${#ARTIFACT_NAMES[@]} == 0 )); then
        log "未发现 HE/SIT 隧道接口或持久化配置"
        return 0
    fi
    printf '\n%-16s %-24s %s\n' "隧道名称" "来源" "目标/详情"
    printf '%-16s %-24s %s\n' "----------------" "------------------------" "------------------------------"
    for i in "${!ARTIFACT_NAMES[@]}"; do
        if (( selected_only )) && ! name_is_selected "${ARTIFACT_NAMES[$i]}"; then
            continue
        fi
        found=1
        label="$(kind_label "${ARTIFACT_KINDS[$i]}")"
        detail="${ARTIFACT_TARGETS[$i]}"
        [[ -n "${ARTIFACT_DETAILS[$i]}" ]] && detail+=" (${ARTIFACT_DETAILS[$i]})"
        printf '%-16s %-24s %s\n' "${ARTIFACT_NAMES[$i]}" "$label" "$detail"
    done
    (( found )) || log "所选范围内未发现隧道"
    printf '\n'
}

artifact_exists_for_name() {
    local wanted="$1" item
    for item in "${ARTIFACT_NAMES[@]}"; do
        [[ "$item" == "$wanted" ]] && return 0
    done
    return 1
}

detect_local_path() {
    local route_info detected_interface detected_source
    route_info="$(ip -4 route get "$HE_SERVER_IPV4" 2>/dev/null | head -n 1)" || true
    [[ -n "$route_info" ]] || die "无法找到通往 HE 服务端 $HE_SERVER_IPV4 的 IPv4 路由"
    detected_interface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<<"$route_info")"
    detected_source="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<<"$route_info")"

    [[ -n "$OUT_INTERFACE" ]] || OUT_INTERFACE="$detected_interface"
    [[ -n "$OUT_INTERFACE" ]] || die "无法自动识别 IPv4 出口网卡"
    ip link show dev "$OUT_INTERFACE" >/dev/null 2>&1 || die "网卡不存在：$OUT_INTERFACE"

    if [[ -z "$LOCAL_IPV4" ]]; then
        if [[ "$OUT_INTERFACE" == "$detected_interface" && -n "$detected_source" ]]; then
            LOCAL_IPV4="$detected_source"
        else
            LOCAL_IPV4="$(ip -4 -o address show dev "$OUT_INTERFACE" scope global |
                awk 'NR == 1 {split($4, address, "/"); print address[1]}')"
        fi
    fi
    [[ -n "$LOCAL_IPV4" ]] || die "无法从网卡 $OUT_INTERFACE 自动识别本地 IPv4"
    if ! ip -4 -o address show dev "$OUT_INTERFACE" | grep -Fq " $LOCAL_IPV4/"; then
        die "$LOCAL_IPV4 不属于网卡 $OUT_INTERFACE；使用 EIP/NAT 时应填写网卡私网地址，而不是公网 EIP"
    fi
    log "已识别 IPv4 出口：$LOCAL_IPV4（网卡 $OUT_INTERFACE）-> $HE_SERVER_IPV4"
}

detect_backend() {
    [[ "$BACKEND" == "auto" ]] || return 0
    if command -v systemctl >/dev/null 2>&1 && [[ -d "$(root_path /run/systemd/system)" ]]; then
        BACKEND="systemd"
    elif command -v ifup >/dev/null 2>&1 &&
         command -v ifdown >/dev/null 2>&1 &&
         [[ -f "$(root_path /etc/network/interfaces)" ]] &&
         grep -Eq '^[[:space:]]*(source|source-directory)[[:space:]]+/etc/network/interfaces\.d' \
             "$(root_path /etc/network/interfaces)"; then
        BACKEND="ifupdown"
    else
        BACKEND="none"
    fi
    log "已选择持久化方式：$BACKEND"
}

preflight_install() {
    need_command ip
    need_command awk
    need_command grep
    need_command ping
    need_command install
    need_command mktemp
    need_command mv
    need_command rm
    need_discovery_commands
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf '0')" == "1" ]]; then
        die "系统已通过 net.ipv6.conf.all.disable_ipv6 禁用 IPv6"
    fi
    detect_local_path
    detect_backend
    case "$BACKEND" in
        systemd) need_command systemctl ;;
        ifupdown)
            need_command ifup
            need_command ifdown
            need_command ifquery
            ;;
    esac
}

is_sit_interface_name() {
    local name="$1"
    ip -d link show dev "$name" 2>/dev/null | grep -Eq 'link/sit|sit ip6ip'
}

interface_has_ipv6_address() {
    local name="$1" address="$2"
    local host="${address%/*}"
    ip -o -6 address show dev "$name" to "${host}/128" 2>/dev/null | grep -q .
}

show_tunnel_diagnostics() {
    local name="$1"
    warn "当前 $name 接口状态："
    ip -d link show dev "$name" >&2 2>/dev/null || true
    ip -6 address show dev "$name" >&2 2>/dev/null || true
    ip -6 route show dev "$name" >&2 2>/dev/null || true
}

delete_live_interface() {
    local name="$1"
    ip link show dev "$name" >/dev/null 2>&1 || return 0
    if ! is_sit_interface_name "$name"; then
        warn "Keeping $name because the live interface is not SIT"
        return 0
    fi
    try_run ip link set dev "$name" down
    try_run ip link delete dev "$name"
}

create_live_tunnel() {
    if command -v modprobe >/dev/null 2>&1; then
        run modprobe sit || return 1
    fi
    run ip tunnel add "$TUNNEL_NAME" mode sit remote "$HE_SERVER_IPV4" local "$LOCAL_IPV4" ttl "$TTL" || return 1
    run ip link set dev "$TUNNEL_NAME" mtu "$MTU" up || return 1
    run ip -6 address add "$HE_CLIENT_IPV6" dev "$TUNNEL_NAME" || return 1
    run ip -6 route replace default via "$HE_SERVER_IPV6" dev "$TUNNEL_NAME" \
        metric "$ROUTE_METRIC" onlink || return 1
}

show_public_addresses() {
    local public_v4 public_v6
    (( NO_CURL )) && return 0
    command -v curl >/dev/null 2>&1 || {
        warn "未安装 curl，跳过公网地址查询"
        return 0
    }
    public_v4="$(curl -4 --connect-timeout 5 --max-time 12 -fsS https://api.ipify.org 2>/dev/null || true)"
    public_v6="$(curl -6 --connect-timeout 5 --max-time 12 -fsS https://api64.ipify.org 2>/dev/null || true)"
    [[ -n "$public_v4" ]] && log "公网 IPv4：$public_v4"
    if [[ -n "$public_v6" ]]; then
        log "公网 IPv6：$public_v6"
    else
        warn "公网 IPv6 查询失败"
    fi
}

run_tunnel_tests() {
    local payload_size=$((MTU - 48))
    (( SKIP_TESTS )) && {
        warn "已按要求跳过连通性测试"
        return 0
    }
    if (( DRY_RUN )); then
        log "预演模式：跳过实际连通性测试"
        return 0
    fi
    is_sit_interface_name "$TUNNEL_NAME" || {
        warn "$TUNNEL_NAME 不是正在运行的 SIT 隧道"
        show_tunnel_diagnostics "$TUNNEL_NAME"
        return 1
    }
    interface_has_ipv6_address "$TUNNEL_NAME" "$HE_CLIENT_IPV6" || {
        warn "隧道 $TUNNEL_NAME 上未找到 Client IPv6：$HE_CLIENT_IPV6"
        show_tunnel_diagnostics "$TUNNEL_NAME"
        return 1
    }
    log "测试 HE IPv6 网关：$HE_SERVER_IPV6"
    if ! ping -6 -c 3 -W 2 "$HE_SERVER_IPV6"; then
        warn "HE IPv6 网关无响应"
        warn "请确认云安全组和主机防火墙双向放行 IPv4 Protocol 41；它不是 TCP/UDP 41 端口"
        warn "抓包诊断：tcpdump -ni $OUT_INTERFACE 'ip proto 41 and host $HE_SERVER_IPV4'"
        return 1
    fi
    log "测试 MTU $MTU（IPv6 ICMP 负载 $payload_size 字节）"
    ping -6 -M 'do' -c 2 -W 2 -s "$payload_size" "$HE_SERVER_IPV6" ||
        warn "MTU 测试失败，可以尝试降低 --mtu"
    log "测试公网 IPv6 连通性：$TEST_TARGET"
    ping -6 -c 3 -W 2 "$TEST_TARGET" ||
        warn "HE 网关可达，但公网 IPv6 Ping 失败"
    show_public_addresses
}

write_metadata() {
    local dir target temp
    dir="$(root_path /etc/he-tunnel)"
    target="$dir/$TUNNEL_NAME.conf"
    if (( DRY_RUN )); then
        log "Would write metadata to $target"
        return 0
    fi
    install -d -o root -g root -m 0755 "$dir" || return 1
    temp="$(mktemp)" || return 1
    if ! cat >"$temp" <<EOF
# $MARKER
NAME=$TUNNEL_NAME
SERVER_IPV4=$HE_SERVER_IPV4
SERVER_IPV6=$HE_SERVER_IPV6
CLIENT_IPV6=$HE_CLIENT_IPV6
LOCAL_IPV4=$LOCAL_IPV4
OUT_INTERFACE=$OUT_INTERFACE
MTU=$MTU
TTL=$TTL
ROUTE_METRIC=$ROUTE_METRIC
BACKEND=$BACKEND
EOF
    then
        rm -f "$temp"
        return 1
    fi
    if ! install -o root -g root -m 0600 "$temp" "$target"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp" || return 1
}

write_systemd_unit() {
    local unit_dir target temp ip_path modprobe_path=""
    unit_dir="$(root_path /etc/systemd/system)"
    target="$unit_dir/he-tunnel-$TUNNEL_NAME.service"
    ip_path="$(command -v ip)"
    command -v modprobe >/dev/null 2>&1 && modprobe_path="$(command -v modprobe)"
    if (( DRY_RUN )); then
        log "Would write systemd service to $target"
        return 0
    fi
    install -d -o root -g root -m 0755 "$unit_dir" || return 1
    temp="$(mktemp)" || return 1
    if ! {
        printf '# %s\n' "$MARKER"
        cat <<EOF
[Unit]
Description=HE IPv6 tunnel $TUNNEL_NAME
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EOF
        [[ -n "$modprobe_path" ]] && printf 'ExecStartPre=%s sit\n' "$modprobe_path"
        cat <<EOF
ExecStartPre=-$ip_path link delete dev $TUNNEL_NAME
ExecStart=$ip_path tunnel add $TUNNEL_NAME mode sit remote $HE_SERVER_IPV4 local $LOCAL_IPV4 ttl $TTL
ExecStart=$ip_path link set dev $TUNNEL_NAME mtu $MTU up
ExecStart=$ip_path -6 address add $HE_CLIENT_IPV6 dev $TUNNEL_NAME
ExecStart=$ip_path -6 route replace default via $HE_SERVER_IPV6 dev $TUNNEL_NAME metric $ROUTE_METRIC onlink
ExecStop=-$ip_path link delete dev $TUNNEL_NAME

[Install]
WantedBy=multi-user.target
EOF
    } >"$temp"; then
        rm -f "$temp"
        return 1
    fi
    if ! install -o root -g root -m 0644 "$temp" "$target"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp" || return 1
}

write_ifupdown_config() {
    local dir target temp
    dir="$(root_path /etc/network/interfaces.d)"
    target="$dir/he-tunnel-$TUNNEL_NAME"
    if (( DRY_RUN )); then
        log "Would write ifupdown configuration to $target"
        return 0
    fi
    install -d -o root -g root -m 0755 "$dir" || return 1
    temp="$(mktemp)" || return 1
    if ! cat >"$temp" <<EOF
# $MARKER
auto $TUNNEL_NAME
iface $TUNNEL_NAME inet6 v4tunnel
    address ${HE_CLIENT_IPV6%/*}
    netmask ${HE_CLIENT_IPV6#*/}
    endpoint $HE_SERVER_IPV4
    local $LOCAL_IPV4
    ttl $TTL
    mtu $MTU
    up ip -6 route replace default via $HE_SERVER_IPV6 dev $TUNNEL_NAME metric $ROUTE_METRIC onlink
    down ip -6 route del default via $HE_SERVER_IPV6 dev $TUNNEL_NAME metric $ROUTE_METRIC || true
EOF
    then
        rm -f "$temp"
        return 1
    fi
    if ! install -o root -g root -m 0644 "$temp" "$target"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp" || return 1
    ifquery "$TUNNEL_NAME" >/dev/null || return 1
}

remove_fresh_managed_files() {
    local metadata systemd_unit ifupdown_file
    metadata="$(root_path /etc/he-tunnel)/$TUNNEL_NAME.conf"
    systemd_unit="$(root_path /etc/systemd/system)/he-tunnel-$TUNNEL_NAME.service"
    ifupdown_file="$(root_path /etc/network/interfaces.d)/he-tunnel-$TUNNEL_NAME"
    if command -v systemctl >/dev/null 2>&1; then
        try_run systemctl disable --now "he-tunnel-$TUNNEL_NAME.service"
    fi
    if command -v ifquery >/dev/null 2>&1 &&
       ifquery --state "$TUNNEL_NAME" >/dev/null 2>&1; then
        try_run ifdown "$TUNNEL_NAME"
    fi
    delete_live_interface "$TUNNEL_NAME"
    try_run rm -f -- "$metadata" "$systemd_unit" "$ifupdown_file"
    if command -v systemctl >/dev/null 2>&1; then
        try_run systemctl daemon-reload
    fi
}

persist_fresh_tunnel() {
    case "$BACKEND" in
        systemd)
            write_metadata || return 1
            write_systemd_unit || return 1
            delete_live_interface "$TUNNEL_NAME"
            if ! run systemctl daemon-reload ||
               ! run systemctl enable --now "he-tunnel-$TUNNEL_NAME.service"; then
                remove_fresh_managed_files
                return 1
            fi
            ;;
        ifupdown)
            write_metadata || return 1
            write_ifupdown_config || return 1
            delete_live_interface "$TUNNEL_NAME"
            if ! run ifup "$TUNNEL_NAME"; then
                remove_fresh_managed_files
                return 1
            fi
            ;;
        none)
            warn "Persistence is disabled; the tunnel will disappear after reboot"
            ;;
    esac
}

install_fresh_tunnel() {
    section "[1/4] 检查现有隧道和配置冲突"
    discover_all
    if artifact_exists_for_name "$TUNNEL_NAME" || ip link show dev "$TUNNEL_NAME" >/dev/null 2>&1; then
        display_discovery
        die "检测到同名隧道 $TUNNEL_NAME；全新部署不会覆盖旧配置，请先执行彻底卸载"
    fi
    log "未发现同名接口或持久化配置，可以全新部署"

    section "[2/4] 建立临时隧道并验证参数"
    if ! create_live_tunnel; then
        delete_live_interface "$TUNNEL_NAME"
        die "临时隧道创建失败，系统未写入持久化配置"
    fi
    if ! run_tunnel_tests; then
        delete_live_interface "$TUNNEL_NAME"
        die "临时隧道验证失败，已回滚，系统未写入持久化配置"
    fi

    section "[3/4] 写入持久化配置并启动"
    if ! persist_fresh_tunnel; then
        delete_live_interface "$TUNNEL_NAME"
        die "持久化启动失败，生成的配置已自动清理"
    fi

    section "[4/4] 最终连通性复核"
    if [[ "$BACKEND" != "none" ]] && ! run_tunnel_tests; then
        remove_fresh_managed_files
        die "持久化后的连通性复核失败，生成的配置已回滚"
    fi
    if (( DRY_RUN )); then
        log "预演完成，没有修改系统"
    else
        log "HE IPv6 隧道全新部署完成"
        warn "该 IPv6 可被公网直接路由，请检查 IPv6 监听端口和防火墙策略"
        command -v ss >/dev/null 2>&1 && ss -H -lnt6 2>/dev/null || true
    fi
}

backup_file() {
    local file="$1" backup_dir relative safe_name destination existing
    [[ -e "$file" || -L "$file" ]] || return 0
    for existing in "${BACKED_UP_FILES[@]}"; do
        [[ "$existing" == "$file" ]] && return 0
    done
    BACKED_UP_FILES+=("$file")
    backup_dir="$(root_path /var/backups/he-tunnel.sh)/$RUN_STAMP"
    relative="${file#"$ROOT_PREFIX"}"
    safe_name="${relative#/}"
    safe_name="${safe_name//\//__}"
    destination="$backup_dir/$safe_name"
    if (( DRY_RUN )); then
        log "Would back up $file to $destination"
        return 0
    fi
    install -d -o root -g root -m 0700 "$backup_dir"
    cp -a -- "$file" "$destination"
    log "Backed up $file to $destination"
}

replace_preserving_metadata() {
    local original="$1" replacement="$2"
    chmod --reference="$original" "$replacement" 2>/dev/null || true
    chown --reference="$original" "$replacement" 2>/dev/null || true
    mv -f -- "$replacement" "$original"
}

remove_ifupdown_stanza() {
    local file="$1" name="$2" temp active_pattern
    [[ -f "$file" ]] || return 0
    backup_file "$file"
    if (( DRY_RUN )); then
        log "Would remove ifupdown stanza $name from $file"
        return 0
    fi
    temp="$(mktemp)"
    awk -v wanted="$name" '
        function directive(line) {
            return line ~ /^(auto|allow-auto|allow-hotplug|iface|mapping|source|source-directory)[ \t]+/
        }
        {
            line = $0
            plain = line
            sub(/^[ \t]*/, "", plain)
            if (skip) {
                if (plain != "" && plain !~ /^#/ && directive(plain)) {
                    skip = 0
                } else {
                    next
                }
            }
            if (plain ~ /^iface[ \t]+/) {
                count = split(plain, fields, /[ \t]+/)
                if (count >= 4 && fields[2] == wanted &&
                    (fields[4] == "v4tunnel" || fields[4] == "sit")) {
                    skip = 1
                    next
                }
            }
            if (plain ~ /^(auto|allow-auto|allow-hotplug)[ \t]+/) {
                count = split(plain, fields, /[ \t]+/)
                output = fields[1]
                kept = 0
                for (i = 2; i <= count; i++) {
                    if (fields[i] != wanted && fields[i] != "") {
                        output = output " " fields[i]
                        kept = 1
                    }
                }
                if (kept) print output
                next
            }
            print line
        }
    ' "$file" >"$temp"
    active_pattern='^[[:space:]]*[^#[:space:]]'
    if [[ "$file" != "$(root_path /etc/network/interfaces)" ]] &&
       ! grep -Eq "$active_pattern" "$temp"; then
        rm -f -- "$file" "$temp"
        log "Removed empty ifupdown fragment $file"
    else
        replace_preserving_metadata "$file" "$temp"
        log "Removed ifupdown stanza $name from $file"
    fi
}

remove_netplan_tunnel() {
    local file="$1" name="$2" temp count
    [[ -f "$file" ]] || return 0
    count="$(netplan_tunnel_names "$file" | awk 'NF {count++} END {print count+0}')"
    backup_file "$file"
    if (( DRY_RUN )); then
        log "Would remove Netplan tunnel $name from $file"
        return 0
    fi
    temp="$(mktemp)"
    awk -v wanted="$name" -v only="$((count == 1 ? 1 : 0))" '
        function indentation(line, copy) {
            copy = line
            sub(/[^ \t].*$/, "", copy)
            return length(copy)
        }
        {
            line = $0
            stripped = line
            sub(/^[ \t]*/, "", stripped)
            indent = indentation(line)
            if (skip) {
                if (stripped != "" && stripped !~ /^#/ && indent <= target_indent) {
                    skip = 0
                } else {
                    next
                }
            }
            if (!in_tunnels && stripped ~ /^tunnels:[ \t]*(#.*)?$/) {
                in_tunnels = 1
                tunnels_indent = indent
                if (only) {
                    prefix = line
                    sub(/tunnels:.*/, "tunnels: {}", prefix)
                    print prefix
                } else {
                    print line
                }
                next
            }
            if (in_tunnels && stripped != "" && stripped !~ /^#/ && indent <= tunnels_indent) {
                in_tunnels = 0
            }
            if (in_tunnels) {
                key = stripped
                sub(/:[ \t]*(#.*)?$/, "", key)
                gsub(/^["\047]|["\047]$/, "", key)
                if (key == wanted) {
                    skip = 1
                    target_indent = indent
                    next
                }
            }
            print line
        }
    ' "$file" >"$temp"
    replace_preserving_metadata "$file" "$temp"
    log "Removed Netplan tunnel $name from $file"
}

remove_startup_commands() {
    local file="$1" name="$2" temp
    [[ -f "$file" ]] || return 0
    backup_file "$file"
    if (( DRY_RUN )); then
        log "Would remove startup commands for $name from $file"
        return 0
    fi
    temp="$(mktemp)"
    awk -v wanted="$name" '
        function has_name_token(line, value, offset, position, before, after, rest) {
            offset = 1
            rest = line
            while ((position = index(rest, value)) > 0) {
                before = position == 1 ? "" : substr(rest, position - 1, 1)
                after = substr(rest, position + length(value), 1)
                if (before !~ /[A-Za-z0-9_.-]/ && after !~ /[A-Za-z0-9_.-]/) {
                    return 1
                }
                offset += position
                rest = substr(line, offset)
            }
            return 0
        }
        has_name_token($0, wanted) &&
        $0 ~ /(^|[ \t\/])ip[ \t]+(tunnel|link|-6[ \t]+(address|addr|route))/ { next }
        { print }
    ' "$file" >"$temp"
    replace_preserving_metadata "$file" "$temp"
    log "Removed startup commands for $name from $file"
}

remove_plain_file() {
    local file="$1"
    [[ -e "$file" || -L "$file" ]] || return 0
    backup_file "$file"
    run rm -f -- "$file"
    log "Removed $file"
}

resolve_script_path() {
    local source="${BASH_SOURCE[0]}" dir base
    if [[ "$source" == */* ]]; then
        dir="${source%/*}"
        base="${source##*/}"
    else
        dir="."
        base="$source"
    fi
    if [[ "$dir" != /* ]]; then
        dir="$(cd "$dir" && pwd -P)" || return 1
    fi
    printf '%s/%s' "$dir" "$base"
}

remove_exact_tree() {
    local target="$1"
    [[ -e "$target" || -L "$target" ]] || return 0
    [[ "$target" == /* && "$target" != "/" ]] || die "拒绝删除异常路径：$target"
    if (( DRY_RUN )); then
        log "Would remove $target"
        return 0
    fi
    rm -rf -- "$target"
    log "Removed $target"
}

remove_self_script() {
    local script_path
    script_path="$(resolve_script_path)" || die "无法解析当前脚本路径"
    [[ -f "$script_path" || -L "$script_path" ]] || {
        warn "未找到当前脚本文件：$script_path"
        return 0
    }
    if (( DRY_RUN )); then
        log "Would remove script $script_path"
        return 0
    fi
    rm -f -- "$script_path"
    log "Removed script $script_path"
}

choose_uninstall_scope() {
    local answer
    if (( ALL_TUNNELS )) || (( NAME_EXPLICIT )); then
        return 0
    fi
    if (( INTERACTIVE )); then
        read -r -p "输入要卸载的隧道名称，或输入 all 全部卸载: " answer
        [[ -n "$answer" ]] || die "未选择隧道"
        if [[ "$answer" == "all" || "$answer" == "ALL" ]]; then
            ALL_TUNNELS=1
        else
            TUNNEL_NAME="$answer"
            NAME_EXPLICIT=1
            validate_name
        fi
        return 0
    fi
    if (( ${#DISCOVERED_NAMES[@]} == 1 )); then
        TUNNEL_NAME="${DISCOVERED_NAMES[0]}"
        NAME_EXPLICIT=1
        log "Only one tunnel was found; selected $TUNNEL_NAME"
        return 0
    fi
    die "Multiple or no tunnels were found; specify --name NAME or --all"
}

stop_selected_services() {
    local i name kind target detail
    for i in "${!ARTIFACT_NAMES[@]}"; do
        name="${ARTIFACT_NAMES[$i]}"
        name_is_selected "$name" || continue
        kind="${ARTIFACT_KINDS[$i]}"
        target="${ARTIFACT_TARGETS[$i]}"
        detail="${ARTIFACT_DETAILS[$i]}"
        case "$kind" in
            systemd-unit)
                TOUCHED_SYSTEMD=1
                if artifact_target_has_unselected_name "$target"; then
                    warn "Keeping shared systemd service active while removing only $name: $target"
                elif command -v systemctl >/dev/null 2>&1; then
                    try_run systemctl disable --now "${detail:-$(basename "$target")}"
                fi
                ;;
            networkmanager-connection)
                TOUCHED_NETWORKMANAGER=1
                if command -v nmcli >/dev/null 2>&1; then
                    try_run nmcli connection down uuid "$target"
                    try_run nmcli connection delete uuid "$target"
                fi
                ;;
            networkd-netdev)
                TOUCHED_NETWORKD=1
                command -v networkctl >/dev/null 2>&1 &&
                    try_run networkctl down "$name"
                ;;
        esac
    done

    for name in "${DISCOVERED_NAMES[@]}"; do
        name_is_selected "$name" || continue
        if command -v ifquery >/dev/null 2>&1 &&
           ifquery --state "$name" >/dev/null 2>&1; then
            try_run ifdown "$name"
        fi
    done
}

remove_selected_artifacts() {
    local i name kind target
    for i in "${!ARTIFACT_NAMES[@]}"; do
        name="${ARTIFACT_NAMES[$i]}"
        name_is_selected "$name" || continue
        kind="${ARTIFACT_KINDS[$i]}"
        target="${ARTIFACT_TARGETS[$i]}"
        case "$kind" in
            live-interface|networkmanager-connection)
                ;;
            ifupdown-stanza)
                remove_ifupdown_stanza "$target" "$name"
                ;;
            netplan-tunnel)
                remove_netplan_tunnel "$target" "$name"
                TOUCHED_NETPLAN=1
                ;;
            startup-script)
                remove_startup_commands "$target" "$name"
                ;;
            systemd-unit|networkd-netdev|networkd-network|network-script|he-metadata)
                if [[ "$kind" == "systemd-unit" ]] && artifact_target_has_unselected_name "$target"; then
                    remove_startup_commands "$target" "$name"
                else
                    remove_plain_file "$target"
                fi
                [[ "$kind" == "systemd-unit" ]] && TOUCHED_SYSTEMD=1
                [[ "$kind" == networkd-* ]] && TOUCHED_NETWORKD=1
                [[ "$kind" == "network-script" ]] && TOUCHED_NETWORKMANAGER=1
                ;;
        esac
    done
}

reload_network_managers() {
    if (( TOUCHED_SYSTEMD )) && command -v systemctl >/dev/null 2>&1; then
        try_run systemctl daemon-reload
    fi
    if (( TOUCHED_NETWORKD )) && command -v networkctl >/dev/null 2>&1; then
        try_run networkctl reload
    fi
    if (( TOUCHED_NETWORKMANAGER )) && command -v nmcli >/dev/null 2>&1; then
        try_run nmcli connection reload
    fi
    if (( TOUCHED_NETPLAN )) && command -v netplan >/dev/null 2>&1; then
        try_run netplan generate
        try_run netplan apply
    fi
}

uninstall_discovered_tunnels() {
    local name remaining=0
    need_command ip
    need_command awk
    need_command grep
    need_command find
    need_command cp
    need_command install
    need_command mktemp
    need_command mv
    need_command rm
    need_command date
    need_discovery_commands

    discover_all
    (( ${#ARTIFACT_NAMES[@]} > 0 )) || {
        log "没有发现可卸载的 HE/SIT 隧道"
        return 0
    }
    choose_uninstall_scope
    display_discovery 1
    if ! artifact_exists_for_name "$TUNNEL_NAME" && (( ! ALL_TUNNELS )); then
        die "No discovered tunnel matches $TUNNEL_NAME"
    fi
    if (( ! DRY_RUN )); then
        confirm "将备份并彻底删除以上隧道接口和持久化配置，是否继续" || {
            log "已取消"
            return 0
        }
    fi

    RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    stop_selected_services
    for name in "${DISCOVERED_NAMES[@]}"; do
        name_is_selected "$name" || continue
        delete_live_interface "$name"
    done
    remove_selected_artifacts
    reload_network_managers

    if (( DRY_RUN )); then
        log "卸载预演完成；没有修改系统"
        return 0
    fi

    discover_all
    for name in "${DISCOVERED_NAMES[@]}"; do
        if (( ALL_TUNNELS )) || [[ "$name" == "$TUNNEL_NAME" ]]; then
            remaining=1
        fi
    done
    if (( remaining )); then
        warn "卸载后仍检测到以下关联项，请检查："
        display_discovery 1
        return 1
    fi
    log "所选 HE/SIT 隧道已彻底卸载"
    if (( SELF_DESTRUCT )); then
        log "自毁模式将继续删除工具备份目录"
    else
        log "配置备份保存在 $(root_path /var/backups/he-tunnel.sh)/$RUN_STAMP"
    fi
}

self_destruct_everything() {
    local saved_assume_yes
    need_command ip
    need_command awk
    need_command grep
    need_command find
    need_command cp
    need_command install
    need_command mktemp
    need_command mv
    need_command rm
    need_command date
    need_discovery_commands

    SELF_DESTRUCT=1
    ALL_TUNNELS=1
    section "自毁卸载"
    discover_all
    if (( ${#ARTIFACT_NAMES[@]} > 0 )); then
        display_discovery 1
    else
        log "没有发现 HE/SIT 隧道或持久化配置"
    fi
    if (( ! DRY_RUN )); then
        confirm "将删除全部 HE/SIT 隧道、持久化配置、备份目录和脚本文件本身，是否继续" || {
            log "已取消"
            return 0
        }
    fi

    saved_assume_yes="$ASSUME_YES"
    ASSUME_YES=1
    uninstall_discovered_tunnels
    ASSUME_YES="$saved_assume_yes"
    remove_exact_tree "$(root_path /etc/he-tunnel)"
    remove_exact_tree "$(root_path /var/backups/he-tunnel.sh)"
    remove_self_script
    if (( DRY_RUN )); then
        log "自毁卸载预演完成；没有修改系统"
    else
        log "自毁卸载完成"
    fi
}

show_status() {
    local name
    need_command ip
    discover_all
    if (( NAME_EXPLICIT || ALL_TUNNELS )); then
        display_discovery 1
    else
        display_discovery
    fi
    for name in "${DISCOVERED_NAMES[@]}"; do
        if (( NAME_EXPLICIT || ALL_TUNNELS )) && ! name_is_selected "$name"; then
            continue
        fi
        if ip link show dev "$name" >/dev/null 2>&1; then
            printf '\n[%s]\n' "$name"
            ip -d link show dev "$name"
            ip -6 address show dev "$name"
            ip -6 route show dev "$name"
        fi
    done
}

prompt_backend_choice() {
    local value
    cat <<'EOF'

持久化方式：
  1) 自动识别（推荐）
  2) systemd
  3) ifupdown
  4) 不持久化
EOF
    while true; do
        read -r -p "请选择 [1]: " value
        case "${value:-1}" in
            1) BACKEND="auto"; return ;;
            2) BACKEND="systemd"; return ;;
            3) BACKEND="ifupdown"; return ;;
            4) BACKEND="none"; return ;;
            *) input_error "请选择 1、2、3 或 4" ;;
        esac
    done
}

prompt_advanced_settings() {
    local value
    section "高级设置"

    while true; do
        value="$(prompt_value "隧道接口名称" "$TUNNEL_NAME")"
        if [[ "$value" =~ ^[a-zA-Z0-9_.-]+$ ]] &&
           (( ${#value} <= 15 )) && [[ "$value" != "sit0" ]]; then
            TUNNEL_NAME="$value"
            NAME_EXPLICIT=1
            break
        fi
        input_error "接口名称只能包含字母、数字、点、下划线和连字符，最长 15 个字符，且不能是 sit0"
    done

    while true; do
        value="$(prompt_value "本地 IPv4；输入 auto 自动识别" "${LOCAL_IPV4:-auto}")"
        if [[ "$value" == "auto" ]]; then
            LOCAL_IPV4=""
            break
        elif is_ipv4 "$value"; then
            LOCAL_IPV4="$value"
            break
        fi
        input_error "请输入网卡上的本地 IPv4；使用 EIP/NAT 时不要填写公网 EIP"
    done

    while true; do
        value="$(prompt_value "出口网卡；输入 auto 自动识别" "${OUT_INTERFACE:-auto}")"
        if [[ "$value" == "auto" ]]; then
            OUT_INTERFACE=""
            break
        elif [[ "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] && (( ${#value} <= 15 )); then
            OUT_INTERFACE="$value"
            break
        fi
        input_error "网卡名称格式无效，或超过 15 个字符"
    done

    MTU="$(prompt_uint_range "MTU" "$MTU" 1280 1480)"
    TTL="$(prompt_uint_range "TTL" "$TTL" 1 255)"
    ROUTE_METRIC="$(prompt_uint_range "IPv6 默认路由 metric" "$ROUTE_METRIC" 1 4294967295)"
    prompt_backend_choice
}

prompt_install_parameters() {
    local suggested_server answer

    section "HE 参数向导"
    hint "请打开 HE Tunnel Details 页面，只需复制下面 3 个字段。"
    hint "不要复制示例配置中的 local 公网地址；脚本会自动识别 EIP/NAT 后的真实本地地址。"

    section "[1/3] Server IPv4 Address"
    hint "复制 HE 页面中的 Server IPv4 Address，例如 216.218.221.6。"
    HE_SERVER_IPV4="$(prompt_ipv4_required)"

    section "[2/3] Client IPv6 Address"
    hint "复制 HE 页面中的 Client IPv6 Address，通常以 ::2 结尾。"
    hint "可以直接粘贴裸地址；未填写前缀时会自动补为 /64。"
    HE_CLIENT_IPV6="$(prompt_client_ipv6)"

    suggested_server="$(derive_he_server_ipv6 "$HE_CLIENT_IPV6")"
    section "[3/3] Server IPv6 Address"
    hint "复制 HE 页面中的 Server IPv6 Address，通常以 ::1 结尾。"
    if [[ -n "$suggested_server" ]]; then
        hint "已根据 Client IPv6 推算出常见值；直接回车即可采用。"
    fi
    HE_SERVER_IPV6="$(prompt_server_ipv6 "$HE_CLIENT_IPV6" "$suggested_server")"

    printf '\n'
    read -r -p "是否修改网卡、MTU、TTL 或持久化方式等高级设置？ [y/N]: " answer
    if [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        prompt_advanced_settings
    else
        log "使用推荐高级设置：自动识别网卡和本地 IPv4，MTU 1480，TTL 255，自动持久化"
    fi
}

show_install_summary() {
    section "部署前检查"
    printf '  %-30s %b%s%b\n' "Server IPv4 Address" "$COLOR_GREEN" "$HE_SERVER_IPV4" "$COLOR_RESET"
    printf '  %-30s %b%s%b\n' "Server IPv6 Address" "$COLOR_GREEN" "$HE_SERVER_IPV6" "$COLOR_RESET"
    printf '  %-30s %b%s%b\n' "Client IPv6 Address" "$COLOR_GREEN" "${HE_CLIENT_IPV6%/*}" "$COLOR_RESET"
    printf '  %-30s /%s\n' "Client IPv6 Prefix" "${HE_CLIENT_IPV6#*/}"
    printf '\n'
    printf '  %-30s %s\n' "隧道接口" "$TUNNEL_NAME"
    printf '  %-30s %s\n' "本地 IPv4" "${LOCAL_IPV4:-自动识别}"
    printf '  %-30s %s\n' "出口网卡" "${OUT_INTERFACE:-自动识别}"
    printf '  %-30s %s / %s\n' "MTU / TTL" "$MTU" "$TTL"
    printf '  %-30s %s\n' "持久化方式" "$BACKEND"

    if [[ "$HE_SERVER_IPV6" != *:1 || "${HE_CLIENT_IPV6%/*}" != *:2 ]]; then
        warn "当前 IPv6 尾号不是 HE 常见的 Server ::1 / Client ::2，请再次对照 Tunnel Details 页面"
    fi
    if [[ "${HE_CLIENT_IPV6#*/}" != "64" ]]; then
        warn "Client IPv6 前缀不是 HE 常见的 /64，请确认该前缀确实来自 HE 页面"
    fi
}

interactive_menu() {
    local choice
    [[ -t 0 && -t 1 ]] || die "交互菜单需要终端"
    INTERACTIVE=1
    printf '\n%b================================================%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '%b  Hurricane Electric HE/SIT IPv6 隧道管理工具%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    printf '%b================================================%b\n' "$COLOR_CYAN" "$COLOR_RESET"
    cat <<'EOF'
  1) 全新部署 HE 隧道（参数向导）
  2) 扫描本机已安装的 HE/SIT 隧道
  3) 查看隧道状态和配置来源
  4) 彻底卸载指定或全部隧道
  5) 预演彻底卸载（只展示，不修改）
  6) 自毁卸载（删除全部隧道、备份和脚本本身）
  0) 退出
EOF
    read -r -p "请选择 [1]: " choice
    case "${choice:-1}" in
        1)
            ACTION="install"
            prompt_install_parameters
            show_install_summary
            hint "请重点核对：Server IPv6 是 HE 网关地址，Client IPv6 是本机地址，两者不能相同。"
            confirm "以上参数确认无误，开始全新部署" || exit 0
            ;;
        2) ACTION="discover" ;;
        3) ACTION="status" ;;
        4) ACTION="uninstall" ;;
        5) ACTION="uninstall"; DRY_RUN=1 ;;
        6) ACTION="self-destruct" ;;
        0) exit 0 ;;
        *) die "无效选项: $choice" ;;
    esac
}

main() {
    if (( $# == 0 )); then
        if [[ -t 0 && -t 1 ]]; then
            ACTION="menu"
        else
            usage
            exit 1
        fi
    else
        parse_arguments "$@"
    fi

    [[ -n "$ACTION" ]] || {
        usage
        exit 1
    }
    require_root
    if [[ "$ACTION" == "menu" ]]; then
        interactive_menu
    fi

    case "$ACTION" in
        install)
            validate_install_arguments
            preflight_install
            install_fresh_tunnel
            ;;
        discover)
            need_command find
            discover_all
            display_discovery
            ;;
        status)
            [[ "$ALL_TUNNELS" == "1" ]] || validate_name
            show_status
            ;;
        uninstall)
            [[ "$ALL_TUNNELS" == "1" ]] || validate_name
            uninstall_discovered_tunnels
            ;;
        self-destruct)
            self_destruct_everything
            ;;
        *) die "Unsupported action: $ACTION" ;;
    esac
}

main "$@"
