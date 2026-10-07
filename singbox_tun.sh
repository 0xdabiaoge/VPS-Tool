#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# sing-box TUN 客户端一键安装与管理脚本
# ==============================================================================

INSTALL_DIR="/root/sing-box-install"
SB_BIN="/usr/local/bin/sing-box"
SB_IMPORT="/usr/local/sbin/sb-import-uri"
SB_MENU="/usr/local/sbin/sbmenu"
SB_LINK="/usr/local/bin/sb"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backups"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
readonly SB_CORE_VERSION="1.13.21"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行此脚本。"
  exit 1
fi

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$INSTALL_DIR"

# 基础依赖检测与安装
check_dependencies() {
  local missing=()
  local packages=() cmd package
  for cmd in curl tar gzip python3 ip ss nft flock sha256sum useradd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
      case "$cmd" in
        ip|ss) package="iproute2" ;;
        nft) package="nftables" ;;
        flock) package="util-linux" ;;
        sha256sum) package="coreutils" ;;
        useradd) package="passwd" ;;
        *) package="$cmd" ;;
      esac
      [[ " ${packages[*]} " == *" $package "* ]] || packages+=("$package")
    fi
  done
  if ((${#missing[@]} > 0)); then
    echo "检测到缺少必要依赖: ${missing[*]}，正在尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y "${packages[@]}" || return 1
    elif command -v yum >/dev/null 2>&1; then
      packages=("${packages[@]/iproute2/iproute}")
      packages=("${packages[@]/passwd/shadow-utils}")
      yum install -y "${packages[@]}" || return 1
    elif command -v dnf >/dev/null 2>&1; then
      packages=("${packages[@]/iproute2/iproute}")
      packages=("${packages[@]/passwd/shadow-utils}")
      dnf install -y "${packages[@]}" || return 1
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "${packages[@]}" || return 1
    fi
  fi
  for cmd in curl tar gzip python3 ip ss nft flock sha256sum useradd; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "缺少必要命令：$cmd"; return 1; }
  done
  command -v systemctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || {
    echo "本脚本需要运行 systemd 的 Linux 系统。"
    return 1
  }
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7*|armhf) echo "armv7" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    i386|i686) echo "386" ;;
    *) echo "不支持的系统架构：$arch" >&2; return 1 ;;
  esac
}

# 安装器与管理菜单共用：固定发布包的官方 SHA-256。
core_archive_sha256() {
  case "$1" in
    amd64) echo "24f9ef8e7234e13e71e74c3598a4164c5fe07b7b67ccc6e96cf68b54789f72cd" ;;
    arm64) echo "3e30b876c9a93c19e503e2a2d6249cf05e6a26766553d4b61e1daf48223f304f" ;;
    armv7) echo "a3edb2a40eeba461fa9c6e9e0fc97217e355154132a588abf89fc4f3f4d0240f" ;;
    s390x) echo "d58b74e57c0ffdcdc0f0d6e32583b4f9fc54ca26504809eaff5987a9f127187b" ;;
    riscv64) echo "7fb119979491aba1deb05491aeaf0b110d36e5670833a865500648981b1bce8d" ;;
    386) echo "d5e01a4df1e63116a2ca71d2aff3963e4e328699f9b284df521e08697864c67d" ;;
    *) return 1 ;;
  esac
}

# 核心安装：两个选项分别使用独立下载源，不跨源自动切换。
install_core_download() (
  local source="${1:-}" target_bin="$2"
  local arch pkg_name url work_dir bin_path version_output actual_version
  local expected_sha256 actual_sha256 staged_bin=""
  arch="$(detect_arch)" || return 1
  expected_sha256="$(core_archive_sha256 "$arch")" || return 1
  pkg_name="sing-box-${SB_CORE_VERSION}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SB_CORE_VERSION}/${pkg_name}"
  case "$source" in
    overseas) echo "下载方式：海外直连（GitHub 官方源）" ;;
    domestic) url="https://ghfast.top/${url}"; echo "下载方式：国内加速源（ghfast.top）" ;;
    local) echo "安装方式：离线官方压缩包" ;;
    *) echo "无效的下载源。"; return 1 ;;
  esac

  work_dir=$(mktemp -d "${TMPDIR:-/tmp}/sb_core.XXXXXX") || return 1
  trap 'rm -rf -- "$work_dir"; [[ -z "$staged_bin" ]] || rm -f -- "$staged_bin"' EXIT
  echo "固定核心版本：v${SB_CORE_VERSION}（架构：$arch）"
  echo "下载地址：$url"
  if [[ "$source" == local ]]; then
    cp -- "$3" "$work_dir/$pkg_name" || return 1
  elif ! curl -fSL --connect-timeout 10 --max-time 300 --retry 2 --retry-delay 2 "$url" -o "$work_dir/$pkg_name"; then
    echo "下载失败，请重新选择下载源，或使用离线压缩包安装。"
    return 1
  fi
  actual_sha256=$(sha256sum "$work_dir/$pkg_name" | awk '{print $1}')
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "安装包 SHA-256 校验失败，原有核心保留。"
    return 1
  fi
  mkdir -p "$work_dir/extracted" || return 1
  if ! tar -xzf "$work_dir/$pkg_name" -C "$work_dir/extracted"; then
    echo "安装包解压失败，原有核心保留。"
    return 1
  fi
  bin_path="$work_dir/extracted/sing-box-${SB_CORE_VERSION}-linux-${arch}/sing-box"
  if [[ ! -f "$bin_path" ]]; then
    echo "安装包中未找到对应版本和架构的 sing-box 核心。"
    return 1
  fi
  # The download temporary directory may be mounted noexec.
  staged_bin=$(mktemp "${target_bin}.new.XXXXXX") || return 1
  install -m 0755 "$bin_path" "$staged_bin" || return 1
  if ! version_output=$("$staged_bin" version 2>/dev/null); then
    echo "下载的核心无法在本机运行，原有核心保留。"
    return 1
  fi
  actual_version=$(printf '%s\n' "$version_output" | awk '/^sing-box version / {print $3; exit}')
  if [[ "$actual_version" != "$SB_CORE_VERSION" ]]; then
    echo "核心版本校验失败：要求 $SB_CORE_VERSION，实际 ${actual_version:-未知}。"
    return 1
  fi
  if [[ -s "$CONFIG_FILE" ]] && ! "$staged_bin" check -c "$CONFIG_FILE"; then
    echo "现有配置与 v${SB_CORE_VERSION} 不兼容，原有核心保留。"
    return 1
  fi
  # 原子替换，避免覆盖正在运行的可执行文件。
  mv -f -- "$staged_bin" "$target_bin" || return 1
  staged_bin=""
  echo "sing-box v${SB_CORE_VERSION} 已安装到 $target_bin，下载临时文件已自动清理。"
)

install_core_auto() {
  check_dependencies || return 1
  install_core_download "$1" "$SB_BIN"
}

# 核心安装：离线包同样固定版本，并校验官方 SHA-256。
install_core_local() {
  local arch package_name directory file selected="" choice
  arch="$(detect_arch)" || return 1
  package_name="sing-box-${SB_CORE_VERSION}-linux-${arch}.tar.gz"
  local archives=()
  for directory in "$PWD" "$(dirname "$SCRIPT_PATH")"; do
    file="$directory/$package_name"
    [[ -f "$file" ]] || continue
    file="$(readlink -f "$file")"
    [[ " ${archives[*]} " != *" $file "* ]] || continue
    archives+=("$file")
  done
  if (("${#archives[@]}" == 0)); then
    echo "未找到离线官方安装包：$package_name"
    return 1
  fi
  selected="${archives[0]}"
  if (("${#archives[@]}" > 1)); then
    local i
    for i in "${!archives[@]}"; do printf ' %d) %s\n' "$((i+1))" "${archives[$i]}"; done
    read -r -p "请选择离线安装包 [1-${#archives[@]}]：" choice || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#archives[@]})) || return 1
    selected="${archives[$((choice-1))]}"
  fi
  install_core_download local "$SB_BIN" "$selected"
}

# 核心安装引导
ensure_or_install_core() {
  if [[ -x "$SB_BIN" ]] && [[ "$("$SB_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')" == "$SB_CORE_VERSION" ]]; then
    return 0
  fi
  echo "========================================================"
  echo " 需要安装固定 v${SB_CORE_VERSION} 核心，请选择安装方式："
  echo "========================================================"
  echo " 1) 海外直连下载 v${SB_CORE_VERSION} (GitHub 官方源)"
  echo " 2) 国内加速源下载 v${SB_CORE_VERSION} (ghfast.top)"
  echo " 3) 安装离线官方 v${SB_CORE_VERSION} 压缩包 (校验 SHA-256)"
  echo " 0) 退出"
  echo "========================================================"
  local choice
  read -r -p "请输入选项 [0-3]：" choice
  case "$choice" in
    1) install_core_auto overseas ;;
    2) install_core_auto domestic ;;
    3) install_core_local ;;
    0) echo "已取消安装。"; exit 0 ;;
    *) echo "无效选项。"; exit 1 ;;
  esac
}

# 彻底卸载与清理（含自删除）
uninstall_everything() {
  echo "========================================================"
  echo " 警告：此操作将彻底卸载 sing-box，删除所有配置、备份"
  echo "       以及当前运行的脚本文件本身！"
  echo "========================================================"
  local confirm
  read -r -p "确认彻底卸载？[y/N] " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "已取消卸载。"; return 0 ;;
  esac

  echo "正在停止并清理 sing-box 服务..."
  systemctl stop sing-box || return 1
  systemctl disable sing-box 2>/dev/null || true
  
  # 清理可能存在的回滚定时器
  for timer in $(systemctl list-units --all --type=timer --plain --no-legend 'sing-box-import-rollback-*.timer' 2>/dev/null | awk '{print $1}' || true); do
    systemctl stop "$timer" 2>/dev/null || true
    systemctl stop "${timer%.timer}.service" 2>/dev/null || true
  done
  if [[ -x "$SB_IMPORT" ]]; then
    "$SB_IMPORT" --clear-network-guard || { echo "严格规则清理失败，停止卸载以保留恢复入口。"; return 1; }
  fi

  echo "正在清理相关文件与目录..."
  rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/multi-user.target.wants/sing-box.service
  systemctl disable --now sing-box-guard.service 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box-guard.service
  rm -f /etc/systemd/system/sing-box.service.d/10-network-guard.conf
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  rm -f "$SB_BIN" "$SB_IMPORT" "$SB_MENU" "$SB_LINK"
  rm -rf "$CONFIG_DIR" "$INSTALL_DIR"
  ip link delete singtun0 2>/dev/null || true

  echo "正在删除脚本自身..."
  if [[ -f "$SCRIPT_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi

  echo "========================================================"
  echo " sing-box 客户端及管理脚本已彻底卸载清理完毕！"
  echo "========================================================"
  exit 0
}

# 检查/引导安装核心
check_dependencies
exec 8>/run/sing-box-import.lock
flock -n 8 || { echo "节点导入/管理操作正在进行，请稍后重试。"; exit 1; }
if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall_everything
  exit 0
fi
ensure_or_install_core
if ! id singbox-tun >/dev/null 2>&1; then
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin singbox-tun
fi
[[ "$(id -u singbox-tun)" != 0 ]] || { echo "专用核心用户不能为 root。"; exit 1; }
chown root:singbox-tun "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"
chmod 0700 "$BACKUP_DIR" "$INSTALL_DIR"

# 1. 节点配置生成器：VLESS 纯 TCP、手填 SOCKS5、SS AES-GCM
cat <<'EOF' > "$SB_IMPORT"
#!/usr/bin/env python3
"""Build strict TUN configurations from supported node links or manual fields."""
import argparse
import base64
import copy
import contextlib
import fcntl
import glob
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid


def b64decode(text: str) -> str:
    text = urllib.parse.unquote(text.strip())
    text += "=" * (-len(text) % 4)
    return base64.b64decode(text.encode(), altchars=b"-_", validate=True).decode("utf-8")


SS_METHODS = {"aes-128-gcm", "aes-256-gcm"}


def server_value(value):
    if not isinstance(value, str):
        raise ValueError("服务器地址必须是 IP 或域名")
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    if not value or any(character.isspace() for character in value) or any(c in value for c in "/@?#\\"):
        raise ValueError("服务器地址只能填写 IP 或域名，不要包含协议或路径")
    if ":" in value:
        ipaddress.IPv6Address(value)
    return value


def uuid_value(value):
    try:
        return str(uuid.UUID(value.strip()))
    except (ValueError, AttributeError, TypeError):
        raise ValueError("VLESS UUID 格式无效") from None


def validate_node(outbound):
    """Enforce the supported protocol subset for imports AND restored/edited configs."""
    server_value(outbound.get("server"))
    port = outbound.get("server_port")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("节点端口必须是 1-65535 的整数")
    protocol = outbound.get("type")
    if protocol == "vless":
        uuid_value(outbound.get("uuid"))
        if any(key in outbound for key in ("tls", "transport", "flow", "multiplex")):
            raise ValueError("VLESS 仅支持无 TLS/Reality、无额外传输层的纯 TCP")
    elif protocol == "shadowsocks":
        if outbound.get("method") not in SS_METHODS:
            raise ValueError("SS 仅支持 aes-128-gcm 和 aes-256-gcm")
        if not isinstance(outbound.get("password"), str) or not outbound["password"]:
            raise ValueError("SS 密码不能为空")
        if any(key in outbound for key in ("plugin", "plugin_opts", "multiplex")):
            raise ValueError("不支持带插件或额外封装的 SS 配置")
    elif protocol == "socks":
        if outbound.get("version", "5") != "5":
            raise ValueError("仅支持 SOCKS5")
        username, password = outbound.get("username", ""), outbound.get("password", "")
        if not isinstance(username, str) or not isinstance(password, str) or bool(username) != bool(password):
            raise ValueError("SOCKS5 用户名和密码需同时填写，或同时留空")
        if type(outbound.get("udp_over_tcp", False)) is not bool:
            raise ValueError("SOCKS5 UDP-over-TCP 必须使用布尔值")
    else:
        raise ValueError("仅支持 VLESS 纯 TCP、SOCKS5、SS aes-128-gcm/aes-256-gcm")


def parse_vless(uri):
    u = urllib.parse.urlsplit(uri)
    q = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    if any(value.lower() not in {"", "tcp"} for key in ("type", "network") for value in q.get(key, [])):
        raise ValueError("当前仅支持 VLESS TCP 传输，不支持 WS/gRPC 等链接")
    if any(value.lower() not in {"", "none"} for key in ("security", "encryption", "headerType") for value in q.get(key, [])):
        raise ValueError("VLESS 仅支持无 TLS/Reality 的纯 TCP")
    if any(any(q.get(key, [])) for key in ("flow", "sni", "pbk", "sid", "fp", "alpn", "path", "serviceName", "tls")):
        raise ValueError("VLESS 纯 TCP 链接不能包含 TLS/Reality、flow 或其他传输参数")
    if not u.hostname or not u.port or not u.username:
        raise ValueError("VLESS 链接缺少服务器、端口或 UUID")
    if u.password is not None or u.path not in {"", "/"}:
        raise ValueError("VLESS 纯 TCP 链接不能包含密码或路径")
    out = {
        "type": "vless",
        "tag": "proxy",
        "server": u.hostname,
        "server_port": u.port,
        "uuid": uuid_value(urllib.parse.unquote(u.username))
    }
    validate_node(out)
    return out, u.hostname


def parse_ss(uri):
    if "plugin" in urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query, keep_blank_values=True):
        raise ValueError("当前不支持带 plugin 的 Shadowsocks 链接")
    body = uri[5:]
    body = body.split("#", 1)[0]
    if "?" in body:
        body, _ = body.split("?", 1)
    encoded_credentials = "@" not in body
    if encoded_credentials:
        body = b64decode(body)
    userinfo, hostport = body.rsplit("@", 1)
    if ":" not in userinfo:
        userinfo = b64decode(userinfo)
        encoded_credentials = True
    method, password = userinfo.split(":", 1)
    u = urllib.parse.urlsplit("ss://x@" + hostport)
    if not u.hostname or not u.port or u.path not in {"", "/"}:
        raise ValueError("Shadowsocks 链接缺少服务器或端口")
    out = {
        "type": "shadowsocks",
        "tag": "proxy",
        "server": u.hostname,
        "server_port": u.port,
        "method": method if encoded_credentials else urllib.parse.unquote(method),
        "password": password if encoded_credentials else urllib.parse.unquote(password),
    }
    validate_node(out)
    return out, u.hostname


def parse_manual(fields):
    protocol = fields.get("protocol", "")
    host = server_value(fields.get("server", ""))
    port = str(fields.get("port", "")).strip()
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError("节点端口必须是 1-65535 的整数")
    out = {
        "type": protocol,
        "tag": "proxy",
        "server": host,
        "server_port": int(port),
    }
    if protocol == "vless":
        out["uuid"] = uuid_value(fields.get("credential", ""))
    elif protocol == "shadowsocks":
        out.update(method=fields.get("method", ""), password=fields.get("password", ""))
    elif protocol == "socks":
        out["version"] = "5"
        username, password = fields.get("credential", ""), fields.get("password", "")
        if username or password:
            out.update(username=username, password=password)
        uot = fields.get("udp_over_tcp", "false").lower()
        if uot not in {"true", "false", ""}:
            raise ValueError("UDP-over-TCP 选项无效")
        if uot == "true":
            out["udp_over_tcp"] = True
    validate_node(out)
    return out, host


def read_manual(stream):
    values = stream.read().decode("utf-8").split("\0")
    if len(values) != 8 or values[-1] != "":
        raise ValueError("手动输入数据不完整")
    names = ("protocol", "server", "port", "credential", "password", "method", "udp_over_tcp")
    return parse_manual(dict(zip(names, values[:-1])))


def parse_uri(uri):
    scheme = uri.split(":", 1)[0].lower()
    if scheme in {"socks", "socks5"}:
        raise ValueError("SOCKS5 仅支持手动填写，请选择菜单中的 SOCKS5")
    parsers = {"vless": parse_vless, "ss": parse_ss}
    if scheme not in parsers:
        raise ValueError("链接导入仅支持 VLESS 纯 TCP 和 SS aes-128-gcm/aes-256-gcm")
    outbound, host = parsers[scheme](uri)
    return outbound, host


def resolve_endpoint(host):
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        return sorted({item[4][0] for item in infos}, key=lambda value: (ipaddress.ip_address(value).version, value))
    except socket.gaierror:
        return []


def command_output(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=4)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


CORE_USER = "singbox-tun"
CORE_BINARY = "/usr/local/bin/sing-box"
CONFIG_PATH = "/etc/sing-box/config.json"
POLICY_STATE = "/etc/sing-box/strict-policy.json"
GUARD_STATE = "/run/sing-box-ssh-guard.json"
GUARD_LOCK = "/run/sing-box-ssh-guard.lock"
GUARD_OWNER = "singbox-tun strict policy v1"
TUN_NAME = "singtun0"
TUN_TABLE = 2022
SSH_MARK = 0x53420001
REPLY_LABEL = 115  # nftables conntrack label number, not a numeric bitmask
WIRE_PRIORITY = 0x53420002  # SO_PRIORITY values above 6 require CAP_NET_ADMIN


def core_identity():
    uid = command_output(["id", "-u", CORE_USER]).strip()
    gid = command_output(["id", "-g", CORE_USER]).strip()
    if not uid.isdigit() or not gid.isdigit() or int(uid) == 0:
        raise ValueError("专用核心用户不存在，请重新运行安装脚本")
    return int(uid), int(gid)


def write_private_json(path, value, gid=None):
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".sb-policy-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            if gid is not None:
                os.fchown(stream.fileno(), 0, gid)
                os.fchmod(stream.fileno(), 0o640)
            else:
                os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_policy():
    if not os.path.isfile(POLICY_STATE):
        return {"armed": False}
    with open(POLICY_STATE) as stream:
        return json.load(stream)


def strict_rules():
    return [
        {"port": 53, "action": "hijack-dns"},
        {"network": "icmp", "action": "reject", "method": "drop"},
    ]


def validate_strict_config(config):
    uid, _ = core_identity()
    inbounds = config.get("inbounds", [])
    if len(inbounds) != 1:
        raise ValueError("请重新导入节点生成严格 TUN 配置")
    tun = inbounds[0]
    expected = {
        "type": "tun", "tag": "tun-in", "interface_name": TUN_NAME,
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1400,
        "auto_route": True, "auto_redirect": True, "strict_route": True,
        "iproute2_table_index": TUN_TABLE, "iproute2_rule_index": 9000,
        "exclude_uid": [uid], "stack": "mixed",
    }
    if tun != expected:
        raise ValueError("TUN 必须启用双栈严格路由，且只能排除专用核心 UID")
    outbounds = config.get("outbounds", [])
    if len(outbounds) != 1 or outbounds[0].get("tag") != "proxy":
        raise ValueError("严格配置只允许一个 proxy 出站，禁止 direct/回退出站")
    proxy = outbounds[0]
    validate_node(proxy)
    ipaddress.ip_address(proxy["server"])
    port = proxy.get("server_port")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("节点端口无效")
    if proxy.get("detour") or proxy.get("routing_mark") or proxy.get("netns"):
        raise ValueError("节点底层连接不能指定额外旁路或网络命名空间")
    interface = proxy.get("bind_interface", "")
    if not interface or interface == TUN_NAME:
        raise ValueError("节点必须绑定原始出口网卡")
    if config.get("route") != {"auto_detect_interface": True, "rules": strict_rules(), "final": "proxy"}:
        raise ValueError("禁止自定义旁路、规则集或直连路由")
    if config.get("dns") != {
        "servers": [{"type": "https", "tag": "dns-proxy", "server": "1.1.1.1",
                     "server_port": 443, "path": "/dns-query", "detour": "proxy",
                     "tls": {"enabled": True, "server_name": "cloudflare-dns.com"}}],
        "strategy": "prefer_ipv4", "final": "dns-proxy",
    }:
        raise ValueError("DNS 必须通过 proxy 的 DoH 解析，禁止直连 DNS")
    if config.get("endpoints") or config.get("services") or config.get("experimental"):
        raise ValueError("严格配置禁止额外端点、服务或实验性 API")
    return proxy


def policy_from_config(config):
    proxy = validate_strict_config(config)
    uid, _ = core_identity()
    return {
        "version": 1, "armed": True, "uid": uid, "ssh_ports": detect_ssh_ports(),
        "endpoints": [{"ip": str(ipaddress.ip_address(proxy["server"])),
                       "port": proxy["server_port"], "type": proxy["type"]}],
    }


def nft_table_exists(family, name):
    result = subprocess.run(["nft", "-j", "list", "table", family, name],
                            capture_output=True, text=True, timeout=5)
    if result.returncode:
        return False
    data = json.loads(result.stdout)
    tables = [item["table"] for item in data.get("nftables", []) if "table" in item]
    # nft 1.0.x JSON does not emit table comments; an unhooked sentinel is portable.
    owned = any(item.get("rule", {}).get("chain") == "owner"
                and item["rule"].get("comment") == GUARD_OWNER for item in data.get("nftables", []))
    if not tables or not owned:
        raise ValueError(f"nftables 表 {family} {name} 已被其他程序占用")
    return True


def firewall_script(policy, devices, existing=()):
    """Independent wire filter: established traffic is never broadly exempted."""
    uid = int(policy["uid"])
    ports = sorted({int(port) for port in policy["ssh_ports"]})
    if not ports or any(not 1 <= port <= 65535 for port in ports):
        raise ValueError("SSH 保护端口无效")
    port_set = "{ " + ", ".join(map(str, ports)) + " }"
    allow = [
        f"meta l4proto tcp tcp sport {port_set} ct mark {SSH_MARK:#x} accept",
        f"meta skuid {uid} ct direction reply ct status dnat meta l4proto {{ tcp, udp }} accept",
        f"ct direction reply ct label & {REPLY_LABEL} == {REPLY_LABEL} meta l4proto {{ tcp, udp }} accept",
        # Underlay maintenance is not proxyable application traffic.
        # DHCP discovery AND unicast renewal must survive a failed proxy.
        "meta nfproto ipv4 meta l4proto udp udp sport 68 udp dport 67 accept",
        "meta nfproto ipv6 meta l4proto udp udp sport 546 udp dport 547 accept",
        "meta l4proto ipv6-icmp icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } ip6 hoplimit 255 accept",
    ]
    for endpoint in policy["endpoints"]:
        address = ipaddress.ip_address(endpoint["ip"])
        family = "ip6" if address.version == 6 else "ip"
        port = int(endpoint["port"])
        if not 1 <= port <= 65535:
            raise ValueError("节点端口无效")
        # TUIC is only retained here to restore an old armed guard safely.
        # New nodes/configurations cannot select it: validate_node rejects it.
        protocols = "{ tcp, udp }" if endpoint["type"] in {"shadowsocks", "socks"} else ("udp" if endpoint["type"] == "tuic" else "tcp")
        if endpoint["type"] == "socks":
            # Standard SOCKS5 may allocate a separate UDP relay port at the same IP.
            allow.append(f"meta skuid {uid} {family} daddr {address} meta l4proto udp accept")
            protocols = "tcp"
        allow.append(f"meta skuid {uid} {family} daddr {address} meta l4proto {protocols} th dport {port} accept")
    lines = [f"delete table {family} {name}" for family, name in existing]
    lines += [
        'table inet sb_strict {',
        f'  comment {json.dumps(GUARD_OWNER)}',
        f'  chain owner {{ counter comment {json.dumps(GUARD_OWNER)}; }}',
        '  chain classify { type filter hook prerouting priority -140; policy accept;',
        f'    fib daddr type local meta l4proto tcp tcp dport {port_set} ct mark set {SSH_MARK:#x}',
        f'    iifname "{TUN_NAME}" meta l4proto {{ tcp, udp }} ct label set ct label | {REPLY_LABEL}',
        '  }',
        '  chain output { type filter hook output priority 200; policy drop;',
        '    oifname "lo" accept',
        # Auto-redirect DNAT is rerouted after OUTPUT, including bound sockets.
        # These packets get no wire tag and cannot escape on a physical device.
        '    ip daddr 127.0.0.0/8 meta l4proto tcp accept',
        '    ip6 daddr ::1 meta l4proto tcp accept',
        f'    oifname "{TUN_NAME}" meta l4proto {{ tcp, udp }} accept',
    ]
    # Socket UID is available at OUTPUT but may be detached before POSTROUTING.
    lines += ["    " + rule.removesuffix("accept") + f"meta priority set {WIRE_PRIORITY:#x} accept" for rule in allow]
    lines += [
        '  }',
        '  chain forward { type filter hook forward priority 200; policy drop;',
        f'    oifname "{TUN_NAME}" meta l4proto {{ tcp, udp }} accept',
        f'    iifname "{TUN_NAME}" meta l4proto {{ tcp, udp }} accept',
        '  }',
        '  chain tag_wire { type filter hook postrouting priority 300; policy accept;',
        f'    oifname {{ "lo", "{TUN_NAME}" }} return',
    ]
    lines += ["    " + rule.removesuffix("accept") + f"meta priority set {WIRE_PRIORITY:#x} accept" for rule in allow]
    lines += [
        '  }',
        '}',
        'table netdev sb_strict_wire {',
        f'  comment {json.dumps(GUARD_OWNER)}',
        f'  chain owner {{ counter comment {json.dumps(GUARD_OWNER)}; }}',
    ]
    for index, device in enumerate(devices):
        if device in {"lo", TUN_NAME}:
            continue
        lines += [f'  chain wire_{index} {{ type filter hook egress device {json.dumps(device)} priority 0; policy drop;',
                  '    ether type arp accept',
                  f'    meta priority {WIRE_PRIORITY:#x} accept']
        lines += ["  }"]
    lines += ["}"]
    return "\n".join(lines) + "\n"


def apply_firewall(policy):
    devices = [item["ifname"] for item in json.loads(command_output(["ip", "-j", "link", "show"]) or "[]")]
    if not devices:
        raise ValueError("无法读取网卡，拒绝启动严格代理")
    existing = [(family, name) for family, name in
                [("inet", "sb_strict"), ("netdev", "sb_strict_wire")]
                if nft_table_exists(family, name)]
    script = firewall_script(policy, devices, existing)
    for argv in (["nft", "-c", "-f", "-"], ["nft", "-f", "-"]):
        subprocess.run(argv, input=script, check=True, text=True, capture_output=True, timeout=12)


def check_runtime(config):
    """Check kernel/nft compatibility before staging a node or arming policy."""
    policy = policy_from_config(config)
    check_route_conflicts(policy, ignore_owned=True)
    devices = [item["ifname"] for item in json.loads(command_output(["ip", "-j", "link", "show"]) or "[]")]
    if not devices:
        raise ValueError("无法读取网卡，拒绝启用严格代理")
    existing = [(family, name) for family, name in
                [("inet", "sb_strict"), ("netdev", "sb_strict_wire")]
                if nft_table_exists(family, name)]
    subprocess.run(["nft", "-c", "-f", "-"], input=firewall_script(policy, devices, existing),
                   check=True, text=True, capture_output=True, timeout=12)


def remove_firewall():
    existing = [(family, name) for family, name in
                [("inet", "sb_strict"), ("netdev", "sb_strict_wire")]
                if nft_table_exists(family, name)]
    if existing:
        subprocess.run(["nft", "-f", "-"], input="\n".join(f"delete table {family} {name}" for family, name in existing) + "\n",
                       check=True, text=True, capture_output=True, timeout=12)


def clear_owned_rules():
    if not os.path.isfile(GUARD_STATE):
        return
    with open(GUARD_STATE) as stream:
        records = json.load(stream)
    remaining = []
    for record in records:
        if "args" in record:
            args = record["args"]
        else:  # Migrate only the exact SSH rules recorded by the older installer.
            args = ["ip", record["family"], "rule", "add", "pref", str(record["priority"]),
                    "ipproto", "tcp", "sport", str(record["port"]), "lookup", "main"]
        deletion = list(args)
        deletion[3] = "del"
        result = subprocess.run(deletion, capture_output=True, text=True, timeout=5)
        if result.returncode and "No such" not in result.stderr and "Cannot find" not in result.stderr:
            remaining.append(record)
    if remaining:
        write_private_json(GUARD_STATE, remaining)
        raise ValueError("部分自有路由规则无法清理，严格保护仍保留")
    os.unlink(GUARD_STATE)


def policy_selectors(policy, family):
    uid = int(policy["uid"])
    selectors = [
        ["uidrange", f"{uid}-{uid}", "lookup", "main"],
        ["iif", TUN_NAME, "lookup", "main"],
    ]
    selectors += [["ipproto", "tcp", "sport", str(port), "lookup", "main"] for port in policy["ssh_ports"]]
    # DHCP clients need the underlay even when the TUN has no usable route.
    maintenance = {
        "-4": ["ipproto", "udp", "sport", "68", "dport", "67", "lookup", "main"],
        "-6": ["ipproto", "udp", "sport", "546", "dport", "547", "lookup", "main"],
    }
    # An early unreachable rule prevents Linux from validating TUN gateways while
    # sing-box creates routes. The independent wire firewall closes this gap.
    return selectors + [maintenance[family], ["lookup", str(TUN_TABLE)]]


def check_route_conflicts(policy, ignore_owned=False):
    owned = {}
    if ignore_owned and os.path.isfile(GUARD_STATE):
        with open(GUARD_STATE) as stream:
            for record in json.load(stream):
                args = record.get("args", [])
                family = args[1] if args else record["family"]
                priority = int(args[5]) if args else int(record["priority"])
                key = (family, priority)
                owned[key] = owned.get(key, 0) + 1
    for family in ("-4", "-6"):
        selectors = policy_selectors(policy, family)
        rules_output = command_output(["ip", "-j", family, "rule", "show"])
        if not rules_output:
            raise ValueError("无法读取策略路由，拒绝启用严格代理")
        current = json.loads(rules_output)
        for rule in current:
            priority = int(rule.get("priority", 0))
            key = (family, priority)
            if owned.get(key, 0):
                owned[key] -= 1
                continue
            if is_running_singbox_loopback_rule(rule, family):
                continue
            if (priority == 0 and rule.get("table") not in {"local", 255}) or 0 < priority <= len(selectors):
                raise ValueError("现有策略路由占用了最前面的优先级，拒绝启动以避免旁路；请先人工整理")
        routes = json.loads(command_output(["ip", "-j", family, "route", "show", "table", str(TUN_TABLE)]) or "[]")
        if any(route.get("dev") not in {None, TUN_NAME} for route in routes):
            raise ValueError("TUN 路由表已被其他程序占用，拒绝覆盖")


def is_running_singbox_loopback_rule(rule, family):
    """Ignore only sing-box's active auto-route rule for its loopback-only table."""
    try:
        if int(rule.get("priority", -1)) != 1:
            return False
        table = str(rule.get("table", ""))
        if not table.isdigit() or int(table) in {0, 253, 254, 255, TUN_TABLE}:
            return False
        forbidden = {"fwmark", "fwmask", "iif", "oif", "uidrange", "ipproto", "sport", "dport", "goto", "l3mdev"}
        if forbidden.intersection(rule):
            return False
        any_source = {None, "all", "0.0.0.0/0" if family == "-4" else "::/0"}
        if rule.get("src") not in any_source or rule.get("dst") not in any_source:
            return False
        if not command_output(["ip", "-j", "link", "show", "dev", TUN_NAME]):
            return False
        active = subprocess.run(["systemctl", "is-active", "--quiet", "sing-box"],
                                capture_output=True, text=True, timeout=3)
        if active.returncode != 0:
            return False
        routes = json.loads(command_output(["ip", "-j", family, "route", "show", "table", table]) or "[]")
        loopback = "127.0.0.1" if family == "-4" else "::1"
        return len(routes) == 1 and routes[0].get("type") == "local" \
            and routes[0].get("dst") == loopback and routes[0].get("dev") not in {None, "lo", TUN_NAME}
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return False


def install_owned_rules(policy):
    clear_owned_rules()
    check_route_conflicts(policy)
    installed = []
    write_private_json(GUARD_STATE, installed)
    try:
        for family in ("-4", "-6"):
            selectors = policy_selectors(policy, family)
            for priority, selector in enumerate(selectors, 1):
                args = ["ip", family, "rule", "add", "pref", str(priority)] + selector
                subprocess.run(args, check=True, capture_output=True, text=True, timeout=5)
                installed.append({"args": args})
                write_private_json(GUARD_STATE, installed)
    except Exception:
        clear_owned_rules()
        raise


def network_guard(clear=False, restore=False):
    if os.geteuid() != 0:
        raise ValueError("严格网络保护需要 root 权限")
    with open(GUARD_LOCK, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if clear:
            # Only explicit menu stop/reset/uninstall calls this path.
            clear_owned_rules()
            remove_firewall()
            write_private_json(POLICY_STATE, {"armed": False})
            return
        if restore:
            policy = read_policy()
            if not policy.get("armed"):
                return
        else:
            with open(CONFIG_PATH) as stream:
                config = json.load(stream)
            policy = policy_from_config(config)
        # Persist before enforcing; crashes/restarts cannot turn protection off.
        write_private_json(POLICY_STATE, policy)
        apply_firewall(policy)
        install_owned_rules(policy)


@contextlib.contextmanager
def allow_probe(config):
    candidate = policy_from_config(config)["endpoints"][0]
    active = False
    with open(GUARD_LOCK, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        policy = read_policy()
        if policy.get("armed"):
            temporary = copy.deepcopy(policy)
            if candidate not in temporary["endpoints"]:
                temporary["endpoints"].append(candidate)
                apply_firewall(temporary)
                active = True
    try:
        yield
    finally:
        if active:
            with open(GUARD_LOCK, "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                policy = read_policy()
                if policy.get("armed"):
                    apply_firewall(policy)


def recover_config(backup, was_active, was_armed):
    with open(backup) as stream:
        previous = json.load(stream)
    if was_armed:
        validate_strict_config(previous)
        _, gid = core_identity()
        write_private_json(CONFIG_PATH, previous, gid)
        network_guard()
        subprocess.run(["systemctl", "restart" if was_active else "stop", "sing-box"], check=True, timeout=30)
    else:
        # A first activation failure must never restore a direct configuration.
        subprocess.run(["systemctl", "stop", "sing-box"], check=True, timeout=30)
        if not read_policy().get("armed"):
            network_guard()
        print("严格代理未确认/启动失败：业务仍被阻断；请重试节点或通过菜单主动关闭。")


def reset_config():
    if read_policy().get("armed"):
        raise ValueError("请先主动关闭严格代理，再重置配置")
    _, gid = core_identity()
    write_private_json(CONFIG_PATH, {
        "log": {"level": "info", "timestamp": True}, "inbounds": [],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct"},
    }, gid)


def detect_ssh_ports():
    ports = set()
    ssh_conn = os.environ.get("SSH_CONNECTION", "")
    if ssh_conn:
        parts = ssh_conn.split()
        if len(parts) >= 4 and parts[3].isdigit():
            ports.add(int(parts[3]))
    
    config_files = ["/etc/ssh/sshd_config"] + glob.glob("/etc/ssh/sshd_config.d/*.conf")
    for cf in config_files:
        if os.path.isfile(cf):
            try:
                with open(cf, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith("#") and line.lower().startswith("port "):
                            p = line.split()[1]
                            if p.isdigit():
                                ports.add(int(p))
            except Exception:
                pass
                
    try:
        res = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True, timeout=2)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "sshd" in line:
                    parts = line.split()
                    if len(parts) >= 4:
                        addr = parts[3]
                        port_str = addr.rsplit(":", 1)[-1]
                        if port_str.isdigit():
                            ports.add(int(port_str))
    except Exception:
        pass

    return sorted(ports or {22})


def build_config(outbound, endpoint_host):
    endpoint_ips = resolve_endpoint(endpoint_host)
    if not endpoint_ips:
        raise ValueError("节点地址无法解析，请检查 DNS 或节点地址")
    uid, _ = core_identity()
    outbound = copy.deepcopy(outbound)
    # Pin the transport IP before enabling strict DNS, preventing bootstrap loops.
    outbound["server"] = endpoint_ips[0]
    family = "-6" if ":" in endpoint_ips[0] else "-4"
    routes = json.loads(command_output(["ip", "-j", family, "route", "get", endpoint_ips[0], "uid", str(uid)]) or "[]")
    interface = routes[0].get("dev", "") if routes else ""
    if not interface or interface in {"lo", TUN_NAME}:
        raise ValueError("找不到通向节点的原始出口网卡")
    outbound["bind_interface"] = interface
    ssh_ports = detect_ssh_ports()
    config = {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [{"type": "https", "tag": "dns-proxy", "server": "1.1.1.1",
                         "server_port": 443, "path": "/dns-query", "detour": "proxy",
                         "tls": {"enabled": True, "server_name": "cloudflare-dns.com"}}],
            "strategy": "prefer_ipv4", "final": "dns-proxy",
        },
        "inbounds": [{
            "type": "tun", "tag": "tun-in", "interface_name": TUN_NAME,
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1400,
            "auto_route": True, "auto_redirect": True, "strict_route": True,
            "iproute2_table_index": TUN_TABLE, "iproute2_rule_index": 9000,
            "exclude_uid": [uid], "stack": "mixed",
        }],
        "outbounds": [outbound],
        "route": {"auto_detect_interface": True, "rules": strict_rules(), "final": "proxy"},
    }
    validate_strict_config(config)
    return config, endpoint_ips, ssh_ports


def query_exit(url, socks_port=None):
    argv = ["curl", "--proxy", "", "--noproxy", "", "-4fsS", "--connect-timeout", "4", "--max-time", "10"]
    if socks_port is not None:
        argv += ["--socks5-hostname", "127.0.0.1:" + str(socks_port)]
    result = subprocess.run(argv + [url], capture_output=True, text=True, timeout=12)
    if result.returncode != 0:
        raise ValueError("出口请求失败")
    address = ipaddress.ip_address(result.stdout.strip())
    if address.version != 4 or not address.is_global:
        raise ValueError("出口查询未返回公网 IPv4")
    return str(address)


def probe_proxy(path):
    """仅通过 loopback SOCKS 实测节点，成功之前不创建 TUN。"""
    with open(path) as f:
        config = copy.deepcopy(json.load(f))
    original_config = copy.deepcopy(config)
    uid, gid = core_identity()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config["inbounds"] = [{"type": "mixed", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": port}]
    config["route"] = {"auto_detect_interface": True, "final": "proxy"}
    config["log"] = {"level": "error", "timestamp": True}
    with allow_probe(original_config), tempfile.TemporaryDirectory(prefix="sing-box-probe-") as work:
        os.chown(work, uid, gid)
        probe_path = os.path.join(work, "config.json")
        fd = os.open(probe_path, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(config, f)
        os.chown(probe_path, uid, gid)
        def drop_privileges():
            os.setgroups([])
            os.setgid(gid)
            os.setuid(uid)
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen([CORE_BINARY, "run", "-c", probe_path], stdout=log, stderr=log, preexec_fn=drop_privileges)
            try:
                for _ in range(30):
                    if process.poll() is not None:
                        raise ValueError("节点预检代理启动失败")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise ValueError("节点预检代理启动超时")
                for url in ["https://api.ipify.org", "https://api.ip.sb/ip"]:
                    try:
                        return {"verified_exit_ipv4": query_exit(url, port), "probe_url": url}
                    except (ValueError, subprocess.TimeoutExpired):
                        pass
                log.seek(0)
                detail = re.sub(r"\x1b\[[0-9;]*m", "", log.read())[-1200:].strip()
                raise ValueError("节点预检失败，未改变当前配置和路由。" + ("\n" + detail if detail else "请检查节点是否可用。"))
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def verify_exit(meta_path):
    with open(meta_path) as f:
        meta = json.load(f)
    expected = meta["verified_exit_ipv4"]
    urls = [meta["probe_url"]]
    urls.extend(url for url in ("https://api.ipify.org", "https://api.ip.sb/ip") if url not in urls)
    last_error = None
    for url in urls:
        for attempt in range(2):
            try:
                current = query_exit(url)
            except (ValueError, subprocess.TimeoutExpired) as exc:
                last_error = exc
                if attempt == 0:
                    time.sleep(1)
                continue
            if current != expected:
                raise ValueError(f"TUN 出口 {current} 与节点预检出口 {expected} 不一致")
            return current
    raise ValueError("TUN 出口请求失败，已重试并切换查询站点。" + (f"\n{last_error}" if last_error else ""))


def main():
    os.umask(0o077)
    ap = argparse.ArgumentParser()
    actions = ap.add_mutually_exclusive_group()
    actions.add_argument("--uri")
    actions.add_argument("--uri-stdin", action="store_true")
    actions.add_argument("--manual-stdin", action="store_true", help="从标准输入读取菜单发送的 NUL 分隔手动字段")
    actions.add_argument("--probe", metavar="CONFIG")
    actions.add_argument("--verify-exit", metavar="META")
    actions.add_argument("--apply-network-guard", action="store_true")
    actions.add_argument("--clear-network-guard", action="store_true")
    actions.add_argument("--restore-network-guard", action="store_true")
    actions.add_argument("--validate-strict", metavar="CONFIG")
    actions.add_argument("--check-runtime", metavar="CONFIG")
    actions.add_argument("--stage-config", metavar="CONFIG")
    actions.add_argument("--policy-status", action="store_true")
    actions.add_argument("--recover-config", metavar="BACKUP")
    actions.add_argument("--reset-config", action="store_true")
    ap.add_argument("--previous-active", choices=["true", "false"], default="false")
    ap.add_argument("--previous-armed", choices=["true", "false"], default="false")
    ap.add_argument("--output")
    ap.add_argument("--meta")
    ap.add_argument("--expected-type", choices=["vless", "shadowsocks", "socks"])
    ap.add_argument("--expected-method", choices=sorted(SS_METHODS))
    args = ap.parse_args()
    try:
        if args.apply_network_guard or args.clear_network_guard or args.restore_network_guard:
            network_guard(clear=args.clear_network_guard, restore=args.restore_network_guard)
            return 0
        if args.reset_config:
            reset_config()
            return 0
        if args.stage_config:
            with open(args.stage_config) as stream:
                config = json.load(stream)
            validate_strict_config(config)
            _, gid = core_identity()
            write_private_json(CONFIG_PATH, config, gid)
            return 0
        if args.check_runtime:
            with open(args.check_runtime) as stream:
                check_runtime(json.load(stream))
            return 0
        if args.validate_strict:
            with open(args.validate_strict) as stream:
                validate_strict_config(json.load(stream))
            return 0
        if args.policy_status:
            print("armed" if read_policy().get("armed") else "off")
            return 0
        if args.recover_config:
            recover_config(args.recover_config, args.previous_active == "true", args.previous_armed == "true")
            return 0
        if args.verify_exit:
            print(verify_exit(args.verify_exit))
            return 0
        if args.probe:
            verified = probe_proxy(args.probe)
            if args.meta:
                with open(args.meta) as f:
                    meta = json.load(f)
                meta.update(verified)
                with open(args.meta, "w") as f:
                    json.dump(meta, f, ensure_ascii=False, indent=2)
            print(verified["verified_exit_ipv4"])
            return 0
        if not args.output or not (args.uri or args.uri_stdin or args.manual_stdin):
            ap.error("生成配置需要 --output 和节点链接或 --manual-stdin")
        if args.manual_stdin:
            outbound, host = read_manual(sys.stdin.buffer)
        else:
            uri = sys.stdin.readline().strip() if args.uri_stdin else args.uri.strip()
            outbound, host = parse_uri(uri)
        if args.expected_type and outbound["type"] != args.expected_type:
            raise ValueError("节点协议与菜单选择不一致，请重新选择")
        if args.expected_method and outbound.get("method") != args.expected_method:
            raise ValueError("SS 加密方式与菜单选择不一致，请重新选择")
        config, ips, ssh_ports = build_config(outbound, host)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=2)
            f.write("\n")
        if args.meta:
            with open(args.meta, "w", encoding="utf-8") as f:
                json.dump({
                    "protocol": outbound["type"],
                    "server": host,
                    "server_port": outbound["server_port"],
                    "method": outbound.get("method", ""),
                    "endpoint_ips": ips,
                    "selected_endpoint": config["outbounds"][0]["server"],
                    "ssh_ports": ssh_ports,
                    "mode": "strict-global",
                    "dns": "DoH through proxy",
                    "udp_note": "SOCKS5 异 IP 的动态 UDP 中继会被阻断" if outbound["type"] == "socks" else ""
                }, f, ensure_ascii=False, indent=2)
                f.write("\n")
    except Exception as exc:
        detail = exc.stderr.strip()[-1500:] if isinstance(exc, subprocess.CalledProcessError) and exc.stderr else str(exc)
        print(f"操作失败：{detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOF

chmod 0755 "$SB_IMPORT"

# 2. 写入 Bash 中文交互式菜单
cat <<'EOF' > "$SB_MENU"
#!/usr/bin/env bash
set -u
umask 077

CONFIG="/etc/sing-box/config.json"
CONFIG_FILE="$CONFIG"
CONFIG_DIR="/etc/sing-box"
BACKUP_DIR="/etc/sing-box/backups"
INSTALL_DIR="/root/sing-box-install"
SERVICE="sing-box"
BIN="/usr/local/bin/sing-box"
SB_BIN="$BIN"
SB_IMPORT="/usr/local/sbin/sb-import-uri"
SB_MENU="/usr/local/sbin/sbmenu"
SB_LINK="/usr/local/bin/sb"
SCRIPT_INSTALLER="/root/sing-box-install/singbox_tun.sh"
SCRIPT_PATH="$SCRIPT_INSTALLER"
EOF
# 复用相同的版本、架构识别和下载实现，避免安装与更新逻辑漂移。
printf 'readonly SB_CORE_VERSION=%q\n' "$SB_CORE_VERSION" >> "$SB_MENU"
declare -f detect_arch core_archive_sha256 install_core_download install_core_local >> "$SB_MENU"
cat <<'EOF' >> "$SB_MENU"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行。"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

acquire_config_lock() {
  [[ "${SB_CONFIG_LOCKED:-false}" == true ]] && return 0
  exec 9>/run/sing-box-import.lock || return 1
  export SB_CONFIG_LOCKED=true
  flock -n 9 || { echo "另一个导入/管理操作正在进行，请稍后重试。"; return 1; }
}

pause() {
  echo
  read -r -p "按回车键返回菜单..." _
}

line() {
  printf '%*s\n' 60 '' | tr ' ' '='
}

service_state() {
  local active enabled
  active=$(systemctl is-active "$SERVICE" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)
  [[ "$active" == "active" ]] && active="运行中" || active="已停止"
  [[ "$enabled" == "enabled" ]] && enabled="开机自启" || enabled="未自启"
  printf '%s / %s' "$active" "$enabled"
}

detect_ssh_ports() {
  local ports=()
  local p
  for p in $(ss -tlnp 2>/dev/null | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -un); do
    [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
  done
  if ((${#ports[@]} == 0)); then
    ports=("22")
  fi
  echo "${ports[*]}"
}

show_header() {
  clear 2>/dev/null || true
  line
  echo "           sing-box TUN 中文交互式管理菜单"
  line
  echo " 核心版本：$($BIN version 2>/dev/null | head -n1 | sed 's/sing-box version //')"
  echo " 运行状态：$(service_state)"
  echo " 放行 SSH：$(detect_ssh_ports)"
  echo " 严格保护：$("$SB_IMPORT" --policy-status 2>/dev/null || echo unknown)"
  echo " 配置文件：$CONFIG"
  line
}

backup_config() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "当前无配置文件，无需备份。"
    return 0
  fi
  local dst
  dst="$BACKUP_DIR/config.json.$(date +%Y%m%d-%H%M%S).bak"
  cp -a "$CONFIG" "$dst"
  echo "已备份到：$dst"
}

edit_config() (
  acquire_config_lock || return 1
  backup_config || return 1
  "${EDITOR:-nano}" "$CONFIG"
  echo
  if "$SB_IMPORT" --validate-strict "$CONFIG" && "$BIN" check -c "$CONFIG"; then
    "$SB_IMPORT" --stage-config "$CONFIG" || return 1
    echo "配置语法检查通过。"
    read -r -p "是否立即重启并应用？[Y/n] " answer
    case "${answer:-Y}" in
      y|Y|yes|YES) restart_service ;;
      *) echo "暂未应用，可稍后在菜单中选择重启。" ;;
    esac
  else
    echo "配置检查失败，服务未重启。请重新编辑或恢复备份。"
    return 1
  fi
)

check_config() {
  "$SB_IMPORT" --validate-strict "$CONFIG" || return 1
  "$SB_IMPORT" --check-runtime "$CONFIG" || return 1
  if "$BIN" check -c "$CONFIG"; then
    echo "配置检查通过，语法完全正确。"
  else
    echo "配置检查失败。"
    return 1
  fi
}

start_service() (
  acquire_config_lock || return 1
  check_config || return 1
  systemctl start "$SERVICE" || return 1
  if systemctl is-active --quiet "$SERVICE"; then
    echo "sing-box 已成功启动。"
  else
    echo "sing-box 启动失败，请查看日志。"
  fi
)

stop_service() (
  acquire_config_lock || return 1
  cancel_import_rollbacks
  systemctl stop "$SERVICE" || return 1
  "$SB_IMPORT" --clear-network-guard || return 1
  echo "严格代理已主动关闭，原网络已恢复。"
)

restart_service() (
  acquire_config_lock || return 1
  check_config || return 1
  systemctl restart "$SERVICE" || return 1
  sleep 1
  systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'
)

toggle_enable() {
  if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
    systemctl disable "$SERVICE"
    echo "已关闭开机自启。"
  else
    systemctl enable "$SERVICE"
    echo "已开启开机自启。"
  fi
}

show_status() {
  systemctl --no-pager --full status "$SERVICE"
}

show_logs() {
  echo "正在显示实时日志，按 Ctrl+C 返回菜单。"
  echo
  journalctl -u "$SERVICE" -f --no-pager || true
}

show_recent_logs() {
  journalctl -u "$SERVICE" -n 100 --no-pager
}

show_config() {
  if command -v jq >/dev/null 2>&1; then
    jq . "$CONFIG" 2>/dev/null || cat "$CONFIG"
  else
    cat "$CONFIG"
  fi
}

cancel_import_rollbacks() {
  local timer
  while read -r timer; do
    [[ -n "$timer" ]] || continue
    systemctl stop "$timer" "${timer%.timer}.service" 2>/dev/null || true
  done < <(systemctl list-units --all --type=timer --plain --no-legend 'sing-box-import-rollback-*.timer' 2>/dev/null | awk '{print $1}')
}

collect_node_config() {
  local tmp="$1" meta="$2" selection mode protocol method="" host port
  local credential="" password="" uot=false uri answer
  local helper_args=()
  echo "请选择节点协议："
  echo " 1) VLESS 纯 TCP（无 TLS/Reality，手动填写 / 链接导入）"
  echo " 2) SOCKS5（仅手动填写）"
  echo " 3) SS aes-128-gcm（手动填写 / 链接导入）"
  echo " 4) SS aes-256-gcm（手动填写 / 链接导入）"
  echo " 0) 取消"
  IFS= read -r -p "请选择 [0-4]：" selection || return 1
  case "$selection" in
    1) protocol=vless ;;
    2) protocol=socks ;;
    3) protocol=shadowsocks; method=aes-128-gcm ;;
    4) protocol=shadowsocks; method=aes-256-gcm ;;
    0) echo "已取消添加节点。"; return 1 ;;
    *) echo "无效的协议选项。"; return 1 ;;
  esac
  helper_args=(--expected-type "$protocol")
  [[ -z "$method" ]] || helper_args+=(--expected-method "$method")
  mode=1
  if [[ "$protocol" != socks ]]; then
    echo " 1) 手动填写"
    echo " 2) 节点链接导入"
    echo " 0) 取消"
    IFS= read -r -p "请选择输入方式 [1]：" mode || return 1
    mode="${mode:-1}"
    case "$mode" in
      1|2) ;;
      0) echo "已取消添加节点。"; return 1 ;;
      *) echo "无效的输入方式。"; return 1 ;;
    esac
  fi
  if [[ "$mode" == 2 ]]; then
    echo "节点链接包含密钥，输入内容不会显示。"
    IFS= read -r -s -p "请粘贴节点链接：" uri || return 1
    echo
    [[ -n "$uri" ]] || { echo "未输入节点链接。"; return 1; }
    printf '%s\n' "$uri" | "$SB_IMPORT" --uri-stdin "${helper_args[@]}" --output "$tmp" --meta "$meta"
    return $?
  fi
  IFS= read -r -p "服务器 IP / 域名（不包含协议和端口）：" host || return 1
  IFS= read -r -p "服务器端口：" port || return 1
  case "$protocol" in
    vless)
      IFS= read -r -s -p "VLESS UUID（隐藏输入）：" credential || return 1
      echo
      ;;
    shadowsocks)
      echo "SS 加密方式：$method"
      IFS= read -r -s -p "SS 密码（隐藏输入）：" password || return 1
      echo
      ;;
    socks)
      IFS= read -r -p "SOCKS5 用户名（无认证时留空）：" credential || return 1
      if [[ -n "$credential" ]]; then
        IFS= read -r -s -p "SOCKS5 密码（隐藏输入）：" password || return 1
        echo
      fi
      IFS= read -r -p "启用 UDP-over-TCP？仅在节点支持时选 y [y/N]：" answer || return 1
      case "${answer:-N}" in
        y|Y|yes|YES) uot=true ;;
        n|N|no|NO) ;;
        *) echo "UDP-over-TCP 选项无效。"; return 1 ;;
      esac
      ;;
  esac
  # NUL-separated stdin preserves literal passwords without exposing secrets in argv.
  printf '%s\0' "$protocol" "$host" "$port" "$credential" "$password" "$method" "$uot" |
    "$SB_IMPORT" --manual-stdin "${helper_args[@]}" --output "$tmp" --meta "$meta"
}

configure_node() (
  local tmp="" meta="" backup stamp unit answer public_ip verified_ip was_active=false was_armed=false
  exec 9>/run/sing-box-import.lock || return 1
  if ! flock -n 9; then
    echo "另一个节点配置操作正在进行，请完成后重试。"
    return 1
  fi
  if systemctl list-units --all --type=timer --plain --no-legend 'sing-box-import-rollback-*.timer' 2>/dev/null | grep -q 'active.*waiting'; then
    echo "已有节点导入正在等待确认，请先完成确认或等待自动回滚。"
    return 1
  fi
  trap 'rm -f "$tmp" "$meta" 2>/dev/null' EXIT
  tmp=$(mktemp /etc/sing-box/config.import.XXXXXX.json) || return 1
  meta=$(mktemp /tmp/sing-box-meta.XXXXXX.json) || return 1
  chmod 600 "$tmp" "$meta"

  collect_node_config "$tmp" "$meta" || return 1
  "$SB_IMPORT" --check-runtime "$tmp" || return 1

  if ! "$BIN" check -c "$tmp"; then
    echo "生成的配置未通过 sing-box 检查。"
    return 1
  fi

  echo "正在预检节点（仅使用本机代理，当前配置和系统路由保持不变）..."
  if ! verified_ip=$("$SB_IMPORT" --probe "$tmp" --meta "$meta"); then
    return 1
  fi
  echo "节点可用，实测代理出口：$verified_ip"

  echo "节点配置已生成："
  if command -v jq >/dev/null 2>&1; then
    jq -r '"  协议：\(.protocol)\n  SS 加密方式：\(.method)\n  地址：\(.server):\(.server_port)\n  直连端点：\(.endpoint_ips | if length == 0 then "DNS 动态解析" else join(", ") end)\n  放行SSH端口：\(.ssh_ports | join(", "))"' "$meta" 2>/dev/null || cat "$meta"
  else
    cat "$meta"
  fi
  echo
  echo "将启用严格全局代理：除 SSH 管理和核心连接节点外，业务全部经节点或被阻断。"
  echo "内网、VPN、容器、IPv6、DNS 都受约束；异常退出不会恢复直连。"
  read -r -p "确认写入并启动？[y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "已取消添加节点。"; return 0 ;;
  esac

  stamp="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  backup="$BACKUP_DIR/config.json.before-import.$stamp.bak"
  cp -a "$CONFIG" "$backup" || { echo "无法备份当前配置，已取消导入。"; return 1; }
  systemctl is-active --quiet "$SERVICE" && was_active=true
  [[ "$("$SB_IMPORT" --policy-status)" == armed ]] && was_armed=true

  unit="sing-box-import-rollback-$stamp"
  if ! systemd-run --quiet --unit="$unit" --on-active=3m --timer-property=AccuracySec=1s \
      "$SB_IMPORT" --recover-config "$backup" --previous-active "$was_active" --previous-armed "$was_armed"; then
    echo "无法建立自动回滚保护任务，已取消导入。"
    return 1
  fi
  if ! "$SB_IMPORT" --stage-config "$tmp"; then
    systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
    echo "配置原子写入失败，原配置保留。"
    return 1
  fi
  echo "已建立 3 分钟安全回滚：恢复原严格节点；首次启用失败时保留阻断。"
  if ! systemctl restart "$SERVICE" || ! sleep 2 || ! systemctl is-active --quiet "$SERVICE"; then
    echo "新配置启动失败，正在立即恢复。"
    systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
    "$SB_IMPORT" --recover-config "$backup" --previous-active "$was_active" --previous-armed "$was_armed"
    return 1
  fi

  if ! public_ip=$("$SB_IMPORT" --verify-exit "$meta"); then
    echo "实际出口未通过节点验证，正在恢复原配置。"
    systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
    "$SB_IMPORT" --recover-config "$backup" --previous-active "$was_active" --previous-armed "$was_armed"
    return 1
  fi
  echo "sing-box 已启动。当前出口：$public_ip"
  echo "请在另一个终端测试 SSH，确认连接正常。"
  read -r -p "确认网络和 SSH 均正常，取消自动回滚？[y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      if ! systemctl is-active --quiet "$unit.timer"; then
        echo "确认已超时，自动回滚已执行或正在执行，请重新配置节点。"
        return 1
      fi
      systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
      if ! cmp -s "$tmp" "$CONFIG" || ! systemctl is-active --quiet "$SERVICE"; then
        echo "确认已超时或配置已被改变，新节点未生效，请重新配置节点。"
        return 1
      fi
      systemctl reset-failed "$unit.service" "$unit.timer" 2>/dev/null || true
      echo "已确认并取消自动回滚，新节点配置正式生效。"
      ;;
    *)
      echo "未确认，正在恢复原配置。"
      systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
      "$SB_IMPORT" --recover-config "$backup" --previous-active "$was_active" --previous-armed "$was_armed"
      ;;
  esac
)

list_backups() {
  local files=()
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config.json.*.bak' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  if ((${#files[@]} == 0)); then
    echo "没有可用备份。"
    return 1
  fi
  local i
  for i in "${!files[@]}"; do
    printf '%2d) %s\n' "$((i+1))" "${files[$i]}"
  done
}

restore_backup() (
  acquire_config_lock || return 1
  local files=()
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config.json.*.bak' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  if ((${#files[@]} == 0)); then
    echo "没有可用备份。"
    return 1
  fi
  local i choice selected
  echo "可用备份："
  for i in "${!files[@]}"; do
    printf '%2d) %s\n' "$((i+1))" "${files[$i]}"
  done
  echo " 0) 取消"
  read -r -p "请选择要恢复的备份编号：" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "输入无效。"; return 1; }
  ((choice == 0)) && return 0
  ((choice >= 1 && choice <= ${#files[@]})) || { echo "编号超出范围。"; return 1; }
  selected="${files[$((choice-1))]}"
  cp -a "$CONFIG" "$BACKUP_DIR/config.json.before-restore.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
  "$SB_IMPORT" --validate-strict "$selected" || return 1
  "$SB_IMPORT" --check-runtime "$selected" || return 1
  "$BIN" check -c "$selected" || return 1
  "$SB_IMPORT" --stage-config "$selected" || return 1
  if check_config; then
    echo "已恢复：$selected"
    read -r -p "是否立即重启并应用？[Y/n] " answer
    case "${answer:-Y}" in
      y|Y|yes|YES) restart_service ;;
      *) echo "已恢复文件，但尚未重启服务。" ;;
    esac
  else
    echo "该备份配置无效，请选择其他备份。"
    return 1
  fi
)

connection_test() {
  echo "服务状态：$(service_state)"
  echo
  echo "当前 IPv4 出口："
  timeout 10 curl --proxy "" --noproxy "" -4fsSL https://myip.ipip.net 2>/dev/null || echo "出口查询失败"
  echo
  echo "构建站点连通性："
  local url result
  for url in \
    https://api.github.com \
    https://registry-1.docker.io/v2/ \
    https://pypi.org/simple/ \
    https://registry.npmjs.org/; do
    result=$(timeout 12 curl --proxy "" --noproxy "" -4sS -o /dev/null -w '%{http_code}  %{time_total}s' "$url" 2>/dev/null || true)
    [[ -n "$result" ]] || result="连接失败"
    printf '  %-38s %s\n' "$url" "$result"
  done
  echo
  echo "IPv6 状态："
  ip -6 -br addr show scope global 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true
}

# 一键清空配置（主动关闭严格代理后恢复待机状态）
clear_all_config() (
  acquire_config_lock || return 1
  read -r -p "确认主动关闭严格代理并重置配置？[y/N] " confirm || return 1
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "已取消操作。"; return 0 ;;
  esac
  cancel_import_rollbacks
  backup_config || return 1
  systemctl stop "$SERVICE" || return 1
  "$SB_IMPORT" --clear-network-guard || return 1
  "$SB_IMPORT" --reset-config || return 1
  echo "已主动关闭严格代理并重置配置，原网络恢复。"
)

# 重新安装/更新核心
reinstall_core() (
  acquire_config_lock || return 1
  echo "========================================================"
  echo " 请选择 sing-box 核心更新/安装方式："
  echo "========================================================"
  echo " 1) 海外直连下载 v${SB_CORE_VERSION} (GitHub 官方源)"
  echo " 2) 国内加速源下载 v${SB_CORE_VERSION} (ghfast.top)"
  echo " 3) 安装离线官方 v${SB_CORE_VERSION} 压缩包 (校验 SHA-256)"
  echo " 0) 返回"
  echo "========================================================"
  local choice
  read -r -p "请输入选项 [0-3]：" choice
  case "$choice" in
    1|2)
      local source="overseas"
      [[ "$choice" == "2" ]] && source="domestic"
      install_core_download "$source" "$BIN" || return 1
      if systemctl is-active --quiet "$SERVICE"; then
        echo "请通过菜单重启服务，使新安装的核心生效。"
      fi
      ;;
    3) install_core_local || return 1 ;;
    0) return 0 ;;
    *) echo "无效选项。" ;;
  esac
)

# 彻底卸载管理函数
uninstall_menu() (
  acquire_config_lock || return 1
  echo "========================================================"
  echo " 警告：将彻底卸载 sing-box，删除所有配置、备份及脚本文件！"
  echo "========================================================"
  read -r -p "确认彻底卸载？[y/N] " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "已取消卸载。"; return 0 ;;
  esac

  echo "正在停止并清理服务..."
  systemctl stop "$SERVICE" || return 1
  systemctl disable "$SERVICE" 2>/dev/null || true

  cancel_import_rollbacks
  if [[ -x "$SB_IMPORT" ]]; then
    "$SB_IMPORT" --clear-network-guard || { echo "严格规则清理失败，停止卸载以保留恢复入口。"; return 1; }
  fi

  rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/multi-user.target.wants/sing-box.service
  systemctl disable --now sing-box-guard.service 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box-guard.service
  rm -f /etc/systemd/system/sing-box.service.d/10-network-guard.conf
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  rm -f "$BIN" "$SB_IMPORT" "$SB_MENU" "$SB_LINK"
  rm -rf "$CONFIG_DIR" "$INSTALL_DIR"
  ip link delete singtun0 2>/dev/null || true

  # 删除调用脚本自身（如果在当前目录或别处）
  local caller_script
  caller_script="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  rm -f "$caller_script" 2>/dev/null || true

  echo "========================================================"
  echo " sing-box 客户端及管理菜单已彻底卸载清理完毕！"
  echo "========================================================"
  exit 0
)

while true; do
  show_header
  cat <<'MENU'
  1) 添加 / 更换节点 (手动填写 / 节点链接导入)
  2) 手动编辑配置 (自动备份并校验)
  3) 检查配置语法
  4) 启动 sing-box
  5) 停止 sing-box
  6) 重启并应用配置
  7) 查看运行状态
  8) 查看实时日志
  9) 查看最近 100 条日志
 10) 查看当前配置
 11) 备份当前配置
 12) 查看配置备份
 13) 恢复配置备份
 14) 开启/关闭开机自启
 15) 测试出口与连通性
 16) 一键清空全部配置 (恢复为纯核心初始状态)
 17) 更新 / 重新安装 sing-box 核心
 18) 彻底卸载 sing-box 及管理脚本 (自删除)
  0) 退出
MENU
  line
  read -r -p "请输入选项 [0-18]：" choice
  echo
  case "$choice" in
    1) configure_node; pause ;;
    2) edit_config; pause ;;
    3) check_config; pause ;;
    4) start_service; pause ;;
    5) stop_service; pause ;;
    6) restart_service; pause ;;
    7) show_status; pause ;;
    8) show_logs ;;
    9) show_recent_logs; pause ;;
    10) show_config; pause ;;
    11) backup_config; pause ;;
    12) list_backups; pause ;;
    13) restore_backup; pause ;;
    14) toggle_enable; pause ;;
    15) connection_test; pause ;;
    16) clear_all_config; pause ;;
    17) reinstall_core; pause ;;
    18) uninstall_menu; [[ -x "$BIN" ]] || exit 0 ;;
    0|q|Q) echo "已退出。"; exit 0 ;;
    *) echo "无效选项，请重新输入。"; sleep 1 ;;
  esac
done
EOF

chmod 0755 "$SB_MENU"
ln -sf "$SB_MENU" "$SB_LINK"

# 首次安装保持待机；只有导入节点并主动启用才建立严格策略。
if [[ ! -f "$CONFIG_FILE" ]]; then
  "$SB_IMPORT" --reset-config
fi

# 4. 确保 systemd 服务单元存在
if [[ ! -f "$SERVICE_FILE" ]]; then
  cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
fi

# Dedicated boot guard restores armed policy before network configuration.
cat <<'EOF' > /etc/systemd/system/sing-box-guard.service
[Unit]
Description=sing-box strict fail-closed network guard
DefaultDependencies=no
After=local-fs.target nftables.service netfilter-persistent.service
Before=network-pre.target
Wants=network-pre.target
RequiresMountsFor=/usr/local/sbin /etc/sing-box

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sb-import-uri --restore-network-guard
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/sing-box.service.d
cat <<'EOF' > /etc/systemd/system/sing-box.service.d/10-network-guard.conf
[Unit]
Requires=sing-box-guard.service
After=sing-box-guard.service

[Service]
User=singbox-tun
Group=singbox-tun
ExecStart=
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecStartPre=
ExecStartPre=+/usr/local/sbin/sb-import-uri --apply-network-guard
ExecStopPost=
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
EOF
chown root:singbox-tun "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"
systemctl daemon-reload
systemctl enable sing-box-guard.service

# 保存管理脚本，便于更新后的安装文件继续使用。
if [[ "$SCRIPT_PATH" != "$INSTALL_DIR/singbox_tun.sh" ]]; then
  install -m 0700 "$SCRIPT_PATH" "$INSTALL_DIR/singbox_tun.sh"
fi

echo "========================================================"
echo " sing-box TUN 客户端环境已就绪！"
echo " 运行命令：sb 或 /usr/local/sbin/sbmenu 即可打开管理菜单"
echo "========================================================"
