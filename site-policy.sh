#!/usr/bin/env bash
# ==============================================================================
# 网站策略管理脚本 (Site Policy v2.0)
# 架构: DNS Sinkhole (dnsmasq) + Nginx (302/403) + 本地自签 CA (HTTPS) + iptables 独立链
# 专为 Debian / Ubuntu 深度优化，支持高并发、超低资源占用、零连带误杀
# ==============================================================================
set -euo pipefail

APP="site-policy"
BASE_DIR="/etc/${APP}"
CONFIG_FILE="${BASE_DIR}/config"
BLOCK_LIST="${BASE_DIR}/block.list"
REDIRECT_LIST="${BASE_DIR}/redirect.list"
DNSMASQ_CONF="${BASE_DIR}/dnsmasq.conf"
NGINX_CONF="/etc/nginx/conf.d/${APP}.conf"
CERTS_DIR="${BASE_DIR}/certs"
CA_KEY="${CERTS_DIR}/ca.key"
CA_CERT="${CERTS_DIR}/ca.crt"
SERVER_KEY="${CERTS_DIR}/server.key"
SERVER_CERT="${CERTS_DIR}/server.crt"
SYSTEM_CA_DIR="/usr/local/share/ca-certificates"
SYSTEM_CA_FILE="${SYSTEM_CA_DIR}/${APP}-ca.crt"

DNS_SERVICE="/etc/systemd/system/${APP}-dns.service"
FW_SCRIPT="/usr/local/sbin/${APP}-firewall"
FW_SERVICE="/etc/systemd/system/${APP}-firewall.service"

NAT_CHAIN="SITE_POLICY_NAT"
NAT_CHAIN6="SITE_POLICY_NAT6"
DNSMASQ_USER="dnsmasq"

DEFAULT_TARGET_MODE="host"
DEFAULT_DNS_PORT="5353"
DEFAULT_BLOCK_MODE="null" # null: 0.0.0.0 瞬断; page: 403 页面
DEFAULT_ENABLE_HTTPS="1"   # 1: 启用 HTTPS 拦截支持 (443); 0: 仅 HTTP (80)
DEFAULT_DOMAIN="ping0.cc"
DEFAULT_REDIRECT_URL="https://ping0.cc"

# ----------------- 日志与辅助函数 -----------------
log() { printf '\033[32m[%s]\033[0m %s\n' "${APP}" "$*"; }
warn() { printf '\033[33m[%s] 警告:\033[0m %s\n' "${APP}" "$*"; }
err() { printf '\033[31m[%s] 错误:\033[0m %s\n' "${APP}" "$*" >&2; }
die() { err "$*"; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "此操作必须使用 root 权限运行"
}

ensure_dirs() {
  mkdir -p "${BASE_DIR}" "${CERTS_DIR}"
  touch "${BLOCK_LIST}" "${REDIRECT_LIST}"
  chmod 700 "${BASE_DIR}" 2>/dev/null || true
  chmod 700 "${CERTS_DIR}" 2>/dev/null || true
}

ensure_dnsmasq_user() {
  if ! id -u "${DNSMASQ_USER}" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /var/empty "${DNSMASQ_USER}" 2>/dev/null || true
  fi
}

# ----------------- 依赖安装与环境初始化 -----------------
install_packages() {
  log "正在检查并安装必要系统依赖 (dnsmasq, nginx, iptables, openssl, ca-certificates)..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      dnsmasq nginx iptables iproute2 openssl ca-certificates curl dnsutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y dnsmasq nginx iptables iproute openssl ca-certificates curl bind-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dnsmasq nginx iptables iproute openssl ca-certificates curl bind-utils
  else
    die "当前包管理器不支持自动安装，请手动安装: dnsmasq, nginx, iptables, openssl, ca-certificates"
  fi

  ensure_dnsmasq_user
  # 停用并禁用系统可能自带的 dnsmasq 默认服务，避免 53 端口冲突
  systemctl disable --now dnsmasq 2>/dev/null || true
  # 清理 Debian/Ubuntu 默认 default 站点，避免端口冲突
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
}

# ----------------- 证书生成与系统根证书信任 -----------------
generate_certificates() {
  ensure_dirs
  # 1. 如果 Root CA 不存在则生成
  if [[ ! -f "${CA_KEY}" || ! -f "${CA_CERT}" ]]; then
    log "正在生成独立本地 Root CA 证书..."
    openssl genrsa -out "${CA_KEY}" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days 3650 \
      -out "${CA_CERT}" -subj "/CN=SitePolicy-Root-CA/O=SitePolicy/C=CN" 2>/dev/null
  fi

  # 2. 将 Root CA 注入系统受信任根证书库 (Debian / Ubuntu)
  if [[ -d "${SYSTEM_CA_DIR}" ]]; then
    if [[ ! -f "${SYSTEM_CA_FILE}" ]] || ! cmp -s "${CA_CERT}" "${SYSTEM_CA_FILE}"; then
      log "正在将本地 Root CA 注入系统证书信任库..."
      cp -f "${CA_CERT}" "${SYSTEM_CA_FILE}"
      chmod 644 "${SYSTEM_CA_FILE}"
      update-ca-certificates >/dev/null 2>&1 || true
    fi
  fi

  # 3. 收集所有需要拦截/跳转的域名，生成包含完整 SAN 的服务端证书
  local san_list="DNS:localhost,IP:127.0.0.1,IP:::1"
  if [[ -n "${LANDING_IP:-}" && "${LANDING_IP}" != "127.0.0.1" ]]; then
    san_list="${san_list},IP:${LANDING_IP}"
  fi

  local domain
  while read -r domain _; do
    [[ -n "${domain}" && ! "${domain}" =~ ^# ]] || continue
    san_list="${san_list},DNS:${domain},DNS:*.${domain}"
  done < <(cat "${BLOCK_LIST}" "${REDIRECT_LIST}" 2>/dev/null || true)

  # 生成服务端私钥与带 SAN 扩展的证书
  local ext_file
  ext_file="$(mktemp)"
  cat >"${ext_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${san_list}
EOF

  local csr_file
  csr_file="$(mktemp)"
  openssl genrsa -out "${SERVER_KEY}" 2048 2>/dev/null
  openssl req -new -key "${SERVER_KEY}" -out "${csr_file}" \
    -subj "/CN=site-policy-server/O=SitePolicy" 2>/dev/null
  openssl x509 -req -in "${csr_file}" -CA "${CA_CERT}" -CAkey "${CA_KEY}" \
    -CAcreateserial -out "${SERVER_CERT}" -days 1095 -sha256 -extfile "${ext_file}" 2>/dev/null

  rm -f "${csr_file}" "${ext_file}" "${CERTS_DIR}/ca.srl" 2>/dev/null || true
  chmod 600 "${SERVER_KEY}" "${CA_KEY}" 2>/dev/null || true
  chmod 644 "${SERVER_CERT}" "${CA_CERT}" 2>/dev/null || true
}

# ----------------- 网桥与运行模式探测 -----------------
detect_bridge_candidates() {
  ip -o link show 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | cut -d'@' -f1 \
    | grep -E '^(incusbr|lxdbr|lxcbr|virbr|br-)' || true
}

bridge_ipv4() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}'
}

select_target_mode() {
  local mode_arg="${1:-}"
  local mode_choice=""

  if [[ "${mode_arg}" == "host" || "${mode_arg}" == "1" ]]; then
    mode_choice="1"
  elif [[ "${mode_arg}" == "bridge" || "${mode_arg}" == "2" ]]; then
    mode_choice="2"
  else
    echo
    echo "请选择策略作用目标："
    echo "  1) host   - 宿主机自身出网拦截 (针对本机进程/curl/脚本出网)"
    echo "  2) bridge - LXC/Incus 容器网桥拦截 (针对容器网桥流量)"
    read -r -p "请选择 [1/2] (直接回车默认 1): " mode_choice || true
    mode_choice="${mode_choice:-1}"
  fi

  case "${mode_choice}" in
    1|host)
      TARGET_MODE="host"
      BRIDGE_IF="lo"
      LANDING_IP="127.0.0.1"
      log "已选择 [宿主机自身出网模式]，落地 IP: 127.0.0.1"
      ;;
    2|bridge)
      TARGET_MODE="bridge"
      select_bridge
      log "已选择 [容器网桥模式]，网桥: ${BRIDGE_IF}，落地 IP: ${LANDING_IP}"
      ;;
    *)
      die "输入无效"
      ;;
  esac
}

select_bridge() {
  local candidates=() iface ip4 idx choice
  mapfile -t candidates < <(detect_bridge_candidates)

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    read -r -p "未自动检测到网桥，请输入网桥名 (如 incusbr0/lxdbr0/lxcbr0): " iface
    [[ -n "${iface}" ]] || die "网桥名不能为空"
  else
    echo "检测到以下可用网桥："
    idx=1
    for iface in "${candidates[@]}"; do
      ip4="$(bridge_ipv4 "${iface}")"
      printf '  %d) %s %s\n' "${idx}" "${iface}" "${ip4:+(${ip4})}"
      idx=$((idx + 1))
    done
    read -r -p "请选择网桥 [1-${#candidates[@]}]: " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] || die "输入无效"
    (( choice >= 1 && choice <= ${#candidates[@]} )) || die "选择超出范围"
    iface="${candidates[$((choice - 1))]}"
  fi

  ip4="$(bridge_ipv4 "${iface}")"
  [[ -n "${ip4}" ]] || die "网桥 ${iface} 没有分配可用的 IPv4 地址"

  BRIDGE_IF="${iface}"
  LANDING_IP="${ip4}"
}

# ----------------- 配置读取与保存 -----------------
load_config() {
  TARGET_MODE="${DEFAULT_TARGET_MODE}"
  DNS_PORT="${DEFAULT_DNS_PORT}"
  BLOCK_MODE="${DEFAULT_BLOCK_MODE}"
  ENABLE_HTTPS="${DEFAULT_ENABLE_HTTPS}"
  BRIDGE_IF="lo"
  LANDING_IP="127.0.0.1"

  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi
}

save_config() {
  ensure_dirs
  umask 077
  cat >"${CONFIG_FILE}" <<EOF
TARGET_MODE="${TARGET_MODE:-${DEFAULT_TARGET_MODE}}"
BRIDGE_IF="${BRIDGE_IF:-lo}"
LANDING_IP="${LANDING_IP:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-${DEFAULT_DNS_PORT}}"
BLOCK_MODE="${BLOCK_MODE:-${DEFAULT_BLOCK_MODE}}"
ENABLE_HTTPS="${ENABLE_HTTPS:-${DEFAULT_ENABLE_HTTPS}}"
EOF
}

# ----------------- 域名与 URL 校验清洗 -----------------
normalize_domain() {
  local value="$1"
  value="${value,,}"
  value="${value//[[:space:]]/}"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  if [[ "${value}" == \*.* ]]; then
    value="${value#\*.}"
  fi
  value="${value#.}"
  value="${value%.}"
  printf '%s' "${value}"
}

validate_domain() {
  local domain="$1"
  local label old_ifs count=0
  [[ -n "${domain}" ]] || return 1
  [[ "${domain}" == *"."* ]] || return 1
  [[ "${domain}" != "."* ]] || return 1
  [[ "${domain}" != *"." ]] || return 1
  [[ "${domain}" != *".."* ]] || return 1
  [[ "${#domain}" -le 253 ]] || return 1
  case "${domain}" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789.-]*)
      return 1
      ;;
  esac

  old_ifs="${IFS}"
  IFS='.'
  set -- ${domain}
  IFS="${old_ifs}"

  for label in "$@"; do
    count=$((count + 1))
    [[ -n "${label}" ]] || return 1
    [[ "${#label}" -le 63 ]] || return 1
    [[ "${label}" != "-"* ]] || return 1
    [[ "${label}" != *"-" ]] || return 1
  done

  [[ "${count}" -ge 2 ]]
}

validate_url() {
  local url="$1"
  local dq sq
  dq="$(printf '\042')"
  sq="$(printf '\047')"
  [[ "${url}" == http://* || "${url}" == https://* ]] || return 1
  [[ "${url}" != *[[:space:]]* ]] || return 1
  [[ "${url}" != *";"* ]] || return 1
  [[ "${url}" != *"$"* ]] || return 1
  [[ "${url}" != *"{"* && "${url}" != *"}"* ]] || return 1
  [[ "${url}" != *"${dq}"* && "${url}" != *"${sq}"* ]] || return 1
  [[ "${url}" != *"<"* && "${url}" != *">"* ]]
}

remove_domain_from_lists() {
  local domain="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v domain="${domain}" '$1 != domain' "${BLOCK_LIST}" >"${tmp}" || true
  cat "${tmp}" >"${BLOCK_LIST}"
  awk -v domain="${domain}" '$1 != domain' "${REDIRECT_LIST}" >"${tmp}" || true
  cat "${tmp}" >"${REDIRECT_LIST}"
  rm -f "${tmp}"
}

# ----------------- 规则增删查 -----------------
add_block() {
  local domain
  ensure_dirs
  domain="$(normalize_domain "${1:-${DEFAULT_DOMAIN}}")"
  validate_domain "${domain}" || die "域名格式无效: ${1:-}"
  remove_domain_from_lists "${domain}"
  printf '%s\n' "${domain}" >>"${BLOCK_LIST}"
  log "已成功添加阻断域名: ${domain}"
  generate_all
  reload_services
}

add_redirect() {
  local domain url
  ensure_dirs
  domain="$(normalize_domain "${1:-${DEFAULT_DOMAIN}}")"
  url="${2:-${DEFAULT_REDIRECT_URL}}"
  validate_domain "${domain}" || die "域名格式无效: ${1:-}"
  validate_url "${url}" || die "跳转 URL 格式不规范或包含非法字符"
  remove_domain_from_lists "${domain}"
  printf '%s %s\n' "${domain}" "${url}" >>"${REDIRECT_LIST}"
  log "已成功添加跳转域名: ${domain} -> ${url}"
  generate_all
  reload_services
}

delete_domain() {
  local domain
  ensure_dirs
  domain="$(normalize_domain "${1:-}")"
  [[ -n "${domain}" ]] || die "必须指定要删除的域名"
  validate_domain "${domain}" || die "域名格式无效: ${domain}"
  remove_domain_from_lists "${domain}"
  log "已删除域名规则: ${domain}"
  generate_all
  reload_services
}

list_rules() {
  ensure_dirs
  load_config
  echo "=================================================="
  echo "               当前生效策略与规则列表               "
  echo "=================================================="
  echo "策略模式   : ${TARGET_MODE}"
  echo "绑定网卡   : ${BRIDGE_IF}"
  echo "落地 IP    : ${LANDING_IP}"
  echo "DNS 端口   : ${DNS_PORT}"
  echo "阻断模式   : ${BLOCK_MODE} ($( [[ "${BLOCK_MODE}" == "null" ]] && echo "0.0.0.0 瞬断" || echo "403 页面提示" ))"
  echo "HTTPS 拦截 : $( [[ "${ENABLE_HTTPS}" == "1" ]] && echo "已开启 (443 端口 + 本地 CA 证书)" || echo "已关闭 (仅 80 端口)" )"
  echo "--------------------------------------------------"
  echo "【阻断域名列表】:"
  if [[ -s "${BLOCK_LIST}" ]]; then
    sed 's/^/  [BLOCK]    /' "${BLOCK_LIST}"
  else
    echo "  (无)"
  fi
  echo
  echo "【跳转域名列表】:"
  if [[ -s "${REDIRECT_LIST}" ]]; then
    awk '{first=$1; $1=""; sub(/^ /,""); printf "  [REDIRECT] %s -> %s\n", first, $0}' "${REDIRECT_LIST}"
  else
    echo "  (无)"
  fi
  echo "=================================================="
}

# ----------------- 模式切换函数 -----------------
set_block_mode() {
  need_root
  load_config
  local mode_arg="${1:-}"
  local choice=""

  if [[ "${mode_arg}" == "null" || "${mode_arg}" == "1" ]]; then
    BLOCK_MODE="null"
  elif [[ "${mode_arg}" == "page" || "${mode_arg}" == "2" ]]; then
    BLOCK_MODE="page"
  else
    echo
    echo "请选择阻断响应模式："
    echo "  1) null - DNS 返回 0.0.0.0/:: (秒级阻断，不产生任何 HTTP 连接，高并发推荐)"
    echo "  2) page - DNS 返回落地 IP，由 Nginx 返回 403 页面提示"
    read -r -p "请选择 [1/2] (直接回车默认 1): " choice || true
    case "${choice:-1}" in
      1|null) BLOCK_MODE="null" ;;
      2|page) BLOCK_MODE="page" ;;
      *) die "输入无效" ;;
    esac
  fi

  save_config
  generate_all
  reload_services
  log "阻断模式已切换为: ${BLOCK_MODE}"
}

set_https_mode() {
  need_root
  load_config
  local mode_arg="${1:-}"
  local choice=""

  if [[ "${mode_arg}" == "1" || "${mode_arg}" == "on" || "${mode_arg}" == "enable" ]]; then
    ENABLE_HTTPS="1"
  elif [[ "${mode_arg}" == "0" || "${mode_arg}" == "off" || "${mode_arg}" == "disable" ]]; then
    ENABLE_HTTPS="0"
  else
    echo
    echo "请选择是否开启 HTTPS 拦截支持："
    echo "  1) 开启 - 监听 443 端口，通过本地 Root CA 签发证书，支持 HTTPS 302 跳转与 403 提示"
    echo "  2) 关闭 - 仅监听 80 端口，HTTPS 请求将直接被拒绝"
    read -r -p "请选择 [1/2] (直接回车默认 1): " choice || true
    case "${choice:-1}" in
      1|on) ENABLE_HTTPS="1" ;;
      2|off) ENABLE_HTTPS="0" ;;
      *) die "输入无效" ;;
    esac
  fi

  save_config
  generate_all
  reload_services
  log "HTTPS 拦截模式已切换为: $( [[ "${ENABLE_HTTPS}" == "1" ]] && echo "开启" || echo "关闭" )"
}

set_target_mode() {
  need_root
  load_config
  select_target_mode "${1:-}"
  save_config
  generate_all
  restart_services
  log "作用目标已成功切换为: ${TARGET_MODE}"
}

# ----------------- 服务与配置文件生成 -----------------
generate_dnsmasq_conf() {
  local domain
  : "${LANDING_IP:?missing LANDING_IP}"

  cat >"${DNSMASQ_CONF}" <<EOF
# 网站策略控制 - dnsmasq 自动生成配置
no-resolv
server=8.8.8.8
server=1.1.1.1
server=223.5.5.5
bind-interfaces
listen-address=${LANDING_IP}
EOF

  if [[ "${TARGET_MODE}" == "host" ]]; then
    printf 'listen-address=::1\n' >>"${DNSMASQ_CONF}"
  fi

  cat >>"${DNSMASQ_CONF}" <<EOF
port=${DNS_PORT}
user=${DNSMASQ_USER}
domain-needed
bogus-priv
cache-size=10000
EOF

  # 1. 处理阻断域名 (DNS Sinkhole 或 落地 IP)
  while read -r domain; do
    [[ -n "${domain}" && ! "${domain}" =~ ^# ]] || continue
    if [[ "${BLOCK_MODE}" == "page" ]]; then
      printf 'address=/%s/%s\n' "${domain}" "${LANDING_IP}" >>"${DNSMASQ_CONF}"
      if [[ "${TARGET_MODE}" == "host" ]]; then
        printf 'address=/%s/::1\n' "${domain}" >>"${DNSMASQ_CONF}"
      else
        printf 'address=/%s/::\n' "${domain}" >>"${DNSMASQ_CONF}"
      fi
    else
      # null 模式: 直接返回 0.0.0.0 / ::
      printf 'address=/%s/0.0.0.0\n' "${domain}" >>"${DNSMASQ_CONF}"
      printf 'address=/%s/::\n' "${domain}" >>"${DNSMASQ_CONF}"
    fi
  done <"${BLOCK_LIST}"

  # 2. 处理跳转域名 (必须解析至落地 IP)
  while read -r domain _; do
    [[ -n "${domain}" && ! "${domain}" =~ ^# ]] || continue
    printf 'address=/%s/%s\n' "${domain}" "${LANDING_IP}" >>"${DNSMASQ_CONF}"
    if [[ "${TARGET_MODE}" == "host" ]]; then
      printf 'address=/%s/::1\n' "${domain}" >>"${DNSMASQ_CONF}"
    else
      printf 'address=/%s/::\n' "${domain}" >>"${DNSMASQ_CONF}"
    fi
  done <"${REDIRECT_LIST}"
}

generate_nginx_conf() {
  local domain url
  cat >"${NGINX_CONF}" <<EOF
# 网站策略控制 - Nginx 自动生成配置
map \$host \$site_policy_redirect {
    hostnames;
    default "";
EOF

  while read -r domain url; do
    [[ -n "${domain}" && -n "${url}" ]] || continue
    printf '    .%s %s;\n' "${domain}" "${url}" >>"${NGINX_CONF}"
  done <"${REDIRECT_LIST}"

  cat >>"${NGINX_CONF}" <<EOF
}

server {
    listen ${LANDING_IP}:80;
EOF

  if [[ "${TARGET_MODE}" == "host" ]]; then
    printf '    listen [::1]:80;\n' >>"${NGINX_CONF}"
  fi

  if [[ "${ENABLE_HTTPS}" == "1" && -f "${SERVER_CERT}" && -f "${SERVER_KEY}" ]]; then
    printf '    listen %s:443 ssl;\n' "${LANDING_IP}" >>"${NGINX_CONF}"
    if [[ "${TARGET_MODE}" == "host" ]]; then
      printf '    listen [::1]:443 ssl;\n' >>"${NGINX_CONF}"
    fi
    cat >>"${NGINX_CONF}" <<EOF
    ssl_certificate ${SERVER_CERT};
    ssl_certificate_key ${SERVER_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
EOF
  fi

  cat >>"${NGINX_CONF}" <<EOF
    server_name _;

    access_log /var/log/nginx/${APP}.access.log;
    error_log /var/log/nginx/${APP}.error.log;

    location / {
        if (\$site_policy_redirect != "") {
            return 302 \$site_policy_redirect;
        }

        default_type text/plain;
        return 403 "Access blocked by site-policy.\n";
    }
}
EOF
}

# ----------------- 防火墙脚本生成 (独立规则链，零干扰) -----------------
generate_firewall_script() {
  cat >"${FW_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TARGET_MODE="${TARGET_MODE:-host}"
BRIDGE_IF="${BRIDGE_IF:-lo}"
DNS_PORT="${DNS_PORT:-${DEFAULT_DNS_PORT}}"
NAT_CHAIN="${NAT_CHAIN}"
NAT_CHAIN6="${NAT_CHAIN6}"
DNSMASQ_USER="${DNSMASQ_USER}"

apply_rules() {
  # 1. IPv4 独立 NAT 链管理
  iptables -t nat -N "\${NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -F "\${NAT_CHAIN}"

  if [[ "\${TARGET_MODE}" == "host" ]]; then
    # 宿主机出网: 排除 dnsmasq 自身，将本机发出的 53 端口流量重定向至 DNS_PORT
    iptables -t nat -A "\${NAT_CHAIN}" -m owner --uid-owner "\${DNSMASQ_USER}" -j RETURN
    iptables -t nat -A "\${NAT_CHAIN}" -p udp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}"
    iptables -t nat -A "\${NAT_CHAIN}" -p tcp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}"
    if ! iptables -t nat -C OUTPUT -j "\${NAT_CHAIN}" 2>/dev/null; then
      iptables -t nat -I OUTPUT 1 -j "\${NAT_CHAIN}"
    fi
  else
    # 容器网桥模式: 拦截网桥进站的 53 端口流量
    iptables -t nat -A "\${NAT_CHAIN}" -i "\${BRIDGE_IF}" -p udp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}"
    iptables -t nat -A "\${NAT_CHAIN}" -i "\${BRIDGE_IF}" -p tcp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}"
    if ! iptables -t nat -C PREROUTING -j "\${NAT_CHAIN}" 2>/dev/null; then
      iptables -t nat -I PREROUTING 1 -j "\${NAT_CHAIN}"
    fi
  fi

  # 2. IPv6 独立 NAT 链管理 (若系统支持)
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -N "\${NAT_CHAIN6}" 2>/dev/null || true
    ip6tables -t nat -F "\${NAT_CHAIN6}" 2>/dev/null || true
    if [[ "\${TARGET_MODE}" == "host" ]]; then
      ip6tables -t nat -A "\${NAT_CHAIN6}" -m owner --uid-owner "\${DNSMASQ_USER}" -j RETURN 2>/dev/null || true
      ip6tables -t nat -A "\${NAT_CHAIN6}" -p udp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}" 2>/dev/null || true
      ip6tables -t nat -A "\${NAT_CHAIN6}" -p tcp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}" 2>/dev/null || true
      if ! ip6tables -t nat -C OUTPUT -j "\${NAT_CHAIN6}" 2>/dev/null; then
        ip6tables -t nat -I OUTPUT 1 -j "\${NAT_CHAIN6}" 2>/dev/null || true
      fi
    else
      ip6tables -t nat -A "\${NAT_CHAIN6}" -i "\${BRIDGE_IF}" -p udp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}" 2>/dev/null || true
      ip6tables -t nat -A "\${NAT_CHAIN6}" -i "\${BRIDGE_IF}" -p tcp --dport 53 -j REDIRECT --to-ports "\${DNS_PORT}" 2>/dev/null || true
      if ! ip6tables -t nat -C PREROUTING -j "\${NAT_CHAIN6}" 2>/dev/null; then
        ip6tables -t nat -I PREROUTING 1 -j "\${NAT_CHAIN6}" 2>/dev/null || true
      fi
    fi
  fi
}

remove_rules() {
  # 仅清理挂载点和独立链，绝不影响系统其他现有规则
  while iptables -t nat -C OUTPUT -j "\${NAT_CHAIN}" 2>/dev/null; do
    iptables -t nat -D OUTPUT -j "\${NAT_CHAIN}" || true
  done
  while iptables -t nat -C PREROUTING -j "\${NAT_CHAIN}" 2>/dev/null; do
    iptables -t nat -D PREROUTING -j "\${NAT_CHAIN}" || true
  done
  iptables -t nat -F "\${NAT_CHAIN}" 2>/dev/null || true
  iptables -t nat -X "\${NAT_CHAIN}" 2>/dev/null || true

  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t nat -C OUTPUT -j "\${NAT_CHAIN6}" 2>/dev/null; do
      ip6tables -t nat -D OUTPUT -j "\${NAT_CHAIN6}" 2>/dev/null || true
    done
    while ip6tables -t nat -C PREROUTING -j "\${NAT_CHAIN6}" 2>/dev/null; do
      ip6tables -t nat -D PREROUTING -j "\${NAT_CHAIN6}" 2>/dev/null || true
    done
    ip6tables -t nat -F "\${NAT_CHAIN6}" 2>/dev/null || true
    ip6tables -t nat -X "\${NAT_CHAIN6}" 2>/dev/null || true
  fi
}

case "\${1:-apply}" in
  apply) apply_rules ;;
  remove) remove_rules ;;
  *) echo "用法: \$0 apply|remove" >&2; exit 2 ;;
esac
EOF
  chmod 755 "${FW_SCRIPT}"
}

# ----------------- Systemd 服务配置 -----------------
generate_systemd_units() {
  local dnsmasq_bin
  dnsmasq_bin="$(command -v dnsmasq || echo /usr/sbin/dnsmasq)"

  cat >"${DNS_SERVICE}" <<EOF
[Unit]
Description=Site Policy dnsmasq daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${dnsmasq_bin} --keep-in-foreground --conf-file=${DNSMASQ_CONF}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat >"${FW_SERVICE}" <<EOF
[Unit]
Description=Site Policy firewall isolation rules
After=network.target network-online.target ufw.service firewalld.service iptables.service nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FW_SCRIPT} apply
ExecStop=${FW_SCRIPT} remove

[Install]
WantedBy=multi-user.target
EOF
}

# ----------------- 综合生成与服务控制 -----------------
generate_all() {
  load_config
  ensure_dirs
  ensure_dnsmasq_user
  if [[ "${ENABLE_HTTPS}" == "1" ]]; then
    generate_certificates
  fi
  generate_dnsmasq_conf
  generate_nginx_conf
  generate_firewall_script
  generate_systemd_units
}

restart_services() {
  log "正在启动/重启所有服务与防火墙规则..."
  systemctl daemon-reload
  nginx -t || die "Nginx 配置文件校验失败"
  systemctl enable --now nginx "${APP}-dns.service" "${APP}-firewall.service"
  systemctl restart "${APP}-dns.service"
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  systemctl restart "${APP}-firewall.service"
  log "所有服务与规则启动成功"
}

reload_services() {
  log "正在重载配置与刷新策略..."
  nginx -t || die "Nginx 配置文件语法检查不通过，取消重载"
  systemctl daemon-reload
  systemctl restart "${APP}-dns.service"
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  "${FW_SCRIPT}" apply 2>/dev/null || true
  log "配置重载完成"
}

install_policy() {
  need_root
  ensure_dirs
  install_packages
  load_config
  select_target_mode "${1:-}"
  save_config
  generate_all
  restart_services

  # 创建全局快捷命令 tj 与 site-policy
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")"
  chmod +x "${script_path}"
  ln -sf "${script_path}" /usr/local/bin/tj
  ln -sf "${script_path}" /usr/local/bin/site-policy

  log "安装与初始化完成！当前模式: ${TARGET_MODE}，落地 IP: ${LANDING_IP}，DNS 端口: ${DNS_PORT}"
  log "已创建快捷命令: tj (随时在终端任意路径输入 tj 即可打开管理菜单)"
}

# ----------------- 自检与诊断 -----------------
self_test() {
  load_config
  echo
  echo "=================================================="
  echo "                Site Policy 连通性自检             "
  echo "=================================================="
  # 1. 检查服务运行状态
  printf "1. DNS 守护进程状态 : "
  if systemctl is-active --quiet "${APP}-dns.service"; then
    printf "\033[32m[正常运行]\033[0m\n"
  else
    printf "\033[31m[异常未运行]\033[0m\n"
  fi

  printf "2. Nginx 服务状态    : "
  if systemctl is-active --quiet nginx; then
    printf "\033[32m[正常运行]\033[0m\n"
  else
    printf "\033[31m[未运行]\033[0m\n"
  fi

  printf "3. 防火墙独立链状态 : "
  if iptables -t nat -C OUTPUT -j "${NAT_CHAIN}" 2>/dev/null || iptables -t nat -C PREROUTING -j "${NAT_CHAIN}" 2>/dev/null; then
    printf "\033[32m[已正确挂载]\033[0m\n"
  else
    printf "\033[31m[未挂载]\033[0m\n"
  fi

  printf "4. HTTPS 本地 CA 状态: "
  if [[ "${ENABLE_HTTPS}" == "1" ]]; then
    if [[ -f "${SYSTEM_CA_FILE}" && -f "${SERVER_CERT}" ]]; then
      printf "\033[32m[已就绪并受系统信任]\033[0m\n"
    else
      printf "\033[33m[证书未完全生成]\033[0m\n"
    fi
  else
    printf "\033[34m[未开启]\033[0m\n"
  fi

  echo "--------------------------------------------------"
  echo "5. 规则实时拦截测试:"
  local sample_block sample_redir sample_target
  sample_block="$(head -n 1 "${BLOCK_LIST}" 2>/dev/null || true)"
  sample_redir="$(head -n 1 "${REDIRECT_LIST}" 2>/dev/null | awk '{print $1}' || true)"
  sample_target="$(head -n 1 "${REDIRECT_LIST}" 2>/dev/null | awk '{print $2}' || true)"

  if [[ -n "${sample_block}" ]]; then
    echo "  - 正在测试阻断域名 [${sample_block}]:"
    local res
    res="$(dig @127.0.0.1 -p "${DNS_PORT}" "${sample_block}" +short 2>/dev/null | head -n 1 || true)"
    echo "    DNS 解析结果: ${res:-无响应} (预期为: $( [[ "${BLOCK_MODE}" == "null" ]] && echo "0.0.0.0" || echo "${LANDING_IP}" ))"
  else
    echo "  - 暂无阻断域名可供测试"
  fi

  if [[ -n "${sample_redir}" ]]; then
    echo "  - 正在测试跳转域名 [${sample_redir} -> ${sample_target}]:"
    local res
    res="$(dig @127.0.0.1 -p "${DNS_PORT}" "${sample_redir}" +short 2>/dev/null | head -n 1 || true)"
    echo "    DNS 解析结果: ${res:-无响应} (预期为: ${LANDING_IP})"
  else
    echo "  - 暂无跳转域名可供测试"
  fi
  echo "=================================================="
}

# ----------------- 彻底卸载与本体自毁 -----------------
uninstall_policy() {
  need_root
  local force="${1:-}"
  local answer=""

  if [[ "${force}" != "--force" && -t 0 ]]; then
    echo
    echo -e "\033[31m警告: 彻底卸载将执行以下操作:\033[0m"
    echo "  1. 停止并禁用 site-policy 所有服务"
    echo "  2. 彻底清除 iptables / ip6tables 独立规则链，还原网络"
    echo "  3. 注销并从系统受信任库中移除本地 Root CA 证书"
    echo "  4. 删除所有策略配置文件、证书及 Nginx 扩展配置"
    echo "  5. 彻底删除当前脚本文件本身！"
    echo
    read -r -p "确认要彻底卸载并自毁吗？[y/N]: " answer || true
    if [[ ! "${answer:-}" =~ ^[Yy]$ ]]; then
      log "已取消卸载"
      return 0
    fi
  fi

  log "正在执行彻底卸载..."

  # 1. 停止并删除 systemd 服务
  systemctl stop "${APP}-firewall.service" "${APP}-dns.service" 2>/dev/null || true
  systemctl disable "${APP}-firewall.service" "${APP}-dns.service" 2>/dev/null || true
  rm -f "${DNS_SERVICE}" "${FW_SERVICE}"

  # 2. 清除防火墙规则
  if [[ -x "${FW_SCRIPT}" ]]; then
    "${FW_SCRIPT}" remove 2>/dev/null || true
  fi
  rm -f "${FW_SCRIPT}"

  # 3. 移除系统根证书并刷新
  if [[ -f "${SYSTEM_CA_FILE}" ]]; then
    rm -f "${SYSTEM_CA_FILE}"
    update-ca-certificates --fresh >/dev/null 2>&1 || true
  fi

  # 4. 移除 Nginx 独立配置并热重载 Nginx
  rm -f "${NGINX_CONF}"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  # 5. 删除策略配置目录与所有数据
  rm -rf "${BASE_DIR}"

  # 移除全局快捷命令
  rm -f /usr/local/bin/tj /usr/local/bin/site-policy

  systemctl daemon-reload

  log "所有服务、规则、证书与数据已彻底清除！"

  # 6. 自毁删除脚本文件自身
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ -f "${script_path}" ]]; then
    rm -f -- "${script_path}"
    log "脚本文件 [${script_path}] 已自毁删除。"
  fi
}

# ----------------- 交互式主菜单 -----------------
menu() {
  need_root
  ensure_dirs
  load_config

  while true; do
    echo
    echo "=================================================="
    echo "        网站访问策略管理控制台 (Site Policy)        "
    echo "=================================================="
    echo "  运行模式   : [${TARGET_MODE}] ($( [[ "${TARGET_MODE}" == "host" ]] && echo "宿主机出网拦截" || echo "容器网桥拦截: ${BRIDGE_IF}" ))"
    echo "  落地 IP    : ${LANDING_IP}"
    echo "  阻断模式   : [${BLOCK_MODE}] ($( [[ "${BLOCK_MODE}" == "null" ]] && echo "0.0.0.0 瞬断" || echo "403 提示页" ))"
    echo "  HTTPS 支持 : $( [[ "${ENABLE_HTTPS}" == "1" ]] && echo "[开启] (443 + CA 证书)" || echo "[关闭]" )"
    echo "  DNS 端口   : ${DNS_PORT}"
    echo "  快捷命令   : tj (在终端任意位置输入 tj 即可打开本菜单)"
    echo "--------------------------------------------------"
    echo "  1) 初始化安装 / 重新配置 (host/bridge)"
    echo "  2) 添加阻断域名 (DNS 阻断)"
    echo "  3) 添加跳转域名 (HTTP/HTTPS 302 跳转)"
    echo "  4) 删除域名规则"
    echo "  5) 查看当前生效策略与规则列表"
    echo "  6) 切换阻断响应模式 (0.0.0.0 瞬断 / 403 页面)"
    echo "  7) 切换 HTTPS 拦截支持开关 (开启/关闭 443 拦截)"
    echo "  8) 切换策略作用目标 (host 宿主机 / bridge 网桥)"
    echo "  9) 平滑热重载所有服务与规则 (Zero-Downtime)"
    echo " 10) 服务状态与连通性自检"
    echo "  u) 彻底卸载 (清除全部规则与证书并自毁脚本)"
    echo "  0) 退出菜单"
    echo "=================================================="
    read -r -p "请选择操作 [0-10, u]: " choice || true

    case "${choice:-0}" in
      1) install_policy ;;
      2)
        read -r -p "请输入要阻断的域名 (直接回车默认 ${DEFAULT_DOMAIN}): " d || true
        d="${d:-${DEFAULT_DOMAIN}}"
        add_block "${d}"
        ;;
      3)
        read -r -p "请输入要跳转的域名 (直接回车默认 ${DEFAULT_DOMAIN}): " d || true
        d="${d:-${DEFAULT_DOMAIN}}"
        read -r -p "请输入目标 URL (直接回车默认 ${DEFAULT_REDIRECT_URL}): " u || true
        u="${u:-${DEFAULT_REDIRECT_URL}}"
        add_redirect "${d}" "${u}"
        ;;
      4)
        read -r -p "请输入要删除的域名规则: " d || true
        delete_domain "${d}"
        ;;
      5) list_rules ;;
      6) set_block_mode ;;
      7) set_https_mode ;;
      8) set_target_mode ;;
      9) reload_services ;;
      10) self_test ;;
      u|U)
        uninstall_policy
        exit 0
        ;;
      0) exit 0 ;;
      *) echo "无效选项，请重新选择" ;;
    esac
    load_config
  done
}

# ----------------- CLI 命令行入口 -----------------
main() {
  local cmd="${1:-menu}"
  case "${cmd}" in
    install)
      install_policy "${2:-}"
      ;;
    menu)
      menu
      ;;
    add-block|block)
      need_root
      [[ $# -ge 2 ]] || die "用法: $0 add-block <DOMAIN>"
      add_block "$2"
      ;;
    add-redirect|redirect)
      need_root
      [[ $# -ge 3 ]] || die "用法: $0 add-redirect <DOMAIN> <TARGET_URL>"
      add_redirect "$2" "$3"
      ;;
    del|delete|remove)
      need_root
      [[ $# -ge 2 ]] || die "用法: $0 del <DOMAIN>"
      delete_domain "$2"
      ;;
    list)
      list_rules
      ;;
    block-mode)
      set_block_mode "${2:-}"
      ;;
    https-mode)
      set_https_mode "${2:-}"
      ;;
    target-mode)
      set_target_mode "${2:-}"
      ;;
    reload)
      need_root
      load_config
      generate_all
      reload_services
      ;;
    status|test)
      self_test
      ;;
    uninstall)
      uninstall_policy "${2:-}"
      ;;
    help|-h|--help)
      cat <<EOF
网站访问策略管理工具 (Site Policy v2.0)

快捷命令:
  tj                                      在终端任意路径直接打开中文管理菜单
  tj <子命令>                             执行任意子命令 (如 tj list, tj add-block ...)

常用用法:
  tj install [host|bridge]                初始化安装并配置模式
  tj menu                                 打开中文化交互菜单
  tj add-block <domain>                   添加阻断域名
  tj add-redirect <domain> <target_url>   添加跳转域名
  tj del <domain>                         删除指定域名规则
  tj list                                 列出所有规则与当前配置
  tj block-mode [null|page]               切换阻断响应模式
  tj https-mode [on|off]                  开启或关闭 HTTPS 拦截支持
  tj target-mode [host|bridge]            切换策略作用目标
  tj reload                               平滑热重载服务与规则
  tj test                                 服务运行状态与连通性自测
  tj uninstall [--force]                  彻底卸载清理并自毁脚本文件
EOF
      ;;
    *)
      err "未知命令: ${cmd}"
      echo "运行 $0 help 查看帮助"
      exit 2
      ;;
  esac
}

main "$@"
