#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

APP_NAME="VPS 出口切换助手"
STATE_DIR="/etc/vps-out-switch"
CLIENT_DIR="$STATE_DIR/clients"
SINGBOX_CONF_DIR="$STATE_DIR/sing-box"
SINGBOX_CONF="$SINGBOX_CONF_DIR/config.json"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_SERVICE="/etc/systemd/system/vps-out-singbox.service"
GENERIC_SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
SINGBOX_DROPIN_DIR="/etc/systemd/system/vps-out-singbox.service.d"
SINGBOX_INCUS_BYPASS_SCRIPT="/usr/local/sbin/vps-out-incus-bypass.sh"
SINGBOX_INCUS_BYPASS_DROPIN="$SINGBOX_DROPIN_DIR/10-incus-bypass.conf"
WATCHDOG_SCRIPT="/usr/local/sbin/vps-out-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/vps-out-watchdog.service"
WG_CLIENT_RULES_SCRIPT="/usr/local/sbin/vps-out-wg-client-rules.sh"
PORT_FORWARD_DIR="$STATE_DIR/port-forwards"
SPLIT_POLICY_FILE="$STATE_DIR/split-policy.env"
STREAM_RULE_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.xray.list"
STREAM_RULE_FILE="$STATE_DIR/stream.xray.list"
STREAM_SELECTED_FILE="$STATE_DIR/stream-selected-categories.txt"
STREAM_PROXY_DOMAINS_FILE="$STATE_DIR/stream-proxy-domains.txt"
SINGBOX_PROXY_CIDRS_FILE="$STATE_DIR/singbox-proxy-cidrs.txt"
STREAM_RECOMMENDED_CATEGORIES="Netflix, Disney+, Youtube, Amazon Prime Video:, HBO / Max, HuluUSA, DAZN, Tiktok, BiliBili, iQiyi, Abema, Bahamut Anime, ESPN+"
WG_CLIENT_IFACE="vpsoutwg"
WG_SERVER_IFACE="vpsout"
WG_CLIENT_CONF="/etc/wireguard/${WG_CLIENT_IFACE}.conf"
WG_SERVER_CONF="/etc/wireguard/${WG_SERVER_IFACE}.conf"
WG_SERVER_ENV="$STATE_DIR/wg-server.env"
WG_SERVER_NFT="$STATE_DIR/wg-server.nft"
HYBRID_WG_RULES_SCRIPT="/usr/local/sbin/vps-out-hybrid-wg-routes.sh"
HYBRID_MODE_NAME="混合模式：sing-box 分流 + WireGuard 出口"
HYBRID_ROUTE_METRIC="51820"
HYBRID_ROUTE_TABLE="51820"
HYBRID_ROUTE_PREF="5182"
HYBRID_ROUTE_MARK="0x51820"
HYBRID_ROUTE_MARK_DEC="333856"
DNS_CSV="1.1.1.1, 8.8.8.8, 2606:4700:4700::1111, 2001:4860:4860::8888"
DNS_SPACE="1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888"
DNS_RESOLV_CONTENT=$'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\n'
DEFAULT_DIRECT_DOMAINS="github.com, githubusercontent.com, githubassets.com, github.io, docker.com, docker.io, registry-1.docker.io, auth.docker.io, production.cloudflare.docker.com, debian.org, ubuntu.com, canonical.com, archive.ubuntu.com, security.ubuntu.com, alpinelinux.org, archlinux.org, fedoraproject.org, centos.org, rockylinux.org, python.org, pypi.org, pythonhosted.org, npmjs.org, npmjs.com, nodejs.org, go.dev, golang.org, proxy.golang.org, rust-lang.org, crates.io, packagist.org, composer.org, rubygems.org"
PRIVATE_EXCLUDE_CIDRS="10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, ::1/128, fc00::/7, fe80::/10"
MIN_SINGBOX_VERSION="1.13.3"
FALLBACK_SINGBOX_VERSION="1.13.3"

if [ -t 1 ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

info() { printf '%s\n' "${BLUE}$*${NC}"; }
ok() { printf '%s\n' "${GREEN}$*${NC}"; }
warn() { printf '%s\n' "${YELLOW}$*${NC}"; }
err() { printf '%s\n' "${RED}$*${NC}" >&2; }
die() { err "错误：$*"; exit 1; }

pause() {
  local _
  read -r -p "按回车返回菜单..." _ || true
}

safe_clear() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    clear || true
  fi
}

get_script_path() {
  local src="$0" dir base
  case "$src" in
    /*) ;;
    *) src="$PWD/$src" ;;
  esac
  dir="$(dirname -- "$src")"
  base="$(basename -- "$src")"
  if [ -d "$dir" ]; then
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$PWD" "$base")
  else
    printf '%s\n' "$src"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-N}"
  local suffix answer
  if [[ "$default" =~ ^[Yy]$ ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  read -r -p "$prompt $suffix " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 身份运行：sudo bash $0"
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "此脚本需要 systemd 管理服务，当前系统未找到 systemctl"
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$CLIENT_DIR" "$SINGBOX_CONF_DIR" "$PORT_FORWARD_DIR" /etc/wireguard
  chmod 700 "$STATE_DIR" "$CLIENT_DIR" "$PORT_FORWARD_DIR" /etc/wireguard
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  else
    return 1
  fi
}

install_pkg_list() {
  local pm="$1"
  shift
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    pacman)
      pacman -Sy --noconfirm "$@"
      ;;
    *)
      die "不支持的包管理器：$pm"
      ;;
  esac
}

ensure_common_tools() {
  local pm
  pm="$(detect_pm)" || die "未识别包管理器，请先手动安装 curl、jq、nftables、iproute2"
  case "$pm" in
    apt) install_pkg_list "$pm" curl ca-certificates tar gzip iproute2 nftables jq ;;
    dnf|yum) install_pkg_list "$pm" curl ca-certificates tar gzip iproute nftables jq ;;
    apk) install_pkg_list "$pm" bash curl ca-certificates tar gzip iproute2 nftables jq ;;
    pacman) install_pkg_list "$pm" curl ca-certificates tar gzip iproute2 nftables jq ;;
  esac
}

ensure_wg_tools() {
  local pm
  ensure_common_tools
  pm="$(detect_pm)" || die "未识别包管理器，请先手动安装 wireguard-tools"
  case "$pm" in
    apt|dnf|yum|apk|pacman) install_pkg_list "$pm" wireguard-tools ;;
  esac
}

enable_kernel_features() {
  modprobe tun 2>/dev/null || true
  modprobe wireguard 2>/dev/null || true
  modprobe nft_nat 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nftables >/dev/null 2>&1 || true
  fi
}

get_default_iface4() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_default_gw4() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

get_default_iface6() {
  ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_default_gw6() {
  ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "$1" == *:* ]]
}

is_ip_literal() {
  is_ipv4 "$1" || is_ipv6 "$1"
}

strip_brackets() {
  local value="$1"
  value="${value#[}"
  value="${value%]}"
  printf '%s' "$value"
}

cidr_for_ip() {
  local ip
  ip="$(strip_brackets "$1")"
  if is_ipv6 "$ip"; then
    printf '%s/128' "$ip"
  else
    printf '%s/32' "$ip"
  fi
}

get_ssh_client_ip() {
  if [ -n "${SSH_CLIENT:-}" ]; then
    awk '{print $1}' <<<"$SSH_CLIENT"
    return
  fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    awk '{print $1}' <<<"$SSH_CONNECTION"
    return
  fi
  who am i 2>/dev/null | awk '{print $5}' | tr -d '()' || true
}

resolve_first_ip() {
  local host="$1"
  host="$(strip_brackets "$host")"
  if is_ip_literal "$host"; then
    printf '%s' "$host"
    return
  fi
  getent ahosts "$host" 2>/dev/null | awk '{print $1; exit}'
}

resolve_all_ips() {
  local host="$1"
  host="$(strip_brackets "$host")"
  if is_ip_literal "$host"; then
    printf '%s\n' "$host"
    return
  fi
  getent ahosts "$host" 2>/dev/null | awk '{print $1}' | awk 'NF && !seen[$0]++' || true
}

resolve_cidrs_for_host() {
  local host="$1" ip
  while IFS= read -r ip; do
    if [ -n "$ip" ] && is_ip_literal "$ip"; then
      cidr_for_ip "$ip"
      printf '\n'
    fi
  done < <(resolve_all_ips "$host" || true) | awk 'NF && !seen[$0]++' | sort -u
}

join_lines_csv() {
  awk 'NF { if (out != "") out = out ", "; out = out $0 } END { print out }'
}

write_proxy_cidrs_state() {
  local cidrs="${1:-}"
  ensure_dirs
  if [ -n "$cidrs" ]; then
    printf '%s\n' "$cidrs" > "$SINGBOX_PROXY_CIDRS_FILE"
  else
    : > "$SINGBOX_PROXY_CIDRS_FILE"
  fi
  chmod 600 "$SINGBOX_PROXY_CIDRS_FILE" 2>/dev/null || true
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

version_ge() {
  local current="$1" required="$2"
  awk -v current="$current" -v required="$required" '
    BEGIN {
      split(current, c, ".")
      split(required, r, ".")
      for (i = 1; i <= 3; i++) {
        cv = c[i] + 0
        rv = r[i] + 0
        if (cv > rv) exit 0
        if (cv < rv) exit 1
      }
      exit 0
    }'
}

csv_to_json_array() {
  local input="${1:-}"
  jq -c -n --arg input "$input" '$input | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))'
}

write_active_mode() {
  ensure_dirs
  printf '%s\n' "$1" > "$STATE_DIR/active-mode"
}

write_shell_env_value() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value"
}

init_split_policy() {
  ensure_dirs
  if [ ! -f "$SPLIT_POLICY_FILE" ]; then
    {
      write_shell_env_value "SPLIT_POLICY_NAME" "默认推荐分流"
      write_shell_env_value "SPLIT_INCLUDE_STREAM" "0"
      write_shell_env_value "SPLIT_STREAM_CATEGORIES" ""
      write_shell_env_value "SPLIT_STREAM_DOMAIN_COUNT" "0"
    } > "$SPLIT_POLICY_FILE"
    chmod 600 "$SPLIT_POLICY_FILE"
  fi
}

load_split_policy() {
  init_split_policy
  # shellcheck disable=SC1090
  . "$SPLIT_POLICY_FILE"
  SPLIT_POLICY_NAME="${SPLIT_POLICY_NAME:-默认推荐分流}"
  SPLIT_INCLUDE_STREAM="${SPLIT_INCLUDE_STREAM:-0}"
  SPLIT_STREAM_CATEGORIES="${SPLIT_STREAM_CATEGORIES:-}"
  SPLIT_STREAM_DOMAIN_COUNT="${SPLIT_STREAM_DOMAIN_COUNT:-0}"
}

save_split_policy() {
  ensure_dirs
  {
    write_shell_env_value "SPLIT_POLICY_NAME" "${SPLIT_POLICY_NAME:-默认推荐分流}"
    write_shell_env_value "SPLIT_INCLUDE_STREAM" "${SPLIT_INCLUDE_STREAM:-0}"
    write_shell_env_value "SPLIT_STREAM_CATEGORIES" "${SPLIT_STREAM_CATEGORIES:-}"
    write_shell_env_value "SPLIT_STREAM_DOMAIN_COUNT" "${SPLIT_STREAM_DOMAIN_COUNT:-0}"
  } > "$SPLIT_POLICY_FILE"
  chmod 600 "$SPLIT_POLICY_FILE"
}

dedupe_csv() {
  local input="${1:-}"
  printf '%s' "$input" | awk -v RS=',' '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && !seen[$0]++) {
        if (out != "") out = out ", "
        out = out $0
      }
    }
    END {print out}'
}

append_csv() {
  local base="${1:-}" add="${2:-}"
  if [ -n "$base" ] && [ -n "$add" ]; then
    dedupe_csv "$base, $add"
  elif [ -n "$base" ]; then
    dedupe_csv "$base"
  else
    dedupe_csv "$add"
  fi
}

line_list_to_csv() {
  awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "" && !seen[$0]++) {
        if (out != "") out = out ", "
        out = out $0
      }
    }
    END {print out}'
}

download_stream_rules() {
  ensure_dirs
  command -v curl >/dev/null 2>&1 || ensure_common_tools
  info "正在下载流媒体分流规则..."
  curl -fL --retry 3 --connect-timeout 15 -o "$STREAM_RULE_FILE.tmp" "$STREAM_RULE_URL" || die "流媒体规则下载失败：$STREAM_RULE_URL"
  tr -d '\r' < "$STREAM_RULE_FILE.tmp" > "$STREAM_RULE_FILE"
  rm -f "$STREAM_RULE_FILE.tmp"
  chmod 600 "$STREAM_RULE_FILE"
  ok "流媒体规则已缓存：$STREAM_RULE_FILE"
}

ensure_stream_rules() {
  if [ ! -s "$STREAM_RULE_FILE" ]; then
    download_stream_rules
  fi
}

stream_category_counts() {
  ensure_stream_rules
  awk '
    /^# *>/ {
      cat = $0
      sub(/^# *> */, "", cat)
      gsub(/[[:space:]]+$/, "", cat)
      if (cat == "") cat = "未分类"
      if (!(cat in seen)) {
        order[++n] = cat
        seen[cat] = 1
      }
      next
    }
    /"domain:/ {
      if (cat == "") {
        cat = "未分类"
        if (!(cat in seen)) {
          order[++n] = cat
          seen[cat] = 1
        }
      }
      count[cat]++
    }
    END {
      for (i = 1; i <= n; i++) {
        printf "%s\t%d\n", order[i], count[order[i]] + 0
      }
    }' "$STREAM_RULE_FILE"
}

extract_stream_domains_by_categories() {
  local selected_file="$1"
  ensure_stream_rules
  awk -v selected_file="$selected_file" '
    BEGIN {
      while ((getline line < selected_file) > 0) {
        gsub(/\r/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") selected[line] = 1
      }
      close(selected_file)
    }
    /^# *>/ {
      cat = $0
      sub(/^# *> */, "", cat)
      gsub(/[[:space:]]+$/, "", cat)
      next
    }
    cat in selected && /"domain:/ {
      domain = $0
      sub(/^.*"domain:/, "", domain)
      sub(/".*$/, "", domain)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", domain)
      if (domain != "" && !seen[domain]++) print domain
    }' "$STREAM_RULE_FILE"
}

select_stream_categories() {
  local tmp_list selection total selected_names domain_count categories_csv
  ensure_stream_rules
  tmp_list="$(mktemp)"
  stream_category_counts > "$tmp_list"
  total="$(wc -l < "$tmp_list" | tr -d ' ')"
  [ "$total" -gt 0 ] || die "流媒体规则文件里没有解析到分类"

  info "可选流媒体分流分类（输入 all 表示全选，输入 r 表示常用推荐，输入序号可逗号分隔，例如 1,3,8）："
  awk -F '\t' '{printf " %3d. %-32s %s 条\n", NR, $1, $2}' "$tmp_list"
  read -r -p "请选择分类，默认 all：" selection || true
  selection="${selection:-all}"

  : > "$STREAM_SELECTED_FILE"
  if [ "$selection" = "all" ] || [ "$selection" = "ALL" ]; then
    cut -f1 "$tmp_list" > "$STREAM_SELECTED_FILE"
  elif [ "$selection" = "r" ] || [ "$selection" = "R" ]; then
    printf '%s' "$STREAM_RECOMMENDED_CATEGORIES" | tr ',' '\n' | while read -r cat; do
      cat="$(printf '%s' "$cat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -n "$cat" ] && awk -F '\t' -v name="$cat" '$1 == name {print $1}' "$tmp_list" >> "$STREAM_SELECTED_FILE"
    done
  else
    printf '%s' "$selection" | tr ',' '\n' | while read -r index; do
      index="$(printf '%s' "$index" | tr -d '[:space:]')"
      [[ "$index" =~ ^[0-9]+$ ]] || continue
      awk -F '\t' -v idx="$index" 'NR == idx {print $1}' "$tmp_list" >> "$STREAM_SELECTED_FILE"
    done
  fi

  if [ ! -s "$STREAM_SELECTED_FILE" ]; then
    rm -f "$tmp_list"
    die "没有选择任何有效分类"
  fi

  sort -u "$STREAM_SELECTED_FILE" > "$STREAM_SELECTED_FILE.tmp"
  mv "$STREAM_SELECTED_FILE.tmp" "$STREAM_SELECTED_FILE"
  extract_stream_domains_by_categories "$STREAM_SELECTED_FILE" | sort -u > "$STREAM_PROXY_DOMAINS_FILE"
  domain_count="$(wc -l < "$STREAM_PROXY_DOMAINS_FILE" | tr -d ' ')"
  categories_csv="$(line_list_to_csv < "$STREAM_SELECTED_FILE")"
  selected_names="$categories_csv"
  rm -f "$tmp_list"

  [ "$domain_count" -gt 0 ] || die "所选分类没有解析到 domain 规则"
  SPLIT_POLICY_NAME="默认推荐分流 + 流媒体代理"
  SPLIT_INCLUDE_STREAM="1"
  SPLIT_STREAM_CATEGORIES="$categories_csv"
  SPLIT_STREAM_DOMAIN_COUNT="$domain_count"
  save_split_policy
  ok "已启用流媒体扩展分流：$domain_count 个域名后缀"
  [ -n "$selected_names" ] && echo "已选分类：$selected_names"
}

write_watchdog_files() {
  cat > "$WATCHDOG_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

STATE_DIR="$STATE_DIR"
ACTIVE_FILE="$STATE_DIR/active-mode"
SINGBOX_SERVICE="vps-out-singbox"
SINGBOX_CONF="$SINGBOX_CONF"
SINGBOX_BIN="$SINGBOX_BIN"
SINGBOX_TUN="vpsout0"
PROXY_CIDRS_FILE="$SINGBOX_PROXY_CIDRS_FILE"
WG_CLIENT_UNIT="wg-quick@${WG_CLIENT_IFACE}"
WG_CLIENT_IFACE="${WG_CLIENT_IFACE}"
HYBRID_MODE_NAME="$HYBRID_MODE_NAME"
WG_HANDSHAKE_MAX_AGE=180
WG_NO_HANDSHAKE_FILE="\$STATE_DIR/wg-no-handshake-since"
CHECK_INTERVAL=10
DDNS_CHECK_INTERVAL=60
LAST_DDNS_CHECK=0

log() {
  logger -t vps-out-watchdog "\$*"
}

restart_unit() {
  local unit="\$1" reason="\$2"
  log "\$reason，正在重启 \$unit"
  systemctl restart "\$unit" >/dev/null 2>&1 || log "重启 \$unit 失败"
}

strip_brackets() {
  local value="\$1"
  value="\${value#[}"
  value="\${value%]}"
  printf '%s' "\$value"
}

is_ipv4() {
  [[ "\$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "\$1" == *:* ]]
}

is_ip_literal() {
  is_ipv4 "\$1" || is_ipv6 "\$1"
}

cidr_for_ip() {
  local ip
  ip="\$(strip_brackets "\$1")"
  if is_ipv6 "\$ip"; then
    printf '%s/128\n' "\$ip"
  else
    printf '%s/32\n' "\$ip"
  fi
}

resolve_all_ips() {
  local host="\$1"
  host="\$(strip_brackets "\$host")"
  if is_ip_literal "\$host"; then
    printf '%s\n' "\$host"
    return
  fi
  getent ahosts "\$host" 2>/dev/null | awk '{print \$1}' | awk 'NF && !seen[\$0]++' || true
}

resolve_cidrs_for_host() {
  local host="\$1" ip
  while IFS= read -r ip; do
    if [ -n "\$ip" ] && is_ip_literal "\$ip"; then
      cidr_for_ip "\$ip"
    fi
  done < <(resolve_all_ips "\$host" || true) | awk 'NF && !seen[\$0]++' | sort -u
}

join_lines_csv() {
  awk 'NF { if (out != "") out = out ", "; out = out \$0 } END { print out }'
}

csv_to_json_array() {
  local input="\${1:-}"
  jq -c -n --arg input "\$input" '\$input | split(",") | map(gsub("^\\\\s+|\\\\s+$";"")) | map(select(length > 0))'
}

refresh_singbox_proxy_ddns() {
  local host old_csv new_csv old_json new_json tmp
  [ -f "\$SINGBOX_CONF" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v getent >/dev/null 2>&1 || return 0
  host="\$(jq -r '(.outbounds // [])[]? | select(.tag=="proxy") | .server // empty' "\$SINGBOX_CONF" 2>/dev/null | head -n 1)"
  [ -n "\$host" ] || return 0
  host="\$(strip_brackets "\$host")"
  is_ip_literal "\$host" && return 0

  new_csv="\$(resolve_cidrs_for_host "\$host" | join_lines_csv)"
  if [ -z "\$new_csv" ]; then
    log "proxy ddns \$host has no DNS result, keep current sing-box config"
    return 0
  fi

  old_csv="\$(cat "\$PROXY_CIDRS_FILE" 2>/dev/null || true)"
  [ "\$new_csv" = "\$old_csv" ] && return 0

  old_json="\$(csv_to_json_array "\$old_csv")" || return 0
  new_json="\$(csv_to_json_array "\$new_csv")" || return 0
  tmp="\$(mktemp)" || return 0

  if jq --argjson oldCidrs "\$old_json" --argjson newCidrs "\$new_json" '
    def arr(\$x): if (\$x | type) == "array" then \$x elif \$x == null then [] else [\$x] end;
    def same_set(\$a; \$b): (arr(\$a) | sort) == (arr(\$b) | sort);
    def managed_old_rule:
      (.action == "route" and .outbound == "direct" and (.ip_cidr? != null) and same_set(.ip_cidr; \$oldCidrs));
    .inbounds = ((.inbounds // []) | map(
      if (.type == "tun" and .tag == "tun-in") then
        .route_exclude_address = (((.route_exclude_address // []) - \$oldCidrs + \$newCidrs) | unique)
      else . end
    ))
    | .route.rules = (
      (.route.rules // []) as \$rules
      | (\$rules | map(select((managed_old_rule) | not))) as \$clean
      | if (\$newCidrs | length) > 0 then
          (\$clean[0:4] + [{ip_cidr: \$newCidrs, action: "route", outbound: "direct"}] + \$clean[4:])
        else \$clean end
    )
  ' "\$SINGBOX_CONF" > "\$tmp"; then
    if "\$SINGBOX_BIN" check -c "\$tmp" >/dev/null 2>&1; then
      cat "\$tmp" > "\$SINGBOX_CONF"
      chmod 600 "\$SINGBOX_CONF" >/dev/null 2>&1 || true
      printf '%s\n' "\$new_csv" > "\$PROXY_CIDRS_FILE"
      chmod 600 "\$PROXY_CIDRS_FILE" >/dev/null 2>&1 || true
      restart_unit "\$SINGBOX_SERVICE" "proxy ddns \$host changed: \${old_csv:-empty} -> \$new_csv"
    else
      log "proxy ddns update produced invalid sing-box config, keep old config"
    fi
  else
    log "proxy ddns update failed, keep old sing-box config"
  fi
  rm -f "\$tmp"
}

maybe_refresh_singbox_proxy_ddns() {
  local now
  now="\$(date +%s)"
  if [ "\$((now - LAST_DDNS_CHECK))" -lt "\$DDNS_CHECK_INTERVAL" ]; then
    return 0
  fi
  LAST_DDNS_CHECK="\$now"
  refresh_singbox_proxy_ddns || true
}

check_singbox() {
  if ! systemctl is-active --quiet "\$SINGBOX_SERVICE"; then
    restart_unit "\$SINGBOX_SERVICE" "sing-box 服务未运行"
    return 1
  fi
  if ! ip link show "\$SINGBOX_TUN" >/dev/null 2>&1; then
    restart_unit "\$SINGBOX_SERVICE" "sing-box TUN 接口 \$SINGBOX_TUN 不存在"
    return 1
  fi
  maybe_refresh_singbox_proxy_ddns
  return 0
}

check_wireguard_client() {
  local latest now age first_seen
  if ! systemctl is-active --quiet "\$WG_CLIENT_UNIT"; then
    restart_unit "\$WG_CLIENT_UNIT" "WireGuard 客户端服务未运行"
    return 1
  fi
  if ! ip link show "\$WG_CLIENT_IFACE" >/dev/null 2>&1; then
    restart_unit "\$WG_CLIENT_UNIT" "WireGuard 客户端接口 \$WG_CLIENT_IFACE 不存在"
    return 1
  fi
  latest="\$(wg show "\$WG_CLIENT_IFACE" latest-handshakes 2>/dev/null | awk '{print \$2}' | sort -nr | head -n 1)"
  now="\$(date +%s)"
  if [ -n "\$latest" ] && [ "\$latest" -gt 0 ]; then
    rm -f "\$WG_NO_HANDSHAKE_FILE"
    age="\$((now - latest))"
    if [ "\$age" -gt "\$WG_HANDSHAKE_MAX_AGE" ]; then
      restart_unit "\$WG_CLIENT_UNIT" "WireGuard 最近握手已超过 \${WG_HANDSHAKE_MAX_AGE}s"
      return 1
    fi
  else
    first_seen="\$(cat "\$WG_NO_HANDSHAKE_FILE" 2>/dev/null || true)"
    if ! [[ "\$first_seen" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "\$now" > "\$WG_NO_HANDSHAKE_FILE"
      return
    fi
    age="\$((now - first_seen))"
    if [ "\$age" -gt "\$WG_HANDSHAKE_MAX_AGE" ]; then
      rm -f "\$WG_NO_HANDSHAKE_FILE"
      restart_unit "\$WG_CLIENT_UNIT" "WireGuard 启动后超过 \${WG_HANDSHAKE_MAX_AGE}s 仍无握手"
      return 1
    fi
  fi
  return 0
}

check_hybrid() {
  if ! check_wireguard_client; then
    sleep 2
    restart_unit "\$SINGBOX_SERVICE" "WireGuard 已重启，刷新 sing-box 的 WG 网卡绑定"
    return
  fi
  check_singbox || true
}

while true; do
  mode="\$(cat "\$ACTIVE_FILE" 2>/dev/null || true)"
  case "\$mode" in
    "sing-box+nftables") check_singbox ;;
    "WireGuard 客户端") check_wireguard_client ;;
    "\$HYBRID_MODE_NAME") check_hybrid ;;
  esac
  sleep "\$CHECK_INTERVAL"
done
EOF
  chmod 755 "$WATCHDOG_SCRIPT"

  cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=VPS Out Switch watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

enable_watchdog() {
  need_systemd
  write_watchdog_files
  systemctl daemon-reload
  systemctl enable --now vps-out-watchdog
}

disable_watchdog() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now vps-out-watchdog >/dev/null 2>&1 || true
  fi
}

read_active_mode() {
  if [ -f "$STATE_DIR/active-mode" ]; then
    cat "$STATE_DIR/active-mode"
  else
    printf '未启用'
  fi
}

select_wan_iface() {
  local default_iface iface selection
  local -a detected ordered
  default_iface="$(get_default_iface4)"
  mapfile -t detected < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo|docker|docker0|podman|podman0|cni|cni0|veth|br-|virbr|tun|wg|vpsout|tailscale|zt|incusbr|lxdbr)' | awk '!seen[$0]++')
  ordered=()
  case "$default_iface" in
    ""|lo|docker*|podman*|cni*|veth*|br-*|virbr*|tun*|wg*|vpsout*|tailscale*|zt*|incusbr*|lxdbr*) ;;
    *) ordered+=("$default_iface") ;;
  esac
  for iface in "${detected[@]}"; do
    if [[ " ${ordered[*]} " != *" $iface "* ]]; then
      ordered+=("$iface")
    fi
  done
  [ "${#ordered[@]}" -gt 0 ] || die "未检测到可用的出网网卡"

  info "请选择公网出网网卡："
  for i in "${!ordered[@]}"; do
    if [ "${ordered[$i]}" = "$default_iface" ]; then
      printf ' %s. %s  %s\n' "$((i + 1))" "${ordered[$i]}" "(当前默认路由)"
    else
      printf ' %s. %s\n' "$((i + 1))" "${ordered[$i]}"
    fi
  done
  read -r -p "输入序号，默认 1：" selection || true
  selection="${selection:-1}"
  [[ "$selection" =~ ^[0-9]+$ ]] || die "网卡序号无效"
  [ "$selection" -ge 1 ] && [ "$selection" -le "${#ordered[@]}" ] || die "网卡序号超出范围"
  WAN_IFACE="${ordered[$((selection - 1))]}"
  ok "已选择网卡：$WAN_IFACE"
}

install_singbox_binary() {
  if [ -x "$SINGBOX_BIN" ]; then
    local current_version
    current_version="$("$SINGBOX_BIN" version 2>/dev/null | sed -nE 's/.*version ([0-9]+(\.[0-9]+){1,2}).*/\1/p' | head -n 1)"
    if [ -n "$current_version" ] && version_ge "$current_version" "$MIN_SINGBOX_VERSION"; then
      ok "已检测到 sing-box：$("$SINGBOX_BIN" version | head -n 1)"
      return
    fi
    warn "检测到 sing-box 版本较旧或无法识别，将升级到当前稳定版。"
  fi

  local arch version tag file_name tar_name url tmp_dir
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv7" ;;
    armv6l) arch="armv6" ;;
    s390x) arch="s390x" ;;
    *) die "暂不支持此 CPU 架构：$(uname -m)" ;;
  esac

  info "正在获取 sing-box 最新版本..."
  tag="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name // empty' || true)"
  version="${tag#v}"
  version="${version:-$FALLBACK_SINGBOX_VERSION}"
  if ! version_ge "$version" "$MIN_SINGBOX_VERSION"; then
    version="$FALLBACK_SINGBOX_VERSION"
  fi
  file_name="sing-box-${version}-linux-${arch}"
  tar_name="${file_name}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${tar_name}"
  tmp_dir="$(mktemp -d)"

  info "正在下载 sing-box v${version}..."
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp_dir/$tar_name" "$url"; then
    warn "GitHub 直连下载失败，尝试 ghproxy 镜像..."
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp_dir/$tar_name" "https://mirror.ghproxy.com/${url}" || die "sing-box 下载失败"
  fi

  tar -xzf "$tmp_dir/$tar_name" -C "$tmp_dir"
  install -m 0755 "$tmp_dir/$file_name/sing-box" "$SINGBOX_BIN"
  rm -rf "$tmp_dir"
  ok "sing-box 安装完成：$("$SINGBOX_BIN" version | head -n 1)"
}

parse_ss_uri() {
  local uri="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$uri" <<'PY'
import base64
import shlex
import sys
import urllib.parse

uri = sys.argv[1].strip()
if not uri.startswith("ss://"):
    raise SystemExit("不是 ss:// 链接")

raw = uri[5:].split("#", 1)[0].split("?", 1)[0]

def b64decode_text(value):
    value = urllib.parse.unquote(value)
    value = value.replace("-", "+").replace("_", "/")
    value += "=" * (-len(value) % 4)
    return base64.b64decode(value).decode()

if "@" in raw:
    userinfo, hostport = raw.rsplit("@", 1)
    userinfo = urllib.parse.unquote(userinfo)
    if ":" not in userinfo:
        userinfo = b64decode_text(userinfo)
else:
    decoded = b64decode_text(raw)
    userinfo, hostport = decoded.rsplit("@", 1)

method, password = userinfo.split(":", 1)
hostport = urllib.parse.unquote(hostport)
if hostport.startswith("["):
    host, rest = hostport[1:].split("]", 1)
    port = rest.lstrip(":")
else:
    host, port = hostport.rsplit(":", 1)

values = {
    "SS_METHOD": method,
    "PROXY_PASS": password,
    "PROXY_ADDR": host,
    "PROXY_PORT": port,
}
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
}

prompt_singbox_node() {
  local choice ss_uri parsed
  info "请选择出口节点类型："
  echo " 1. SOCKS5（别人给的 SK5 节点，或你自建的 SOCKS5）"
  echo " 2. Shadowsocks（手动输入）"
  echo " 3. Shadowsocks（粘贴 ss:// 链接，能解析常见 SIP002 格式）"
  read -r -p "输入序号，默认 1：" choice || true
  choice="${choice:-1}"

  case "$choice" in
    1)
      PROXY_KIND="socks"
      read -r -p "SOCKS5 地址（IP/域名）：" PROXY_ADDR
      read -r -p "SOCKS5 端口：" PROXY_PORT
      read -r -p "用户名（没有就留空）：" PROXY_USER
      read -r -p "密码（没有就留空，明文显示）：" PROXY_PASS
      ;;
    2)
      PROXY_KIND="shadowsocks"
      read -r -p "SS 地址（IP/域名）：" PROXY_ADDR
      read -r -p "SS 端口：" PROXY_PORT
      read -r -p "加密方法，默认 aes-256-gcm：" SS_METHOD
      SS_METHOD="${SS_METHOD:-aes-256-gcm}"
      read -r -s -p "SS 密码： " PROXY_PASS
      echo
      ;;
    3)
      PROXY_KIND="shadowsocks"
      read -r -p "粘贴 ss:// 链接：" ss_uri
      parsed="$(parse_ss_uri "$ss_uri" 2>/dev/null)" || die "解析失败。请确认系统有 python3，或改用手动输入"
      eval "$parsed"
      ok "已解析：$PROXY_ADDR:$PROXY_PORT / $SS_METHOD"
      ;;
    *)
      die "节点类型选择无效"
      ;;
  esac

  [ -n "${PROXY_ADDR:-}" ] || die "节点地址不能为空"
  validate_port "${PROXY_PORT:-}" || die "节点端口无效"
}

apply_managed_split_policy() {
  local stream_csv=""
  load_split_policy
  FINAL_OUTBOUND="proxy"
  DIRECT_DOMAINS="$DEFAULT_DIRECT_DOMAINS"
  DIRECT_CIDRS=""
  PROXY_DOMAINS=""
  PROXY_CIDRS=""

  if [ "${SPLIT_INCLUDE_STREAM:-0}" = "1" ]; then
    if [ -s "$STREAM_PROXY_DOMAINS_FILE" ]; then
      stream_csv="$(line_list_to_csv < "$STREAM_PROXY_DOMAINS_FILE")"
      PROXY_DOMAINS="$(append_csv "$PROXY_DOMAINS" "$stream_csv")"
    else
      warn "已启用流媒体扩展，但未找到缓存域名文件。请先在主菜单进入“分流规则管理”下载/选择分类。"
    fi
  fi
}

prompt_singbox_split() {
  local choice final_choice custom_direct_domains custom_direct_cidrs custom_proxy_domains custom_proxy_cidrs
  info "请选择 sing-box 分流策略："
  echo " 1. 全局代理：除内网、SSH 客户端、代理节点自身外，其余都走出口节点"
  echo " 2. 使用主菜单“分流规则管理”中的当前策略"
  echo " 3. 自定义分流：自己填写直连和代理规则"
  echo " 4. 仅指定规则走代理：默认直连，只把你填写的域名/IP 段送到出口节点"
  read -r -p "输入序号，默认 2：" choice || true
  choice="${choice:-2}"

  DIRECT_DOMAINS=""
  DIRECT_CIDRS=""
  PROXY_DOMAINS=""
  PROXY_CIDRS=""
  FINAL_OUTBOUND="proxy"

  case "$choice" in
    1)
      FINAL_OUTBOUND="proxy"
      ;;
    2)
      apply_managed_split_policy
      ok "当前分流策略：${SPLIT_POLICY_NAME:-默认推荐分流}"
      ;;
    3)
      echo "默认未命中流量走哪里？"
      echo " 1. 走代理"
      echo " 2. 直连"
      read -r -p "输入序号，默认 1：" final_choice || true
      final_choice="${final_choice:-1}"
      if [ "$final_choice" = "2" ]; then
        FINAL_OUTBOUND="direct"
      else
        FINAL_OUTBOUND="proxy"
      fi
      read -r -p "直连域名后缀，逗号分隔，可留空：" custom_direct_domains
      read -r -p "直连 IP/CIDR，逗号分隔，可留空：" custom_direct_cidrs
      read -r -p "代理域名后缀，逗号分隔，可留空：" custom_proxy_domains
      read -r -p "代理 IP/CIDR，逗号分隔，可留空：" custom_proxy_cidrs
      DIRECT_DOMAINS="$custom_direct_domains"
      DIRECT_CIDRS="$custom_direct_cidrs"
      PROXY_DOMAINS="$custom_proxy_domains"
      PROXY_CIDRS="$custom_proxy_cidrs"
      ;;
    4)
      FINAL_OUTBOUND="direct"
      read -r -p "需要走代理的域名后缀，逗号分隔：" custom_proxy_domains
      read -r -p "需要走代理的 IP/CIDR，逗号分隔，可留空：" custom_proxy_cidrs
      PROXY_DOMAINS="$custom_proxy_domains"
      PROXY_CIDRS="$custom_proxy_cidrs"
      ;;
    *)
      die "分流策略选择无效"
      ;;
  esac
}

show_split_policy_status() {
  load_split_policy
  echo "当前策略：$SPLIT_POLICY_NAME"
  echo "默认直连规则：已包含软件源、GitHub、Docker、常用开发生态域名"
  if [ "${SPLIT_INCLUDE_STREAM:-0}" = "1" ]; then
    echo "流媒体扩展：已启用"
    echo "流媒体域名数：${SPLIT_STREAM_DOMAIN_COUNT:-0}"
    echo "已选分类：${SPLIT_STREAM_CATEGORIES:-未记录}"
    [ -s "$STREAM_RULE_FILE" ] && echo "远程规则缓存：$STREAM_RULE_FILE"
  else
    echo "流媒体扩展：未启用"
  fi
}

reset_default_split_policy() {
  SPLIT_POLICY_NAME="默认推荐分流"
  SPLIT_INCLUDE_STREAM="0"
  SPLIT_STREAM_CATEGORIES=""
  SPLIT_STREAM_DOMAIN_COUNT="0"
  rm -f "$STREAM_SELECTED_FILE" "$STREAM_PROXY_DOMAINS_FILE"
  save_split_policy
  ok "已切换为默认推荐分流。"
}

show_stream_category_summary() {
  ensure_stream_rules
  info "流媒体规则分类摘要："
  stream_category_counts | awk -F '\t' '{printf " - %-32s %s 条\n", $1, $2}'
}

manage_split_rules() {
  local choice
  ensure_dirs
  init_split_policy
  while true; do
    safe_clear
    echo "${BLUE}============================================================${NC}"
    echo "${BOLD}                 分流规则管理${NC}"
    echo "${BLUE}============================================================${NC}"
    show_split_policy_status
    echo
    echo " 1. 使用默认推荐分流"
    echo " 2. 下载/更新流媒体分流源"
    echo " 3. 在默认基础上加入流媒体分流（按分类选择，命中走代理）"
    echo " 4. 查看流媒体分类摘要"
    echo " 5. 清空流媒体扩展，只保留默认分流"
    echo " 0. 返回主菜单"
    echo "${BLUE}============================================================${NC}"
    read -r -p "请输入选项：" choice || true
    case "$choice" in
      1) reset_default_split_policy; pause ;;
      2) download_stream_rules; pause ;;
      3) select_stream_categories; pause ;;
      4) show_stream_category_summary; pause ;;
      5) reset_default_split_policy; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

build_proxy_outbound_json() {
  if [ "$PROXY_KIND" = "socks" ]; then
    OUTBOUND_JSON="$(jq -c -n \
      --arg server "$PROXY_ADDR" \
      --argjson port "$PROXY_PORT" \
      --arg user "${PROXY_USER:-}" \
      --arg pass "${PROXY_PASS:-}" \
      '{type:"socks", tag:"proxy", server:$server, server_port:$port, version:"5", domain_resolver:"cf_v4"} +
       (if $user != "" then {username:$user, password:$pass} else {} end)')"
  elif [ "$PROXY_KIND" = "shadowsocks" ]; then
    OUTBOUND_JSON="$(jq -c -n \
      --arg server "$PROXY_ADDR" \
      --argjson port "$PROXY_PORT" \
      --arg method "$SS_METHOD" \
      --arg pass "$PROXY_PASS" \
      '{type:"shadowsocks", tag:"proxy", server:$server, server_port:$port, method:$method, password:$pass, domain_resolver:"cf_v4"}')"
  else
    die "未知代理类型：$PROXY_KIND"
  fi
}

build_singbox_config() {
  local direct_domains_json direct_cidrs_json proxy_domains_json proxy_cidrs_json route_excludes_json proxy_ip_cidrs proxy_ip_cidrs_json proxy_domain_json ssh_ip route_excludes
  build_proxy_outbound_json

  route_excludes="$PRIVATE_EXCLUDE_CIDRS"
  ssh_ip="$(get_ssh_client_ip)"
  if [ -n "$ssh_ip" ] && is_ip_literal "$ssh_ip"; then
    route_excludes="$route_excludes, $(cidr_for_ip "$ssh_ip")"
  fi

  proxy_ip_cidrs="$(resolve_cidrs_for_host "$PROXY_ADDR" | join_lines_csv)"
  proxy_ip_cidrs_json="[]"
  if [ -n "$proxy_ip_cidrs" ]; then
    route_excludes="$route_excludes, $proxy_ip_cidrs"
    proxy_ip_cidrs_json="$(csv_to_json_array "$proxy_ip_cidrs")"
  fi
  write_proxy_cidrs_state "$proxy_ip_cidrs"

  if is_ip_literal "$(strip_brackets "$PROXY_ADDR")"; then
    proxy_domain_json="[]"
  else
    proxy_domain_json="$(jq -c -n --arg d "$PROXY_ADDR" '[$d]')"
  fi

  direct_domains_json="$(csv_to_json_array "$DIRECT_DOMAINS")"
  direct_cidrs_json="$(csv_to_json_array "$DIRECT_CIDRS")"
  proxy_domains_json="$(csv_to_json_array "$PROXY_DOMAINS")"
  proxy_cidrs_json="$(csv_to_json_array "$PROXY_CIDRS")"
  route_excludes_json="$(csv_to_json_array "$route_excludes")"

  jq -n \
    --argjson outbound "$OUTBOUND_JSON" \
    --argjson directDomains "$direct_domains_json" \
    --argjson directCidrs "$direct_cidrs_json" \
    --argjson proxyDomains "$proxy_domains_json" \
    --argjson proxyCidrs "$proxy_cidrs_json" \
    --argjson routeExcludes "$route_excludes_json" \
    --argjson proxyIpCidrs "$proxy_ip_cidrs_json" \
    --argjson proxyDomainsExact "$proxy_domain_json" \
    --arg final "$FINAL_OUTBOUND" '
    def maybe_domain_suffix($items; $out):
      if ($items | length) > 0 then [{domain_suffix:$items, action:"route", outbound:$out}] else [] end;
    def maybe_domain($items; $out):
      if ($items | length) > 0 then [{domain:$items, action:"route", outbound:$out}] else [] end;
    def maybe_cidr($items; $out):
      if ($items | length) > 0 then [{ip_cidr:$items, action:"route", outbound:$out}] else [] end;
    {
      log: {
        level: "info",
        timestamp: true
      },
      dns: {
        servers: [
          {type:"udp", tag:"cf_v4", server:"1.1.1.1", server_port:53, detour:"direct"},
          {type:"udp", tag:"google_v4", server:"8.8.8.8", server_port:53, detour:"direct"},
          {type:"udp", tag:"cf_v6", server:"2606:4700:4700::1111", server_port:53, detour:"direct"},
          {type:"udp", tag:"google_v6", server:"2001:4860:4860::8888", server_port:53, detour:"direct"}
        ],
        final: "cf_v4",
        strategy: "prefer_ipv4",
        reverse_mapping: true
      },
      inbounds: [
        {
          type: "tun",
          tag: "tun-in",
          interface_name: "vpsout0",
          address: [
            "172.19.0.1/30",
            "fdfe:dcba:9876::1/126"
          ],
          mtu: 9000,
          auto_route: true,
          auto_redirect: true,
          strict_route: true,
          route_exclude_address: $routeExcludes,
          stack: "system"
        }
      ],
      outbounds: [
        $outbound,
        {type:"direct", tag:"direct", domain_resolver:"cf_v4"}
      ],
      route: {
        auto_detect_interface: true,
        default_domain_resolver: "cf_v4",
        final: $final,
        rules:
          ([
            {action:"sniff", timeout:"300ms"},
            {port:53, action:"hijack-dns"},
            {protocol:"dns", action:"hijack-dns"},
            {ip_is_private:true, action:"route", outbound:"direct"}
          ]
          + maybe_domain($proxyDomainsExact; "direct")
          + maybe_cidr($proxyIpCidrs; "direct")
          + maybe_domain_suffix($directDomains; "direct")
          + maybe_cidr($directCidrs; "direct")
          + maybe_domain_suffix($proxyDomains; "proxy")
          + maybe_cidr($proxyCidrs; "proxy"))
      }
    }' > "$SINGBOX_CONF"
  chmod 600 "$SINGBOX_CONF"
}

get_wg_endpoint_host_from_conf() {
  local file="${1:-$WG_CLIENT_CONF}" endpoint hostport
  [ -f "$file" ] || return 0
  endpoint="$(awk -F= '
    /^[[:space:]]*Endpoint[[:space:]]*=/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$file")"
  [ -n "$endpoint" ] || return 0
  endpoint="${endpoint%%[[:space:]]*}"
  if [[ "$endpoint" == \[*\]*:* ]]; then
    printf '%s\n' "$endpoint" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/'
  else
    hostport="$endpoint"
    printf '%s\n' "${hostport%:*}"
  fi
}

build_hybrid_singbox_config() {
  local direct_domains_json direct_cidrs_json proxy_domains_json proxy_cidrs_json route_excludes_json ssh_ip route_excludes endpoint_host endpoint_ip_cidrs endpoint_ip_cidrs_json endpoint_domain_json

  route_excludes="$PRIVATE_EXCLUDE_CIDRS"
  ssh_ip="$(get_ssh_client_ip)"
  if [ -n "$ssh_ip" ] && is_ip_literal "$ssh_ip"; then
    route_excludes="$route_excludes, $(cidr_for_ip "$ssh_ip")"
  fi

  endpoint_host="$(get_wg_endpoint_host_from_conf "$WG_CLIENT_CONF" || true)"
  endpoint_ip_cidrs_json="[]"
  endpoint_domain_json="[]"
  if [ -n "$endpoint_host" ]; then
    if is_ip_literal "$(strip_brackets "$endpoint_host")"; then
      endpoint_ip_cidrs="$(cidr_for_ip "$endpoint_host")"
    else
      endpoint_ip_cidrs="$(resolve_cidrs_for_host "$endpoint_host" | join_lines_csv)"
      endpoint_domain_json="$(jq -c -n --arg d "$endpoint_host" '[$d]')"
    fi
    if [ -n "${endpoint_ip_cidrs:-}" ]; then
      route_excludes="$route_excludes, $endpoint_ip_cidrs"
      endpoint_ip_cidrs_json="$(csv_to_json_array "$endpoint_ip_cidrs")"
    fi
  fi

  direct_domains_json="$(csv_to_json_array "$DIRECT_DOMAINS")"
  direct_cidrs_json="$(csv_to_json_array "$DIRECT_CIDRS")"
  proxy_domains_json="$(csv_to_json_array "$PROXY_DOMAINS")"
  proxy_cidrs_json="$(csv_to_json_array "$PROXY_CIDRS")"
  route_excludes_json="$(csv_to_json_array "$route_excludes")"

  jq -n \
    --arg wanIface "$WAN_IFACE" \
    --arg wgIface "$WG_CLIENT_IFACE" \
    --argjson wgMark "$HYBRID_ROUTE_MARK_DEC" \
    --argjson directDomains "$direct_domains_json" \
    --argjson directCidrs "$direct_cidrs_json" \
    --argjson proxyDomains "$proxy_domains_json" \
    --argjson proxyCidrs "$proxy_cidrs_json" \
    --argjson routeExcludes "$route_excludes_json" \
    --argjson endpointIpCidrs "$endpoint_ip_cidrs_json" \
    --argjson endpointDomainsExact "$endpoint_domain_json" \
    --arg final "$FINAL_OUTBOUND" '
    def maybe_domain_suffix($items; $out):
      if ($items | length) > 0 then [{domain_suffix:$items, action:"route", outbound:$out}] else [] end;
    def maybe_domain($items; $out):
      if ($items | length) > 0 then [{domain:$items, action:"route", outbound:$out}] else [] end;
    def maybe_cidr($items; $out):
      if ($items | length) > 0 then [{ip_cidr:$items, action:"route", outbound:$out}] else [] end;
    {
      log: {
        level: "info",
        timestamp: true
      },
      dns: {
        servers: [
          {type:"udp", tag:"cf_v4", server:"1.1.1.1", server_port:53, detour:"direct"},
          {type:"udp", tag:"google_v4", server:"8.8.8.8", server_port:53, detour:"direct"},
          {type:"udp", tag:"cf_v6", server:"2606:4700:4700::1111", server_port:53, detour:"direct"},
          {type:"udp", tag:"google_v6", server:"2001:4860:4860::8888", server_port:53, detour:"direct"}
        ],
        final: "cf_v4",
        strategy: "prefer_ipv4",
        reverse_mapping: true
      },
      inbounds: [
        {
          type: "tun",
          tag: "tun-in",
          interface_name: "vpsout0",
          address: [
            "172.19.0.1/30",
            "fdfe:dcba:9876::1/126"
          ],
          mtu: 9000,
          auto_route: true,
          auto_redirect: true,
          strict_route: false,
          route_exclude_address: $routeExcludes,
          stack: "system"
        }
      ],
      outbounds: [
        {type:"direct", tag:"proxy", bind_interface:$wgIface, routing_mark:$wgMark, domain_resolver:"cf_v4"},
        {type:"direct", tag:"direct", bind_interface:$wanIface, domain_resolver:"cf_v4"}
      ],
      route: {
        default_domain_resolver: "cf_v4",
        final: $final,
        rules:
          ([
            {action:"sniff", timeout:"300ms"},
            {port:53, action:"hijack-dns"},
            {protocol:"dns", action:"hijack-dns"},
            {ip_is_private:true, action:"route", outbound:"direct"}
          ]
          + maybe_domain($endpointDomainsExact; "direct")
          + maybe_cidr($endpointIpCidrs; "direct")
          + maybe_domain_suffix($directDomains; "direct")
          + maybe_cidr($directCidrs; "direct")
          + maybe_domain_suffix($proxyDomains; "proxy")
          + maybe_cidr($proxyCidrs; "proxy"))
      }
    }' > "$SINGBOX_CONF"
  chmod 600 "$SINGBOX_CONF"
}

write_singbox_service() {
  cat > "$SINGBOX_SERVICE" <<EOF
[Unit]
Description=VPS Out Switch - sing-box TUN/NFT mode
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target wg-quick@${WG_CLIENT_IFACE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF
Restart=on-failure
RestartSec=3
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE
NoNewPrivileges=true
LimitNPROC=512
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_singbox_container_bypass() {
  local bypass_wan_iface="${WAN_IFACE:-}"
  if [ -z "$bypass_wan_iface" ]; then
    bypass_wan_iface="$(get_default_iface4)"
  fi
  mkdir -p "$SINGBOX_DROPIN_DIR"
  cat > "$SINGBOX_INCUS_BYPASS_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TABLE="sing-box"
WAN_IFACE="$bypass_wan_iface"
if [ -z "\$WAN_IFACE" ]; then
  WAN_IFACE="\$(ip route show default 2>/dev/null | awk '{print \$5; exit}')"
fi
INBOUND_MARK="0x114"
[ -n "\$WAN_IFACE" ] || exit 0
command -v nft >/dev/null 2>&1 || exit 0

for _ in \$(seq 1 30); do
  nft list chain inet "\$TABLE" prerouting >/dev/null 2>&1 &&
    nft list chain inet "\$TABLE" output >/dev/null 2>&1 &&
    break
  sleep 0.2
done

nft list table inet "\$TABLE" >/dev/null 2>&1 || exit 0

chain_exists() {
  nft list chain inet "\$TABLE" "\$1" >/dev/null 2>&1
}

rule_exists() {
  local chain="\$1" pattern="\$2"
  nft list chain inet "\$TABLE" "\$chain" 2>/dev/null | grep -Fq "\$pattern"
}

insert_once() {
  local chain="\$1" pattern="\$2"
  shift 2
  chain_exists "\$chain" || return 0
  rule_exists "\$chain" "\$pattern" && return 0
  nft insert rule inet "\$TABLE" "\$chain" "\$@" >/dev/null 2>&1 || true
}

# 参考 singbox-out.sh 的保护思路：从物理 WAN 进入的连接是入站会话，
# 例如面板 SSH、Incus/LXC 端口转发，必须保持主路由回包，不能被 TUN 改出口。
for chain in prerouting_prematch prerouting prerouting_udp_icmp; do
  insert_once "\$chain" "ct mark \$INBOUND_MARK return" ct mark "\$INBOUND_MARK" return
  insert_once "\$chain" "iifname \"\$WAN_IFACE\" ct mark set \$INBOUND_MARK return" iifname "\$WAN_IFACE" ct mark set "\$INBOUND_MARK" return
done

for chain in output output_udp_icmp; do
  insert_once "\$chain" "ct mark \$INBOUND_MARK return" ct mark "\$INBOUND_MARK" return
done
EOF
  chmod 755 "$SINGBOX_INCUS_BYPASS_SCRIPT"

  cat > "$SINGBOX_INCUS_BYPASS_DROPIN" <<EOF
[Service]
ExecStartPost=$SINGBOX_INCUS_BYPASS_SCRIPT
EOF
}

stop_singbox_mode() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now vps-out-singbox >/dev/null 2>&1 || true
  fi
}

stop_wg_client_mode() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${WG_CLIENT_IFACE}" >/dev/null 2>&1 || true
  fi
  wg-quick down "$WG_CLIENT_IFACE" >/dev/null 2>&1 || true
  cleanup_hybrid_policy_routes
}

stop_client_modes() {
  stop_singbox_mode
  stop_wg_client_mode
}

stop_all_modes() {
  stop_client_modes
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${WG_SERVER_IFACE}" >/dev/null 2>&1 || true
  fi
  wg-quick down "$WG_SERVER_IFACE" >/dev/null 2>&1 || true
}

stop_generic_singbox() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now sing-box >/dev/null 2>&1 || true
  fi
  pkill -f "$SINGBOX_BIN" >/dev/null 2>&1 || true
}

cleanup_nft_tables() {
  command -v nft >/dev/null 2>&1 || return 0
  nft delete table inet vps_out_wg_filter >/dev/null 2>&1 || true
  nft delete table ip vps_out_wg_nat >/dev/null 2>&1 || true
  nft delete table ip6 vps_out_wg_nat6 >/dev/null 2>&1 || true
  nft delete table inet vps_out_wg_client >/dev/null 2>&1 || true
  nft delete table ip vps_out_wg_client_nat >/dev/null 2>&1 || true
  nft list tables 2>/dev/null | awk '/vps_out|sing-box|singbox/ {print $2, $3}' | while read -r family table; do
    case "$table" in
      *vps_out*|*sing-box*|*singbox*) nft delete table "$family" "$table" >/dev/null 2>&1 || true ;;
    esac
  done
}

cleanup_link_residue() {
  command -v ip >/dev/null 2>&1 || return 0
  ip link delete vpsout0 >/dev/null 2>&1 || true
  ip link delete "$WG_CLIENT_IFACE" >/dev/null 2>&1 || true
  ip link delete "$WG_SERVER_IFACE" >/dev/null 2>&1 || true
}

cleanup_hybrid_policy_routes() {
  command -v ip >/dev/null 2>&1 || return 0
  ip route del default dev "$WG_CLIENT_IFACE" metric "$HYBRID_ROUTE_METRIC" >/dev/null 2>&1 || true
  ip -6 route del default dev "$WG_CLIENT_IFACE" metric "$HYBRID_ROUTE_METRIC" >/dev/null 2>&1 || true
  ip route flush table "$HYBRID_ROUTE_TABLE" >/dev/null 2>&1 || true
  ip -6 route flush table "$HYBRID_ROUTE_TABLE" >/dev/null 2>&1 || true
  ip rule del pref "$HYBRID_ROUTE_PREF" fwmark "$HYBRID_ROUTE_MARK" lookup "$HYBRID_ROUTE_TABLE" >/dev/null 2>&1 || true
  ip -6 rule del pref "$HYBRID_ROUTE_PREF" fwmark "$HYBRID_ROUTE_MARK" lookup "$HYBRID_ROUTE_TABLE" >/dev/null 2>&1 || true
}

collect_managed_iface_addrs() {
  local iface
  command -v ip >/dev/null 2>&1 || return 0
  for iface in vpsout0 "$WG_CLIENT_IFACE"; do
    (ip -o addr show dev "$iface" scope global 2>/dev/null || true) | awk '{sub(/\/.*/, "", $4); print $4}'
  done | awk 'NF && !seen[$0]++'
}

kill_stale_managed_connections() {
  local addrs="${1:-}" addr
  [ "${VPS_OUT_KEEP_STALE_CONNECTIONS:-0}" = "1" ] && return 0
  command -v ss >/dev/null 2>&1 || return 0
  [ -n "$addrs" ] || return 0
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    ss -K src "$addr" >/dev/null 2>&1 || true
  done <<<"$addrs"
}

deploy_singbox_mode() {
  local stale_addrs
  safe_clear
  need_root
  need_systemd
  ensure_dirs
  info "开始部署 sing-box + nftables 模式。此模式适合 SOCKS5/SK5 和 Shadowsocks 出口节点，支持域名与 CIDR 分流。"
  ensure_common_tools
  enable_kernel_features
  install_singbox_binary
  select_wan_iface
  prompt_singbox_node
  prompt_singbox_split

  info "正在生成 sing-box 配置..."
  build_singbox_config
  write_singbox_service
  write_singbox_container_bypass

  info "正在检查配置..."
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF" || die "sing-box 配置检查失败，未启动服务"

  if confirm "是否同时写入系统 DNS 为 Cloudflare/Google？sing-box 内部 DNS 已经固定为这些地址。" "N"; then
    apply_system_dns
  fi

  info "正在切换出口模式..."
  stale_addrs="$(collect_managed_iface_addrs)"
  disable_watchdog
  stop_client_modes
  systemctl daemon-reload
  systemctl enable --now vps-out-singbox
  write_active_mode "sing-box+nftables"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "部署完成。当前模式：sing-box+nftables"
  show_status_brief
  pause
}

apply_system_dns() {
  ensure_dirs
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    if [ -f /etc/systemd/resolved.conf.d/vps-out-switch.conf ] && [ ! -f "$STATE_DIR/resolved.conf.backup" ]; then
      cp -a /etc/systemd/resolved.conf.d/vps-out-switch.conf "$STATE_DIR/resolved.conf.backup"
    fi
    cat > /etc/systemd/resolved.conf.d/vps-out-switch.conf <<EOF
[Resolve]
DNS=$DNS_SPACE
FallbackDNS=$DNS_SPACE
Domains=~.
EOF
    systemctl restart systemd-resolved || warn "systemd-resolved 重启失败，请手动检查 DNS"
    printf 'systemd-resolved\n' > "$STATE_DIR/dns-mode"
    ok "已写入 systemd-resolved DNS：$DNS_CSV"
    return
  fi

  if [ -e /etc/resolv.conf ] && [ ! -f "$STATE_DIR/resolv.conf.backup" ]; then
    cp -a /etc/resolv.conf "$STATE_DIR/resolv.conf.backup" || true
  fi
  printf '%s' "$DNS_RESOLV_CONTENT" > /etc/resolv.conf
  printf 'resolv.conf\n' > "$STATE_DIR/dns-mode"
  ok "已写入 /etc/resolv.conf DNS：$DNS_CSV"
}

restore_system_dns() {
  if [ -f /etc/systemd/resolved.conf.d/vps-out-switch.conf ]; then
    rm -f /etc/systemd/resolved.conf.d/vps-out-switch.conf
    if [ -f "$STATE_DIR/resolved.conf.backup" ]; then
      cp -a "$STATE_DIR/resolved.conf.backup" /etc/systemd/resolved.conf.d/vps-out-switch.conf
    fi
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  if [ -f "$STATE_DIR/resolv.conf.backup" ]; then
    cp -a "$STATE_DIR/resolv.conf.backup" /etc/resolv.conf || true
  fi
  rm -f "$STATE_DIR/dns-mode"
}

prompt_wg_allowed_ips() {
  local choice custom
  info "请选择 WireGuard 路由范围："
  echo " 1. 全局出口：0.0.0.0/0, ::/0"
  echo " 2. 仅指定 CIDR 走 WG：适合 IP 段分流，原生 WG 不支持域名分流"
  echo " 3. 只走 IPv4 全局：0.0.0.0/0"
  read -r -p "输入序号，默认 1：" choice || true
  choice="${choice:-1}"
  case "$choice" in
    1) WG_ALLOWED_IPS="0.0.0.0/0, ::/0" ;;
    2)
      read -r -p "输入 CIDR，逗号分隔，例如 1.2.3.0/24, 2001:db8::/32：" custom
      [ -n "$custom" ] || die "CIDR 不能为空"
      WG_ALLOWED_IPS="$custom"
      ;;
    3) WG_ALLOWED_IPS="0.0.0.0/0" ;;
    *) die "WireGuard 路由范围选择无效" ;;
  esac
}

format_wg_endpoint() {
  local host="$1" port="$2"
  host="$(strip_brackets "$host")"
  if is_ipv6 "$host"; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

route_add_cmd_for_ip() {
  local ip="$1" cidr iface gw
  cidr="$(cidr_for_ip "$ip")"
  if is_ipv6 "$ip"; then
    iface="$(get_default_iface6)"
    gw="$(get_default_gw6)"
    [ -n "$iface" ] || return 0
    if [ -n "$gw" ]; then
      printf 'ip -6 route replace %s via %s dev %s 2>/dev/null || true' "$cidr" "$gw" "$iface"
    else
      printf 'ip -6 route replace %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    fi
  else
    iface="$(get_default_iface4)"
    gw="$(get_default_gw4)"
    [ -n "$iface" ] || return 0
    if [ -n "$gw" ]; then
      printf 'ip route replace %s via %s dev %s 2>/dev/null || true' "$cidr" "$gw" "$iface"
    else
      printf 'ip route replace %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    fi
  fi
}

route_del_cmd_for_ip() {
  local ip="$1" cidr
  cidr="$(cidr_for_ip "$ip")"
  if is_ipv6 "$ip"; then
    printf 'ip -6 route del %s 2>/dev/null || true' "$cidr"
  else
    printf 'ip route del %s 2>/dev/null || true' "$cidr"
  fi
}

route_add_cmd_for_iface() {
  local cidr="$1" iface="$2" metric="${3:-}"
  if [[ "$cidr" == *:* ]]; then
    if [ -n "$metric" ]; then
      printf 'ip -6 route replace %s dev %s metric %s 2>/dev/null || true' "$cidr" "$iface" "$metric"
    else
      printf 'ip -6 route replace %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    fi
  else
    if [ -n "$metric" ]; then
      printf 'ip route replace %s dev %s metric %s 2>/dev/null || true' "$cidr" "$iface" "$metric"
    else
      printf 'ip route replace %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    fi
  fi
}

route_del_cmd_for_cidr() {
  local cidr="$1" iface="${2:-}" metric="${3:-}"
  if [[ "$cidr" == *:* ]]; then
    if [ -n "$iface" ] && [ -n "$metric" ]; then
      printf 'ip -6 route del %s dev %s metric %s 2>/dev/null || true' "$cidr" "$iface" "$metric"
    elif [ -n "$iface" ]; then
      printf 'ip -6 route del %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    else
      printf 'ip -6 route del %s 2>/dev/null || true' "$cidr"
    fi
  else
    if [ -n "$iface" ] && [ -n "$metric" ]; then
      printf 'ip route del %s dev %s metric %s 2>/dev/null || true' "$cidr" "$iface" "$metric"
    elif [ -n "$iface" ]; then
      printf 'ip route del %s dev %s 2>/dev/null || true' "$cidr" "$iface"
    else
      printf 'ip route del %s 2>/dev/null || true' "$cidr"
    fi
  fi
}

append_wg_interface_line() {
  local file="$1" line="$2" tmp
  grep -Fqx "$line" "$file" 2>/dev/null && return
  tmp="$(mktemp)"
  awk -v insert="$line" '
    BEGIN {done=0}
    /^\[Peer\]/ && !done {print insert; done=1}
    {print}
    END {if(!done) print insert}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

set_wg_interface_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN {iniface=0; changed=0; saw_iface=0}
    /^\[Interface\]/ {iniface=1; print; next}
    /^\[/ && $0 !~ /^\[Interface\]/ {
      if (iniface && !changed) {
        print key " = " value
        changed=1
      }
      iniface=0
    }
    iniface && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print key " = " value
      changed=1
      next
    }
    {print}
    END {
      if (iniface && !changed) {
        print key " = " value
      }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

ensure_wg_dns_line() {
  local file="$1" tmp
  if grep -Eq '^[[:space:]]*DNS[[:space:]]*=' "$file"; then
    sed -i.bak -E "s|^[[:space:]]*DNS[[:space:]]*=.*|DNS = $DNS_CSV|" "$file"
    return
  fi
  tmp="$(mktemp)"
  awk -v dns="DNS = $DNS_CSV" '
    BEGIN {iniface=0; done=0}
    /^\[Interface\]/ {iniface=1; print; next}
    /^\[/ && $0 !~ /^\[Interface\]/ {
      if (iniface && !done) {
        print dns
        done=1
      }
      iniface=0
    }
    {print}
    END {
      if (iniface && !done) {
        print dns
      }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

remove_wg_interface_hooks() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk '
    /^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ {next}
    {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

set_wg_allowed_ips() {
  local file="$1" allowed="$2" tmp
  tmp="$(mktemp)"
  awk -v allowed="$allowed" '
    BEGIN {inpeer=0; changed=0}
    /^\[Peer\]/ {inpeer=1; print; next}
    /^\[/ && $0 !~ /^\[Peer\]/ {
      if (inpeer && !changed) {
        print "AllowedIPs = " allowed
        changed=1
      }
      inpeer=0
    }
    inpeer && /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
      print "AllowedIPs = " allowed
      changed=1
      next
    }
    {print}
    END {
      if (inpeer && !changed) {
        print "AllowedIPs = " allowed
      }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

set_wg_peer_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN {inpeer=0; changed=0}
    /^\[Peer\]/ {inpeer=1; print; next}
    /^\[/ && $0 !~ /^\[Peer\]/ {
      if (inpeer && !changed) {
        print key " = " value
        changed=1
      }
      inpeer=0
    }
    inpeer && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      print key " = " value
      changed=1
      next
    }
    {print}
    END {
      if (inpeer && !changed) {
        print key " = " value
      }
    }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

add_hybrid_wg_routes() {
  local file="$1"
  write_hybrid_wg_routes_script
  append_wg_interface_line "$file" "PostUp = $HYBRID_WG_RULES_SCRIPT up"
  append_wg_interface_line "$file" "PostDown = $HYBRID_WG_RULES_SCRIPT down"
}

write_hybrid_wg_routes_script() {
  cat > "$HYBRID_WG_RULES_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ACTION="\${1:-up}"
WG_IFACE="$WG_CLIENT_IFACE"
TABLE="$HYBRID_ROUTE_TABLE"
PREF="$HYBRID_ROUTE_PREF"
MARK="$HYBRID_ROUTE_MARK"

if [ "\$ACTION" = "down" ]; then
  ip rule del pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
  ip -6 rule del pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
  ip route flush table "\$TABLE" >/dev/null 2>&1 || true
  ip -6 route flush table "\$TABLE" >/dev/null 2>&1 || true
  exit 0
fi

ip route replace default dev "\$WG_IFACE" table "\$TABLE" >/dev/null 2>&1 || true
ip -6 route replace default dev "\$WG_IFACE" table "\$TABLE" >/dev/null 2>&1 || true
ip rule del pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
ip -6 rule del pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
ip rule add pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
ip -6 rule add pref "\$PREF" fwmark "\$MARK" lookup "\$TABLE" >/dev/null 2>&1 || true
EOF
  chmod 755 "$HYBRID_WG_RULES_SCRIPT"
}

prepare_wg_conf_for_hybrid() {
  local file="$1" endpoint_host="${2:-}"
  ensure_wg_dns_line "$file"
  set_wg_allowed_ips "$file" "0.0.0.0/0, ::/0"
  set_wg_peer_key "$file" "PersistentKeepalive" "25"
  set_wg_interface_key "$file" "Table" "off"
  remove_wg_interface_hooks "$file"
  add_wg_preserve_routes "$file" "$endpoint_host"
  add_hybrid_wg_routes "$file"
}

add_wg_preserve_routes() {
  local file="$1" endpoint_host="${2:-}" ssh_ip endpoint_ip add_cmd del_cmd
  ssh_ip="$(get_ssh_client_ip)"
  if [ -n "$ssh_ip" ] && is_ip_literal "$ssh_ip"; then
    add_cmd="$(route_add_cmd_for_ip "$ssh_ip")"
    del_cmd="$(route_del_cmd_for_ip "$ssh_ip")"
    [ -n "$add_cmd" ] && append_wg_interface_line "$file" "PreUp = $add_cmd"
    [ -n "$del_cmd" ] && append_wg_interface_line "$file" "PostDown = $del_cmd"
  fi

  endpoint_host="$(strip_brackets "$endpoint_host")"
  if [ -n "$endpoint_host" ] && is_ip_literal "$endpoint_host"; then
    endpoint_ip="$endpoint_host"
  else
    endpoint_ip="$(resolve_first_ip "$endpoint_host" || true)"
  fi
  if [ -n "$endpoint_ip" ] && is_ip_literal "$endpoint_ip"; then
    add_cmd="$(route_add_cmd_for_ip "$endpoint_ip")"
    del_cmd="$(route_del_cmd_for_ip "$endpoint_ip")"
    [ -n "$add_cmd" ] && append_wg_interface_line "$file" "PreUp = $add_cmd"
    [ -n "$del_cmd" ] && append_wg_interface_line "$file" "PostDown = $del_cmd"
  fi
}

detect_container_cidrs_csv() {
  local cidrs
  cidrs="$(ip -4 route show 2>/dev/null | awk '$3 ~ /^(incusbr|lxdbr|docker|podman|cni|br-)/ {print $1}' | line_list_to_csv)"
  printf '%s' "$cidrs"
}

write_wg_client_rules_script() {
  local wan_iface="${WAN_IFACE:-}" container_cidrs="${WG_CONTAINER_CIDRS:-}"
  if [ -z "$wan_iface" ]; then
    wan_iface="$(get_default_iface4)"
  fi
  if [ -z "$container_cidrs" ]; then
    container_cidrs="$(detect_container_cidrs_csv)"
  fi
  cat > "$WG_CLIENT_RULES_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ACTION="\${1:-up}"
WG_IFACE="${WG_CLIENT_IFACE}"
WAN_IFACE="$wan_iface"
CONTAINER_CIDRS="$container_cidrs"
TABLE_INET="vps_out_wg_client"
TABLE_IP="vps_out_wg_client_nat"
INBOUND_MARK="0x114"
RULE_PREF="114"

if [ "\$ACTION" = "down" ]; then
  nft delete table inet "\$TABLE_INET" >/dev/null 2>&1 || true
  nft delete table ip "\$TABLE_IP" >/dev/null 2>&1 || true
  ip rule del pref "\$RULE_PREF" fwmark "\$INBOUND_MARK" lookup main >/dev/null 2>&1 || true
  exit 0
fi

command -v nft >/dev/null 2>&1 || exit 0
[ -n "\$WG_IFACE" ] || exit 0

ip rule del pref "\$RULE_PREF" fwmark "\$INBOUND_MARK" lookup main >/dev/null 2>&1 || true
ip rule add pref "\$RULE_PREF" fwmark "\$INBOUND_MARK" lookup main >/dev/null 2>&1 || true
nft delete table inet "\$TABLE_INET" >/dev/null 2>&1 || true
nft delete table ip "\$TABLE_IP" >/dev/null 2>&1 || true

nft add table inet "\$TABLE_INET" >/dev/null 2>&1 || true
nft add chain inet "\$TABLE_INET" prerouting '{ type filter hook prerouting priority mangle; policy accept; }' >/dev/null 2>&1 || true
nft add chain inet "\$TABLE_INET" output '{ type route hook output priority mangle; policy accept; }' >/dev/null 2>&1 || true
if [ -n "\$WAN_IFACE" ]; then
  nft add rule inet "\$TABLE_INET" prerouting iifname "\$WAN_IFACE" ct mark set "\$INBOUND_MARK" meta mark set "\$INBOUND_MARK" >/dev/null 2>&1 || true
  nft add rule inet "\$TABLE_INET" output ct mark "\$INBOUND_MARK" meta mark set "\$INBOUND_MARK" >/dev/null 2>&1 || true
fi

nft add table ip "\$TABLE_IP" >/dev/null 2>&1 || true
nft add chain ip "\$TABLE_IP" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' >/dev/null 2>&1 || true
printf '%s\n' "\$CONTAINER_CIDRS" | tr ',' '\n' | while read -r cidr; do
  cidr="\$(printf '%s' "\$cidr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "\$cidr" ] || continue
  nft add rule ip "\$TABLE_IP" postrouting oifname "\$WG_IFACE" ip saddr \$cidr masquerade >/dev/null 2>&1 || true
done
EOF
  chmod 755 "$WG_CLIENT_RULES_SCRIPT"
}

add_wg_client_rules_hooks() {
  local file="$1"
  write_wg_client_rules_script
  append_wg_interface_line "$file" "PostUp = $WG_CLIENT_RULES_SCRIPT up"
  append_wg_interface_line "$file" "PostDown = $WG_CLIENT_RULES_SCRIPT down"
}

deploy_wg_client_manual() {
  local client_private client_public address4 address6 address_line server_public psk endpoint_host endpoint_port endpoint mtu
  read -r -p "客户端私钥（留空自动生成）：" client_private
  if [ -z "$client_private" ]; then
    client_private="$(wg genkey)"
  fi
  client_public="$(printf '%s' "$client_private" | wg pubkey)"

  read -r -p "客户端隧道 IPv4，默认 10.66.0.2/32：" address4
  address4="${address4:-10.66.0.2/32}"
  read -r -p "客户端隧道 IPv6，可留空，默认 fd42:42:42::2/128：" address6
  address6="${address6:-fd42:42:42::2/128}"
  if [ -n "$address6" ]; then
    address_line="$address4, $address6"
  else
    address_line="$address4"
  fi

  read -r -p "服务端公钥：" server_public
  [ -n "$server_public" ] || die "服务端公钥不能为空"
  read -r -p "服务端地址（IP/域名）：" endpoint_host
  read -r -p "服务端 UDP 端口，默认 51820：" endpoint_port
  endpoint_port="${endpoint_port:-51820}"
  validate_port "$endpoint_port" || die "服务端端口无效"
  endpoint="$(format_wg_endpoint "$endpoint_host" "$endpoint_port")"
  read -r -p "预共享密钥 PresharedKey（没有就留空）：" psk
  read -r -p "MTU，默认 1420：" mtu
  mtu="${mtu:-1420}"
  prompt_wg_allowed_ips

  cat > "$WG_CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $client_private
Address = $address_line
DNS = $DNS_CSV
MTU = $mtu

[Peer]
PublicKey = $server_public
Endpoint = $endpoint
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF
  if [ -n "$psk" ]; then
    sed -i "/^PublicKey = /a PresharedKey = $psk" "$WG_CLIENT_CONF"
  fi
  chmod 600 "$WG_CLIENT_CONF"
  add_wg_preserve_routes "$WG_CLIENT_CONF" "$endpoint_host"
  add_wg_client_rules_hooks "$WG_CLIENT_CONF"
  ok "客户端公钥：$client_public"
  warn "如果服务端还没添加这个客户端，请把上面的客户端公钥加入服务端 Peer。"
}

deploy_wg_client_import() {
  local src endpoint_host
  read -r -p "输入已有 wg-quick 配置文件路径：" src
  [ -f "$src" ] || die "配置文件不存在：$src"
  cp -a "$src" "$WG_CLIENT_CONF"
  chmod 600 "$WG_CLIENT_CONF"
  ensure_wg_dns_line "$WG_CLIENT_CONF"
  prompt_wg_allowed_ips
  set_wg_allowed_ips "$WG_CLIENT_CONF" "$WG_ALLOWED_IPS"
  set_wg_peer_key "$WG_CLIENT_CONF" "PersistentKeepalive" "25"
  read -r -p "服务端地址用于 SSH 保活路由（IP/域名，可留空）：" endpoint_host
  add_wg_preserve_routes "$WG_CLIENT_CONF" "$endpoint_host"
  add_wg_client_rules_hooks "$WG_CLIENT_CONF"
}

deploy_hybrid_wg_client_manual() {
  local client_private client_public address4 address6 address_line server_public psk endpoint_host endpoint_port endpoint mtu
  read -r -p "客户端私钥（留空自动生成）：" client_private
  if [ -z "$client_private" ]; then
    client_private="$(wg genkey)"
  fi
  client_public="$(printf '%s' "$client_private" | wg pubkey)"

  read -r -p "客户端隧道 IPv4，默认 10.66.0.2/32：" address4
  address4="${address4:-10.66.0.2/32}"
  read -r -p "客户端隧道 IPv6，可留空，默认 fd42:42:42::2/128：" address6
  address6="${address6:-fd42:42:42::2/128}"
  if [ -n "$address6" ]; then
    address_line="$address4, $address6"
  else
    address_line="$address4"
  fi

  read -r -p "服务端公钥：" server_public
  [ -n "$server_public" ] || die "服务端公钥不能为空"
  read -r -p "服务端地址（IP/域名）：" endpoint_host
  [ -n "$endpoint_host" ] || die "服务端地址不能为空"
  read -r -p "服务端 UDP 端口，默认 51820：" endpoint_port
  endpoint_port="${endpoint_port:-51820}"
  validate_port "$endpoint_port" || die "服务端端口无效"
  endpoint="$(format_wg_endpoint "$endpoint_host" "$endpoint_port")"
  read -r -p "预共享密钥 PresharedKey（没有就留空）：" psk
  read -r -p "MTU，默认 1420：" mtu
  mtu="${mtu:-1420}"

  cat > "$WG_CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $client_private
Address = $address_line
DNS = $DNS_CSV
MTU = $mtu

[Peer]
PublicKey = $server_public
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  if [ -n "$psk" ]; then
    sed -i "/^PublicKey = /a PresharedKey = $psk" "$WG_CLIENT_CONF"
  fi
  chmod 600 "$WG_CLIENT_CONF"
  prepare_wg_conf_for_hybrid "$WG_CLIENT_CONF" "$endpoint_host"
  ok "客户端公钥：$client_public"
  warn "如果服务端还没有添加这个客户端，请把上面的客户端公钥加入服务端 Peer。"
}

deploy_hybrid_wg_client_import() {
  local src endpoint_host
  read -r -p "输入已有 wg-quick 配置文件路径：" src
  [ -f "$src" ] || die "配置文件不存在：$src"
  cp -a "$src" "$WG_CLIENT_CONF"
  chmod 600 "$WG_CLIENT_CONF"
  endpoint_host="$(get_wg_endpoint_host_from_conf "$WG_CLIENT_CONF" || true)"
  if [ -z "$endpoint_host" ]; then
    read -r -p "未在配置中解析到 Endpoint，请输入服务端地址（IP/域名）：" endpoint_host
  fi
  prepare_wg_conf_for_hybrid "$WG_CLIENT_CONF" "$endpoint_host"
}

deploy_hybrid_wg_client_existing() {
  local endpoint_host
  [ -f "$WG_CLIENT_CONF" ] || die "未找到当前 WG 客户端配置：$WG_CLIENT_CONF"
  endpoint_host="$(get_wg_endpoint_host_from_conf "$WG_CLIENT_CONF" || true)"
  if [ -z "$endpoint_host" ]; then
    read -r -p "未在当前配置中解析到 Endpoint，请输入服务端地址（IP/域名）：" endpoint_host
  fi
  prepare_wg_conf_for_hybrid "$WG_CLIENT_CONF" "$endpoint_host"
}

deploy_wg_client_mode() {
  local choice stale_addrs
  safe_clear
  need_root
  need_systemd
  ensure_dirs
  info "开始部署 WireGuard 客户端出口模式。"
  warn "说明：原生 WireGuard 只适合按 IP/CIDR 分流；如果你需要域名分流，请优先使用 sing-box+nftables 模式。"
  ensure_wg_tools
  enable_kernel_features
  info "正在停止现有 WireGuard 客户端，避免旧配置路由残留..."
  disable_watchdog
  stop_wg_client_mode
  auto_select_wan_iface

  echo " 1. 手动输入 WireGuard 参数"
  echo " 2. 导入已有 wg-quick 配置文件"
  read -r -p "输入序号，默认 1：" choice || true
  choice="${choice:-1}"
  case "$choice" in
    1) deploy_wg_client_manual ;;
    2) deploy_wg_client_import ;;
    *) die "WireGuard 客户端模式选择无效" ;;
  esac

  if confirm "是否写入系统 DNS 为 Cloudflare/Google？WG 配置内已写入 DNS 行。" "Y"; then
    apply_system_dns
  fi

  info "正在切换出口模式..."
  stale_addrs="$(collect_managed_iface_addrs)"
  stop_singbox_mode
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_CLIENT_IFACE}"
  write_active_mode "WireGuard 客户端"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "部署完成。当前模式：WireGuard 客户端"
  show_status_brief
  pause
}

deploy_hybrid_mode() {
  local choice stale_addrs
  safe_clear
  need_root
  need_systemd
  ensure_dirs
  info "开始部署混合模式：sing-box 负责透明代理和域名/CIDR 分流，WireGuard 作为代理出口。"
  warn "此模式适合你拥有出口 VPS 控制权、入口机承载多台 LXC/Incus 容器，并且仍需要域名分流的场景。"
  ensure_wg_tools
  enable_kernel_features
  install_singbox_binary
  info "正在停止现有 WireGuard 客户端，避免旧配置路由残留..."
  disable_watchdog
  stop_wg_client_mode
  select_wan_iface

  echo "请选择 WireGuard 客户端配置来源："
  echo " 1. 手动输入 WireGuard 参数"
  echo " 2. 导入已有 wg-quick 配置文件"
  echo " 3. 复用当前 $WG_CLIENT_CONF"
  read -r -p "输入序号，默认 3：" choice || true
  choice="${choice:-3}"
  case "$choice" in
    1) deploy_hybrid_wg_client_manual ;;
    2) deploy_hybrid_wg_client_import ;;
    3) deploy_hybrid_wg_client_existing ;;
    *) die "WireGuard 配置来源选择无效" ;;
  esac

  prompt_singbox_split

  info "正在生成混合模式 sing-box 配置..."
  build_hybrid_singbox_config
  write_singbox_service
  write_singbox_container_bypass

  if confirm "是否同时写入系统 DNS 为 Cloudflare/Google？sing-box 内部 DNS 已经固定为这些地址。" "N"; then
    apply_system_dns
  fi

  info "正在切换到混合模式..."
  stale_addrs="$(collect_managed_iface_addrs)"
  stop_singbox_mode
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_CLIENT_IFACE}"
  if ! ip link show "$WG_CLIENT_IFACE" >/dev/null 2>&1; then
    journalctl -u "wg-quick@${WG_CLIENT_IFACE}" -n 40 --no-pager 2>/dev/null || true
    die "WireGuard 客户端接口 $WG_CLIENT_IFACE 未启动，已停止切换"
  fi
  info "正在检查 sing-box 配置..."
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF" || die "sing-box 配置检查失败，已保留 WireGuard 运行状态以便排查"
  systemctl enable --now vps-out-singbox
  write_active_mode "$HYBRID_MODE_NAME"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "部署完成。当前模式：$HYBRID_MODE_NAME"
  show_status_brief
  pause
}

setup_wg_server_mode() {
  local port public_endpoint v4_prefix v6_prefix server_v4 server_v6 nat_v4 nat_v6 private_key public_key
  safe_clear
  need_root
  need_systemd
  ensure_dirs
  info "开始初始化本机为 WireGuard 出口 VPS。"
  warn "这个功能应在你拥有完整控制权的出口 VPS 上运行，不是在需要切换出口的客户端 VPS 上运行。"
  ensure_wg_tools
  enable_kernel_features
  select_wan_iface
  info "正在停止旧 WireGuard 服务端实例，避免旧配置继续运行..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${WG_SERVER_IFACE}" >/dev/null 2>&1 || true
  fi
  wg-quick down "$WG_SERVER_IFACE" >/dev/null 2>&1 || true

  read -r -p "WireGuard UDP 监听端口，默认 51820：" port
  port="${port:-51820}"
  validate_port "$port" || die "监听端口无效"
  read -r -p "服务端公网 IP/域名，默认自动探测：" public_endpoint
  public_endpoint="${public_endpoint:-$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  [ -n "$public_endpoint" ] || warn "未能自动探测公网地址，后续生成客户端时需要手动填写"

  read -r -p "客户端 IPv4 前缀前三段，默认 10.66.0：" v4_prefix
  v4_prefix="${v4_prefix:-10.66.0}"
  read -r -p "客户端 IPv6 前缀，默认 fd42:42:42::：" v6_prefix
  v6_prefix="${v6_prefix:-fd42:42:42::}"
  server_v4="${v4_prefix}.1/24"
  nat_v4="${v4_prefix}.0/24"
  server_v6="${v6_prefix}1/64"
  nat_v6="${v6_prefix}/64"

  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"

  cat > "$WG_SERVER_NFT" <<EOF
table inet vps_out_wg_filter {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$WG_SERVER_IFACE" oifname "$WAN_IFACE" accept
    iifname "$WAN_IFACE" oifname "$WG_SERVER_IFACE" ct state established,related accept
  }
}

table ip vps_out_wg_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN_IFACE" ip saddr $nat_v4 masquerade
  }
}

table ip6 vps_out_wg_nat6 {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN_IFACE" ip6 saddr $nat_v6 masquerade
  }
}
EOF

  cat > /etc/sysctl.d/99-vps-out-switch.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null

  cat > "$WG_SERVER_CONF" <<EOF
[Interface]
Address = $server_v4, $server_v6
ListenPort = $port
PrivateKey = $private_key
SaveConfig = false
PostUp = nft delete table inet vps_out_wg_filter 2>/dev/null || true; nft delete table ip vps_out_wg_nat 2>/dev/null || true; nft delete table ip6 vps_out_wg_nat6 2>/dev/null || true; nft -f $WG_SERVER_NFT
PostDown = nft delete table inet vps_out_wg_filter 2>/dev/null || true
PostDown = nft delete table ip vps_out_wg_nat 2>/dev/null || true
PostDown = nft delete table ip6 vps_out_wg_nat6 2>/dev/null || true
EOF
  chmod 600 "$WG_SERVER_CONF"

  {
    write_shell_env_value "SERVER_PUBLIC_KEY" "$public_key"
    write_shell_env_value "SERVER_ENDPOINT" "$public_endpoint"
    write_shell_env_value "SERVER_PORT" "$port"
    write_shell_env_value "CLIENT_V4_PREFIX" "$v4_prefix"
    write_shell_env_value "CLIENT_V6_PREFIX" "$v6_prefix"
    write_shell_env_value "NEXT_CLIENT_ID" "2"
  } > "$WG_SERVER_ENV"
  chmod 600 "$WG_SERVER_ENV"

  systemctl daemon-reload
  if ! systemctl enable --now "wg-quick@${WG_SERVER_IFACE}"; then
    journalctl -u "wg-quick@${WG_SERVER_IFACE}" -n 60 --no-pager 2>/dev/null || true
    die "WireGuard 出口服务端启动失败"
  fi
  ok "WireGuard 出口服务端已启动。"
  ok "服务端公钥：$public_key"
  warn "如果你的 VPS 开了云防火墙、安全组、ufw 或 firewalld，请放行 UDP $port。"
  pause
}

add_wg_server_peer() {
  local client_name client_id client_private client_public psk client_v4 client_v6 client_allowed client_allowed_wg client_file psk_file route_choice
  safe_clear
  need_root
  need_systemd
  ensure_dirs
  [ -f "$WG_SERVER_ENV" ] || die "未找到服务端状态，请先运行“初始化本机为 WireGuard 出口服务端”"
  # shellcheck disable=SC1090
  . "$WG_SERVER_ENV"

  read -r -p "客户端名称，只能用于文件名，默认 client${NEXT_CLIENT_ID}：" client_name
  client_name="${client_name:-client${NEXT_CLIENT_ID}}"
  [[ "$client_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "客户端名称只能包含字母、数字、点、下划线和短横线"
  if grep -Fq "# vps-out-switch peer: $client_name" "$WG_SERVER_CONF" 2>/dev/null; then
    die "服务端配置中已存在同名客户端：$client_name"
  fi
  client_id="$NEXT_CLIENT_ID"
  read -r -p "客户端 IPv4，默认 ${CLIENT_V4_PREFIX}.${client_id}/32：" client_v4
  client_v4="${client_v4:-${CLIENT_V4_PREFIX}.${client_id}/32}"
  read -r -p "客户端 IPv6，默认 ${CLIENT_V6_PREFIX}${client_id}/128：" client_v6
  client_v6="${client_v6:-${CLIENT_V6_PREFIX}${client_id}/128}"

  client_private="$(wg genkey)"
  client_public="$(printf '%s' "$client_private" | wg pubkey)"
  psk="$(wg genpsk)"
  client_allowed="$client_v4, $client_v6"
  client_allowed_wg="${client_allowed// /}"

  cat >> "$WG_SERVER_CONF" <<EOF

# vps-out-switch peer: $client_name
[Peer]
PublicKey = $client_public
PresharedKey = $psk
AllowedIPs = $client_allowed
EOF
  chmod 600 "$WG_SERVER_CONF"

  if ip link show "$WG_SERVER_IFACE" >/dev/null 2>&1; then
    psk_file="$(mktemp)"
    printf '%s\n' "$psk" > "$psk_file"
    wg set "$WG_SERVER_IFACE" peer "$client_public" preshared-key "$psk_file" allowed-ips "$client_allowed_wg"
    rm -f "$psk_file"
  else
    systemctl restart "wg-quick@${WG_SERVER_IFACE}"
  fi

  echo "客户端默认路由范围："
  echo " 1. 全局出口 0.0.0.0/0, ::/0"
  echo " 2. 仅 IPv4 全局 0.0.0.0/0"
  read -r -p "输入序号，默认 1：" route_choice || true
  route_choice="${route_choice:-1}"
  if [ "$route_choice" = "2" ]; then
    WG_ALLOWED_IPS="0.0.0.0/0"
  else
    WG_ALLOWED_IPS="0.0.0.0/0, ::/0"
  fi

  client_file="$CLIENT_DIR/${client_name}.conf"
  cat > "$client_file" <<EOF
[Interface]
PrivateKey = $client_private
Address = $client_allowed
DNS = $DNS_CSV

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $psk
Endpoint = $(format_wg_endpoint "$SERVER_ENDPOINT" "$SERVER_PORT")
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF
  chmod 600 "$client_file"

  NEXT_CLIENT_ID="$((client_id + 1))"
  {
    write_shell_env_value "SERVER_PUBLIC_KEY" "$SERVER_PUBLIC_KEY"
    write_shell_env_value "SERVER_ENDPOINT" "$SERVER_ENDPOINT"
    write_shell_env_value "SERVER_PORT" "$SERVER_PORT"
    write_shell_env_value "CLIENT_V4_PREFIX" "$CLIENT_V4_PREFIX"
    write_shell_env_value "CLIENT_V6_PREFIX" "$CLIENT_V6_PREFIX"
    write_shell_env_value "NEXT_CLIENT_ID" "$NEXT_CLIENT_ID"
  } > "$WG_SERVER_ENV"

  ok "客户端已添加：$client_name"
  ok "客户端配置文件：$client_file"
  pause
}

auto_select_wan_iface() {
  local default_iface detected_iface
  if [ -n "${VPS_OUT_WAN_IFACE:-}" ]; then
    WAN_IFACE="$VPS_OUT_WAN_IFACE"
    ok "已使用环境变量指定公网网卡：$WAN_IFACE"
    return
  fi

  default_iface="$(get_default_iface4)"
  case "$default_iface" in
    ""|lo|docker*|podman*|cni*|veth*|br-*|virbr*|tun*|wg*|vpsout*|tailscale*|zt*|incusbr*|lxdbr*) ;;
    *)
      WAN_IFACE="$default_iface"
      ok "已自动选择公网网卡：$WAN_IFACE"
      return
      ;;
  esac

  detected_iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo|docker|docker0|podman|podman0|cni|cni0|veth|br-|virbr|tun|wg|vpsout|tailscale|zt|incusbr|lxdbr)' | awk '!seen[$0]++ {print; exit}')"
  [ -n "$detected_iface" ] || die "未检测到可用的公网网卡，请设置 VPS_OUT_WAN_IFACE"
  WAN_IFACE="$detected_iface"
  ok "已自动选择公网网卡：$WAN_IFACE"
}

apply_auto_split_policy() {
  local mode="${VPS_OUT_SPLIT_MODE:-managed}"
  DIRECT_DOMAINS=""
  DIRECT_CIDRS=""
  PROXY_DOMAINS=""
  PROXY_CIDRS=""
  FINAL_OUTBOUND="proxy"

  case "$mode" in
    global)
      FINAL_OUTBOUND="proxy"
      ;;
    managed)
      apply_managed_split_policy
      ;;
    direct-default)
      FINAL_OUTBOUND="direct"
      DIRECT_DOMAINS="${VPS_OUT_DIRECT_DOMAINS:-}"
      DIRECT_CIDRS="${VPS_OUT_DIRECT_CIDRS:-}"
      PROXY_DOMAINS="${VPS_OUT_PROXY_DOMAINS:-}"
      PROXY_CIDRS="${VPS_OUT_PROXY_CIDRS:-}"
      ;;
    custom)
      FINAL_OUTBOUND="${VPS_OUT_FINAL_OUTBOUND:-proxy}"
      case "$FINAL_OUTBOUND" in proxy|direct) ;; *) die "VPS_OUT_FINAL_OUTBOUND 只能是 proxy 或 direct" ;; esac
      DIRECT_DOMAINS="${VPS_OUT_DIRECT_DOMAINS:-$DEFAULT_DIRECT_DOMAINS}"
      DIRECT_CIDRS="${VPS_OUT_DIRECT_CIDRS:-}"
      PROXY_DOMAINS="${VPS_OUT_PROXY_DOMAINS:-}"
      PROXY_CIDRS="${VPS_OUT_PROXY_CIDRS:-}"
      ;;
    *)
      die "VPS_OUT_SPLIT_MODE 无效：$mode，可用 managed/global/direct-default/custom"
      ;;
  esac
}

sanitize_unit_name_part() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_.-]+/-/g'
}

get_incus_ipv4() {
  local name="$1"
  incus list "$name" --format csv -c 4 2>/dev/null | head -n1 | awk '{print $1}'
}

ensure_socat_installed() {
  command -v socat >/dev/null 2>&1 && return
  local pm
  pm="$(detect_pm)" || die "未识别包管理器，请先手动安装 socat"
  install_pkg_list "$pm" socat
}

deploy_port_forward() {
  local listen_ip="$1" listen_port="$2" target_ip="$3" target_port="$4" name="$5"
  local safe_name unit record
  validate_port "$listen_port" || die "公网监听端口无效：$listen_port"
  validate_port "$target_port" || die "容器目标端口无效：$target_port"
  [ -n "$listen_ip" ] || die "公网监听 IP 不能为空"
  [ -n "$target_ip" ] || die "容器目标 IP 不能为空"
  safe_name="$(sanitize_unit_name_part "$name")"
  unit="/etc/systemd/system/vps-out-port-${safe_name}-${listen_port}.service"
  record="$PORT_FORWARD_DIR/${safe_name}-${listen_port}.env"
  ensure_socat_installed
  if [ -f "$unit" ]; then
    systemctl disable --now "$(basename "$unit")" >/dev/null 2>&1 || true
    systemctl reset-failed "$(basename "$unit")" >/dev/null 2>&1 || true
  fi

  cat > "$unit" <<EOF
[Unit]
Description=VPS Out Switch port forward ${listen_ip}:${listen_port} to ${target_ip}:${target_port}
After=network-online.target incus.service lxd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${listen_port},bind=${listen_ip},fork,reuseaddr TCP:${target_ip}:${target_port}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit"
  {
    write_shell_env_value "UNIT" "$unit"
    write_shell_env_value "LISTEN_IP" "$listen_ip"
    write_shell_env_value "LISTEN_PORT" "$listen_port"
    write_shell_env_value "TARGET_IP" "$target_ip"
    write_shell_env_value "TARGET_PORT" "$target_port"
    write_shell_env_value "NAME" "$name"
  } > "$record"
  chmod 600 "$record"
  systemctl daemon-reload
  systemctl enable --now "$(basename "$unit")"
  ok "端口转发已启用：${listen_ip}:${listen_port} -> ${target_ip}:${target_port}"
}

auto_deploy_port_forward() {
  local listen_ip listen_port target_ip target_port name container
  need_root
  need_systemd
  ensure_dirs
  listen_ip="${VPS_OUT_LISTEN_IP:-$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  listen_port="${VPS_OUT_LISTEN_PORT:-}"
  target_port="${VPS_OUT_TARGET_PORT:-$listen_port}"
  target_ip="${VPS_OUT_TARGET_IP:-}"
  container="${VPS_OUT_CONTAINER:-}"
  name="${VPS_OUT_FORWARD_NAME:-${container:-manual}}"
  [ -n "$listen_port" ] || die "请设置 VPS_OUT_LISTEN_PORT"
  if [ -z "$target_ip" ]; then
    [ -n "$container" ] || die "未设置 VPS_OUT_TARGET_IP 时必须设置 VPS_OUT_CONTAINER"
    target_ip="$(get_incus_ipv4 "$container")"
  fi
  deploy_port_forward "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$name"
}

manage_port_forwards() {
  local choice container listen_ip listen_port target_ip target_port name file
  ensure_dirs
  while true; do
    safe_clear
    echo "${BLUE}============================================================${NC}"
    echo "${BOLD}                 容器端口转发管理${NC}"
    echo "${BLUE}============================================================${NC}"
    echo "已记录的转发："
    if compgen -G "$PORT_FORWARD_DIR/*.env" >/dev/null; then
      for file in "$PORT_FORWARD_DIR"/*.env; do
        # shellcheck disable=SC1090
        . "$file"
        printf ' - %s:%s -> %s:%s  (%s)\n' "${LISTEN_IP:-}" "${LISTEN_PORT:-}" "${TARGET_IP:-}" "${TARGET_PORT:-}" "${NAME:-}"
      done
    else
      echo " - 暂无"
    fi
    echo
    echo " 1. 添加/覆盖 TCP 端口转发到 Incus/LXC 容器"
    echo " 0. 返回主菜单"
    echo "${BLUE}============================================================${NC}"
    read -r -p "请输入选项：" choice || true
    case "$choice" in
      1)
        read -r -p "容器名称：" container
        [ -n "$container" ] || die "容器名称不能为空"
        target_ip="$(get_incus_ipv4 "$container")"
        [ -n "$target_ip" ] || die "未检测到容器 IPv4：$container"
        read -r -p "公网监听 IP，默认自动检测：" listen_ip
        listen_ip="${listen_ip:-$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
        read -r -p "公网监听端口：" listen_port
        read -r -p "容器目标端口，默认同公网端口：" target_port
        target_port="${target_port:-$listen_port}"
        name="$container"
        deploy_port_forward "$listen_ip" "$listen_port" "$target_ip" "$target_port" "$name"
        pause
        ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

configure_auto_singbox_node() {
  local kind="${VPS_OUT_PROXY_KIND:-}" parsed

  if [ -n "${VPS_OUT_SS_URI:-}" ]; then
    PROXY_KIND="shadowsocks"
    parsed="$(parse_ss_uri "$VPS_OUT_SS_URI" 2>/dev/null)" || die "解析 VPS_OUT_SS_URI 失败"
    eval "$parsed"
    ok "已解析 Shadowsocks 节点：$PROXY_ADDR:$PROXY_PORT / $SS_METHOD"
    return
  fi

  case "$kind" in
    socks)
      PROXY_KIND="socks"
      PROXY_ADDR="${VPS_OUT_PROXY_ADDR:-}"
      PROXY_PORT="${VPS_OUT_PROXY_PORT:-}"
      PROXY_USER="${VPS_OUT_PROXY_USER:-}"
      PROXY_PASS="${VPS_OUT_PROXY_PASS:-}"
      ;;
    shadowsocks)
      PROXY_KIND="shadowsocks"
      PROXY_ADDR="${VPS_OUT_PROXY_ADDR:-}"
      PROXY_PORT="${VPS_OUT_PROXY_PORT:-}"
      SS_METHOD="${VPS_OUT_SS_METHOD:-aes-256-gcm}"
      PROXY_PASS="${VPS_OUT_PROXY_PASS:-}"
      ;;
    *)
      die "请设置 VPS_OUT_SS_URI，或设置 VPS_OUT_PROXY_KIND=socks|shadowsocks 及对应节点参数"
      ;;
  esac

  [ -n "${PROXY_ADDR:-}" ] || die "节点地址不能为空"
  validate_port "${PROXY_PORT:-}" || die "节点端口无效"
  if [ "$PROXY_KIND" = "shadowsocks" ]; then
    [ -n "${PROXY_PASS:-}" ] || die "Shadowsocks 密码不能为空"
  fi
}

auto_deploy_singbox_mode() {
  local stale_addrs
  need_root
  need_systemd
  ensure_dirs
  init_split_policy
  info "自动部署 sing-box + nftables 出口模式..."
  ensure_common_tools
  enable_kernel_features
  install_singbox_binary
  auto_select_wan_iface
  configure_auto_singbox_node
  apply_auto_split_policy

  build_singbox_config
  write_singbox_service
  write_singbox_container_bypass
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF" || die "sing-box 配置检查失败"

  disable_watchdog
  stale_addrs="$(collect_managed_iface_addrs)"
  stop_client_modes
  systemctl daemon-reload
  systemctl enable --now vps-out-singbox
  write_active_mode "sing-box+nftables"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "sing-box + nftables 自动部署完成。"
  show_status_brief
}

remove_wg_interface_key() {
  local file="$1" key="$2" tmp
  tmp="$(mktemp)"
  awk -v key="$key" '
    BEGIN {iniface=0}
    /^\[Interface\]/ {iniface=1; print; next}
    /^\[/ && $0 !~ /^\[Interface\]/ {iniface=0}
    iniface && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {next}
    {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

copy_wg_conf_if_needed() {
  local src="$1"
  [ -f "$src" ] || die "指定的 WG 配置不存在：$src"
  if [ "$(readlink -f "$src")" != "$(readlink -f "$WG_CLIENT_CONF" 2>/dev/null || printf '%s' "$WG_CLIENT_CONF")" ]; then
    cp -a "$src" "$WG_CLIENT_CONF"
  fi
  chmod 600 "$WG_CLIENT_CONF"
}

auto_deploy_wg_client_mode() {
  local src endpoint_host allowed stale_addrs
  need_root
  need_systemd
  ensure_dirs
  info "自动部署 WireGuard 客户端出口模式..."
  ensure_wg_tools
  enable_kernel_features

  disable_watchdog
  stop_wg_client_mode
  auto_select_wan_iface
  src="${VPS_OUT_WG_CONF_SOURCE:-}"
  if [ -n "$src" ]; then
    copy_wg_conf_if_needed "$src"
  fi
  [ -f "$WG_CLIENT_CONF" ] || die "未找到 WG 客户端配置：$WG_CLIENT_CONF，请设置 VPS_OUT_WG_CONF_SOURCE"

  endpoint_host="${VPS_OUT_WG_ENDPOINT_HOST:-$(get_wg_endpoint_host_from_conf "$WG_CLIENT_CONF" || true)}"
  allowed="${VPS_OUT_WG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
  if [ -n "$(detect_container_cidrs_csv)" ] && [ "$allowed" != "0.0.0.0/0, ::/0" ] && [ "$allowed" != "0.0.0.0/0" ]; then
    warn "检测到容器网段，但当前 WireGuard AllowedIPs 不是全局。容器内对外提供代理节点时，窄 CIDR 分流会导致节点出站不可用。"
  fi
  ensure_wg_dns_line "$WG_CLIENT_CONF"
  remove_wg_interface_hooks "$WG_CLIENT_CONF"
  remove_wg_interface_key "$WG_CLIENT_CONF" "Table"
  set_wg_allowed_ips "$WG_CLIENT_CONF" "$allowed"
  set_wg_peer_key "$WG_CLIENT_CONF" "PersistentKeepalive" "25"
  add_wg_preserve_routes "$WG_CLIENT_CONF" "$endpoint_host"
  add_wg_client_rules_hooks "$WG_CLIENT_CONF"

  stale_addrs="$(collect_managed_iface_addrs)"
  stop_singbox_mode
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_CLIENT_IFACE}"
  ip link show "$WG_CLIENT_IFACE" >/dev/null 2>&1 || die "WireGuard 客户端接口 $WG_CLIENT_IFACE 未启动"
  write_active_mode "WireGuard 客户端"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "WireGuard 客户端自动部署完成。"
  show_status_brief
}

auto_setup_wg_server_mode() {
  local port public_endpoint v4_prefix v6_prefix server_v4 server_v6 nat_v4 nat_v6 private_key public_key
  need_root
  need_systemd
  ensure_dirs
  info "自动初始化本机为 WireGuard 出口服务端..."
  ensure_wg_tools
  enable_kernel_features
  auto_select_wan_iface

  port="${VPS_OUT_WG_PORT:-51820}"
  validate_port "$port" || die "监听端口无效：$port"
  public_endpoint="${VPS_OUT_PUBLIC_ENDPOINT:-$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  [ -n "$public_endpoint" ] || die "未能自动检测公网地址，请设置 VPS_OUT_PUBLIC_ENDPOINT"
  v4_prefix="${VPS_OUT_WG_V4_PREFIX:-10.66.0}"
  v6_prefix="${VPS_OUT_WG_V6_PREFIX:-fd42:42:42::}"
  server_v4="${v4_prefix}.1/24"
  nat_v4="${v4_prefix}.0/24"
  server_v6="${v6_prefix}1/64"
  nat_v6="${v6_prefix}/64"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${WG_SERVER_IFACE}" >/dev/null 2>&1 || true
  fi
  wg-quick down "$WG_SERVER_IFACE" >/dev/null 2>&1 || true

  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"

  cat > "$WG_SERVER_NFT" <<EOF
table inet vps_out_wg_filter {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$WG_SERVER_IFACE" oifname "$WAN_IFACE" accept
    iifname "$WAN_IFACE" oifname "$WG_SERVER_IFACE" ct state established,related accept
  }
}

table ip vps_out_wg_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN_IFACE" ip saddr $nat_v4 masquerade
  }
}

table ip6 vps_out_wg_nat6 {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN_IFACE" ip6 saddr $nat_v6 masquerade
  }
}
EOF

  cat > /etc/sysctl.d/99-vps-out-switch.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null

  cat > "$WG_SERVER_CONF" <<EOF
[Interface]
Address = $server_v4, $server_v6
ListenPort = $port
PrivateKey = $private_key
SaveConfig = false
PostUp = nft delete table inet vps_out_wg_filter 2>/dev/null || true; nft delete table ip vps_out_wg_nat 2>/dev/null || true; nft delete table ip6 vps_out_wg_nat6 2>/dev/null || true; nft -f $WG_SERVER_NFT
PostDown = nft delete table inet vps_out_wg_filter 2>/dev/null || true
PostDown = nft delete table ip vps_out_wg_nat 2>/dev/null || true
PostDown = nft delete table ip6 vps_out_wg_nat6 2>/dev/null || true
EOF
  chmod 600 "$WG_SERVER_CONF"

  {
    write_shell_env_value "SERVER_PUBLIC_KEY" "$public_key"
    write_shell_env_value "SERVER_ENDPOINT" "$public_endpoint"
    write_shell_env_value "SERVER_PORT" "$port"
    write_shell_env_value "CLIENT_V4_PREFIX" "$v4_prefix"
    write_shell_env_value "CLIENT_V6_PREFIX" "$v6_prefix"
    write_shell_env_value "NEXT_CLIENT_ID" "2"
  } > "$WG_SERVER_ENV"
  chmod 600 "$WG_SERVER_ENV"

  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_SERVER_IFACE}"
  ok "WireGuard 出口服务端已启动。"
  ok "服务端公钥：$public_key"
  ok "服务端地址：$(format_wg_endpoint "$public_endpoint" "$port")"
}

auto_add_wg_server_peer() {
  local client_name client_id client_private client_public psk client_v4 client_v6 client_allowed client_allowed_wg client_file psk_file route_mode
  need_root
  need_systemd
  ensure_dirs
  [ -f "$WG_SERVER_ENV" ] || die "未找到服务端状态，请先运行 --auto-setup-wg-server"
  # shellcheck disable=SC1090
  . "$WG_SERVER_ENV"

  client_name="${VPS_OUT_CLIENT_NAME:-client${NEXT_CLIENT_ID}}"
  [[ "$client_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "客户端名称只能包含字母、数字、点、下划线和短横线"
  if grep -Fq "# vps-out-switch peer: $client_name" "$WG_SERVER_CONF" 2>/dev/null; then
    die "服务端配置中已存在同名客户端：$client_name"
  fi
  client_id="${VPS_OUT_CLIENT_ID:-$NEXT_CLIENT_ID}"
  client_v4="${VPS_OUT_CLIENT_V4:-${CLIENT_V4_PREFIX}.${client_id}/32}"
  client_v6="${VPS_OUT_CLIENT_V6:-${CLIENT_V6_PREFIX}${client_id}/128}"
  client_private="$(wg genkey)"
  client_public="$(printf '%s' "$client_private" | wg pubkey)"
  psk="$(wg genpsk)"
  client_allowed="$client_v4, $client_v6"
  client_allowed_wg="${client_allowed// /}"

  cat >> "$WG_SERVER_CONF" <<EOF

# vps-out-switch peer: $client_name
[Peer]
PublicKey = $client_public
PresharedKey = $psk
AllowedIPs = $client_allowed
EOF
  chmod 600 "$WG_SERVER_CONF"

  if ip link show "$WG_SERVER_IFACE" >/dev/null 2>&1; then
    psk_file="$(mktemp)"
    printf '%s\n' "$psk" > "$psk_file"
    wg set "$WG_SERVER_IFACE" peer "$client_public" preshared-key "$psk_file" allowed-ips "$client_allowed_wg"
    rm -f "$psk_file"
  else
    systemctl restart "wg-quick@${WG_SERVER_IFACE}"
  fi

  route_mode="${VPS_OUT_CLIENT_ROUTE:-dual}"
  if [ "$route_mode" = "ipv4" ]; then
    WG_ALLOWED_IPS="0.0.0.0/0"
  else
    WG_ALLOWED_IPS="0.0.0.0/0, ::/0"
  fi

  client_file="$CLIENT_DIR/${client_name}.conf"
  cat > "$client_file" <<EOF
[Interface]
PrivateKey = $client_private
Address = $client_allowed
DNS = $DNS_CSV

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $psk
Endpoint = $(format_wg_endpoint "$SERVER_ENDPOINT" "$SERVER_PORT")
AllowedIPs = $WG_ALLOWED_IPS
PersistentKeepalive = 25
EOF
  chmod 600 "$client_file"

  NEXT_CLIENT_ID="$((client_id + 1))"
  {
    write_shell_env_value "SERVER_PUBLIC_KEY" "$SERVER_PUBLIC_KEY"
    write_shell_env_value "SERVER_ENDPOINT" "$SERVER_ENDPOINT"
    write_shell_env_value "SERVER_PORT" "$SERVER_PORT"
    write_shell_env_value "CLIENT_V4_PREFIX" "$CLIENT_V4_PREFIX"
    write_shell_env_value "CLIENT_V6_PREFIX" "$CLIENT_V6_PREFIX"
    write_shell_env_value "NEXT_CLIENT_ID" "$NEXT_CLIENT_ID"
  } > "$WG_SERVER_ENV"
  chmod 600 "$WG_SERVER_ENV"

  ok "客户端已添加：$client_name"
  ok "客户端配置文件：$client_file"
}

auto_deploy_hybrid_mode() {
  local src endpoint_host stale_addrs
  need_root
  need_systemd
  ensure_dirs
  init_split_policy
  info "自动部署混合模式：sing-box 分流 + WireGuard 出口..."
  ensure_wg_tools
  enable_kernel_features
  install_singbox_binary
  disable_watchdog
  stop_wg_client_mode
  auto_select_wan_iface

  src="${VPS_OUT_WG_CONF_SOURCE:-}"
  if [ -n "$src" ]; then
    copy_wg_conf_if_needed "$src"
  fi
  [ -f "$WG_CLIENT_CONF" ] || die "未找到 WG 客户端配置：$WG_CLIENT_CONF，请设置 VPS_OUT_WG_CONF_SOURCE"

  endpoint_host="${VPS_OUT_WG_ENDPOINT_HOST:-$(get_wg_endpoint_host_from_conf "$WG_CLIENT_CONF" || true)}"
  [ -n "$endpoint_host" ] || die "未能从 WG 配置解析 Endpoint，请设置 VPS_OUT_WG_ENDPOINT_HOST"
  prepare_wg_conf_for_hybrid "$WG_CLIENT_CONF" "$endpoint_host"
  apply_auto_split_policy

  build_hybrid_singbox_config
  write_singbox_service
  write_singbox_container_bypass

  stale_addrs="$(collect_managed_iface_addrs)"
  stop_singbox_mode
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${WG_CLIENT_IFACE}"
  ip link show "$WG_CLIENT_IFACE" >/dev/null 2>&1 || die "WireGuard 客户端接口 $WG_CLIENT_IFACE 未启动"
  "$SINGBOX_BIN" check -c "$SINGBOX_CONF" || die "sing-box 配置检查失败"
  systemctl enable --now vps-out-singbox
  write_active_mode "$HYBRID_MODE_NAME"
  kill_stale_managed_connections "$stale_addrs"
  enable_watchdog
  ok "混合模式自动部署完成。"
  show_status_brief
}

verify_hybrid_mode() {
  local failed=0 host_ip4 wg_ip4 latest now age
  need_root
  need_systemd
  info "开始验证混合模式..."

  if [ "$(read_active_mode)" != "$HYBRID_MODE_NAME" ]; then
    err "当前记录模式不是混合模式：$(read_active_mode)"
    failed=1
  fi

  if ! systemctl is-active --quiet "wg-quick@${WG_CLIENT_IFACE}"; then
    err "WireGuard 客户端服务未运行"
    failed=1
  fi
  if ! systemctl is-active --quiet vps-out-singbox; then
    err "sing-box 服务未运行"
    failed=1
  fi
  if ! systemctl is-active --quiet vps-out-watchdog; then
    err "守护进程未运行"
    failed=1
  fi
  if ! ip link show "$WG_CLIENT_IFACE" >/dev/null 2>&1; then
    err "WireGuard 客户端接口不存在：$WG_CLIENT_IFACE"
    failed=1
  fi
  if ! ip link show vpsout0 >/dev/null 2>&1; then
    err "sing-box TUN 接口不存在：vpsout0"
    failed=1
  fi
  if [ -x "$SINGBOX_BIN" ] && [ -f "$SINGBOX_CONF" ]; then
    "$SINGBOX_BIN" check -c "$SINGBOX_CONF" >/dev/null 2>&1 || {
      err "sing-box 配置检查失败：$SINGBOX_CONF"
      failed=1
    }
  else
    err "sing-box 二进制或配置文件不存在"
    failed=1
  fi

  latest="$(wg show "$WG_CLIENT_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -n 1)"
  now="$(date +%s)"
  if [ -n "$latest" ] && [ "$latest" -gt 0 ]; then
    age="$((now - latest))"
    if [ "$age" -gt 300 ]; then
      err "WireGuard 最近握手超过 300 秒：${age}s"
      failed=1
    else
      ok "WireGuard 最近握手：${age}s 前"
    fi
  else
    err "WireGuard 尚无握手"
    failed=1
  fi

  wg_ip4="$(curl -4 -fsS --interface "$WG_CLIENT_IFACE" --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  host_ip4="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$wg_ip4" ]; then
    ok "WG 网卡 IPv4 出口：$wg_ip4"
  else
    err "WG 网卡 IPv4 出口检测失败"
    failed=1
  fi
  if [ -n "$host_ip4" ]; then
    ok "主机当前 IPv4 出口：$host_ip4"
  else
    err "主机当前 IPv4 出口检测失败"
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    ok "混合模式验证通过。"
  else
    die "混合模式验证失败，请查看上方错误和 journalctl 日志"
  fi
}

show_service_state() {
  local unit="$1" label="$2"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf '%s：%s运行中%s\n' "$label" "$GREEN" "$NC"
  else
    printf '%s：%s未运行%s\n' "$label" "$YELLOW" "$NC"
  fi
}

show_status_brief() {
  local ip4 ip6 wg_ip4 wg_ip6
  echo
  info "状态摘要："
  printf '当前记录模式：%s\n' "$(read_active_mode)"
  show_service_state vps-out-singbox "sing-box+nftables"
  show_service_state "wg-quick@${WG_CLIENT_IFACE}" "WireGuard 客户端"
  show_service_state "wg-quick@${WG_SERVER_IFACE}" "WireGuard 服务端"
  show_service_state vps-out-watchdog "出口守护进程"
  if [ "$(read_active_mode)" = "$HYBRID_MODE_NAME" ]; then
    printf '混合模式出口链路：sing-box -> %s\n' "$WG_CLIENT_IFACE"
    wg_ip4="$(curl -4 -fsS --interface "$WG_CLIENT_IFACE" --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    wg_ip6="$(curl -6 -fsS --interface "$WG_CLIENT_IFACE" --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    [ -n "$wg_ip4" ] && printf 'WG 网卡 IPv4 出口：%s\n' "$wg_ip4" || printf 'WG 网卡 IPv4 出口：检测失败\n'
    [ -n "$wg_ip6" ] && printf 'WG 网卡 IPv6 出口：%s\n' "$wg_ip6" || printf 'WG 网卡 IPv6 出口：检测失败或无 IPv6\n'
  fi
  ip4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  ip6="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  [ -n "$ip4" ] && printf '当前 IPv4 出口：%s\n' "$ip4" || printf '当前 IPv4 出口：检测失败\n'
  [ -n "$ip6" ] && printf '当前 IPv6 出口：%s\n' "$ip6" || printf '当前 IPv6 出口：检测失败或无 IPv6\n'
}

show_status_detail() {
  safe_clear
  show_status_brief
  echo
  info "默认路由："
  ip route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
  echo
  info "WireGuard 路由："
  ip route show dev "$WG_CLIENT_IFACE" 2>/dev/null || true
  ip -6 route show dev "$WG_CLIENT_IFACE" 2>/dev/null || true
  echo
  info "WireGuard 状态："
  wg show 2>/dev/null || true
  echo
  info "nftables 相关表："
  nft list tables 2>/dev/null | grep -E 'vps_out|sing-box|singbox' || true
  echo
  info "最近日志：sing-box"
  journalctl -u vps-out-singbox -n 20 --no-pager 2>/dev/null || true
  echo
  info "最近日志：WireGuard 客户端"
  journalctl -u "wg-quick@${WG_CLIENT_IFACE}" -n 20 --no-pager 2>/dev/null || true
  echo
  info "最近日志：出口守护进程"
  journalctl -u vps-out-watchdog -n 20 --no-pager 2>/dev/null || true
  pause
}

cleanup_client_modes() {
  safe_clear
  need_root
  info "正在停止客户端出口切换模式..."
  disable_watchdog
  stop_client_modes
  write_active_mode "未启用"
  if confirm "是否恢复脚本写入过的系统 DNS？" "Y"; then
    restore_system_dns
  fi
  ok "已停止 sing-box 和 WireGuard 客户端出口切换。配置文件保留。"
  pause
}

uninstall_generated() {
  safe_clear
  need_root
  local self_path
  self_path="$(get_script_path)"
  warn "此操作会彻底卸载本脚本生成的所有出口切换内容，并删除脚本文件本身。"
  warn "将删除：sing-box 服务和二进制、sing-box 通用配置、WireGuard 客户端/服务端配置、/etc/vps-out-switch、nft 表、sysctl 配置、DNS 回滚文件。"
  confirm "确认彻底卸载并删除脚本自身？" "N" || return

  info "正在停止所有相关服务..."
  disable_watchdog
  stop_all_modes
  stop_generic_singbox

  info "正在恢复 DNS 并删除服务文件..."
  restore_system_dns
  rm -f "$SINGBOX_SERVICE"
  rm -f "$SINGBOX_INCUS_BYPASS_DROPIN"
  rmdir "$SINGBOX_DROPIN_DIR" >/dev/null 2>&1 || true
  rm -f "$GENERIC_SINGBOX_SERVICE"
  rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_SCRIPT" "$WG_CLIENT_RULES_SCRIPT" "$HYBRID_WG_RULES_SCRIPT" "$SINGBOX_INCUS_BYPASS_SCRIPT"
  if compgen -G "$PORT_FORWARD_DIR/*.env" >/dev/null; then
    for pf in "$PORT_FORWARD_DIR"/*.env; do
      # shellcheck disable=SC1090
      . "$pf"
      [ -n "${UNIT:-}" ] && systemctl disable --now "$(basename "$UNIT")" >/dev/null 2>&1 || true
      [ -n "${UNIT:-}" ] && rm -f "$UNIT"
    done
  fi
  rm -f "$WG_CLIENT_CONF" "${WG_CLIENT_CONF}.bak" "${WG_CLIENT_CONF}.save"
  rm -f "$WG_SERVER_CONF" "${WG_SERVER_CONF}.bak" "${WG_SERVER_CONF}.save"
  rm -f /etc/sysctl.d/99-vps-out-switch.conf
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed vps-out-singbox sing-box vps-out-watchdog "wg-quick@${WG_CLIENT_IFACE}" "wg-quick@${WG_SERVER_IFACE}" >/dev/null 2>&1 || true

  info "正在清理网络残留..."
  cleanup_nft_tables
  cleanup_link_residue
  sysctl --system >/dev/null 2>&1 || true

  info "正在删除配置目录和 sing-box 二进制..."
  rm -rf "$STATE_DIR"
  rm -rf /usr/local/etc/sing-box /etc/sing-box
  rm -f "$SINGBOX_BIN"

  if [ -f "$self_path" ]; then
    info "正在删除脚本自身：$self_path"
    rm -f -- "$self_path"
  else
    warn "未找到可删除的脚本路径：$self_path"
  fi

  ok "彻底卸载完成。"
  exit 0
}

show_wg_plan() {
  safe_clear
  cat <<'EOF'
WireGuard / 混合隧道模式规划：

1. 如果你拥有出口 VPS 控制权，推荐在出口 VPS 上运行：
   “初始化本机为 WireGuard 出口服务端”。

2. 在需要切换出口的 VPS 上运行：
   “部署/切换 WireGuard 客户端出口”。

3. WireGuard 的优点：
   - 适合你自己控制的出口 VPS，性能高、延迟低、协议干净。
   - 服务端只需要开放一个 UDP 端口。
   - 客户端可以全局出口，也可以按 IP/CIDR 分流。
   - 如果入口机承载 LXC/Incus 容器并且容器内要对外提供代理节点，纯 WG 模式建议使用全局出口；窄 CIDR 分流只适合宿主机按目标网段出站，不适合作为容器节点的通用回程出口。

4. WireGuard 的限制：
   - 原生 WG 不理解域名，只能按 AllowedIPs 里的 IP/CIDR 分流。
   - 如果你要“域名分流”，可以使用“混合模式：sing-box 分流 + WireGuard 出口”。
   - 全局 WG 出口会改变默认路由，本脚本会尽量保留当前 SSH 客户端直连路由，降低断连风险。

5. 混合模式：
   - 入口机先用 wg-quick 建立内核 WireGuard 网卡，配置 Table=off，不直接抢系统默认路由。
   - sing-box 负责透明代理、DNS 劫持、域名/CIDR 分流。
   - 命中代理规则的连接绑定 WireGuard 网卡出站，命中直连规则的连接绑定公网网卡出站。
   - 混合模式会关闭 sing-box TUN 的 strict_route，以兼容按网卡绑定出站。
   - 这个模式比纯 WG 多一层 sing-box 用户态转发，但能保留域名分流，适合多 LXC 容器统一出口。

6. DNS 规划：
   - 本脚本固定使用 1.1.1.1、8.8.8.8、2606:4700:4700::1111、2001:4860:4860::8888。
   - sing-box 模式会在内部 DNS 里使用这些地址。
   - WG 模式会写入客户端配置的 DNS 行，也可以选择写入系统 DNS。
EOF
  pause
}

print_menu() {
  safe_clear
  echo "${BLUE}============================================================${NC}"
  echo "${BOLD}                 $APP_NAME${NC}"
  echo "${BLUE}============================================================${NC}"
  echo " 当前模式：$(read_active_mode)"
  echo
  echo " 1. 部署/切换 sing-box + nftables 出口（SOCKS5/SK5 或 Shadowsocks）"
  echo " 2. 部署/切换 WireGuard 客户端出口"
  echo " 3. 部署/切换混合模式（sing-box 分流 + WireGuard 出口）"
  echo " 4. 初始化本机为 WireGuard 出口服务端"
  echo " 5. 给本机 WireGuard 服务端添加客户端"
  echo " 6. 分流规则管理"
  echo " 7. 容器端口转发管理"
  echo " 8. 查看状态、出口 IP 和日志"
  echo " 9. 停止当前客户端出口切换（保留配置）"
  echo "10. 查看 WireGuard / 混合模式规划说明"
  echo "11. 彻底卸载并删除脚本自身"
  echo " 0. 退出"
  echo "${BLUE}============================================================${NC}"
}

main() {
  local choice
  need_root
  ensure_dirs
  init_split_policy
  while true; do
    print_menu
    read -r -p "请输入选项：" choice || true
    case "$choice" in
      1) deploy_singbox_mode ;;
      2) deploy_wg_client_mode ;;
      3) deploy_hybrid_mode ;;
      4) setup_wg_server_mode ;;
      5) add_wg_server_peer ;;
      6) manage_split_rules ;;
      7) manage_port_forwards ;;
      8) show_status_detail ;;
      9) cleanup_client_modes ;;
      10) show_wg_plan ;;
      11) uninstall_generated ;;
      0) exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

run_self_check() {
  need_root
  ensure_dirs
  init_split_policy
  info "开始执行脚本自检..."
  command -v jq >/dev/null 2>&1 || die "缺少 jq"
  command -v ip >/dev/null 2>&1 || die "缺少 iproute2"
  command -v nft >/dev/null 2>&1 || warn "未检测到 nft，部署时会自动尝试安装 nftables"
  command -v wg >/dev/null 2>&1 || warn "未检测到 wg，部署 WireGuard 时会自动尝试安装 wireguard-tools"
  command -v systemctl >/dev/null 2>&1 || warn "未检测到 systemctl，服务部署不可用"
  if [ -x "$SINGBOX_BIN" ]; then
    ok "sing-box：$("$SINGBOX_BIN" version | head -n 1)"
  else
    warn "未检测到 $SINGBOX_BIN，部署 sing-box 相关模式时会自动安装"
  fi
  ok "公网网卡候选："
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo|docker|docker0|podman|podman0|cni|cni0|veth|br-|virbr|tun|wg|vpsout|tailscale|zt|incusbr|lxdbr)' | awk '!seen[$0]++ {print " - " $0}' || true
  ok "自检完成。"
}

case "${1:-}" in
  --self-check)
    run_self_check
    exit 0
    ;;
  --auto-setup-wg-server)
    auto_setup_wg_server_mode
    exit 0
    ;;
  --auto-deploy-singbox)
    auto_deploy_singbox_mode
    exit 0
    ;;
  --auto-deploy-wg-client)
    auto_deploy_wg_client_mode
    exit 0
    ;;
  --auto-port-forward)
    auto_deploy_port_forward
    exit 0
    ;;
  --auto-add-wg-peer)
    auto_add_wg_server_peer
    exit 0
    ;;
  --auto-deploy-hybrid)
    auto_deploy_hybrid_mode
    exit 0
    ;;
  --verify-hybrid)
    verify_hybrid_mode
    exit 0
    ;;
esac

main "$@"
