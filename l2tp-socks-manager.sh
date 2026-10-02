#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu L2TP/IPsec -> SOCKS5 + Shadowsocks, multi-profile edition.
BASE=/etc/l2tp-socks
PROFILES=$BASE/profiles
MANAGER=/usr/local/sbin/l2tp-socks-manager.sh
LIB=/usr/local/libexec/l2tp-socks
IPSEC_SECRETS=/etc/ipsec.d/l2tp-socks.secrets
NFT_TABLE=l2tp_socks
COMPAT_IKE='aes128-sha1-modp2048,aes128-sha1-modp1024,3des-sha1-modp1024'
COMPAT_ESP='aes128-sha1,3des-sha1'

say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; return 1; }
root_required() { [[ $(id -u) -eq 0 ]] || fail '请以 root 身份运行。'; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1025 && 10#$1 <= 65535 )); }
random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d '[:space:]'; }
quote_dq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
quote_ppp() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
id_ok() { [[ ${1:-} =~ ^[1-9][0-9]{0,2}$ ]] && (( 10#$1 <= 999 )); }
conn_name() { printf 'l2tp-socks-%s' "$1"; }
profile_dir() { printf '%s/%s' "$PROFILES" "$1"; }
mark_for() { printf '0x%x' "$((0x4c540000 + 10#$1))"; }
table_for() { printf '%s' "$((20000 + 10#$1))"; }
priority_for() { printf '%s' "$((12000 + 2 * 10#$1))"; }

require_fresh_layout() {
    if [[ -f $BASE/settings && ! -f $BASE/multi-profile.version ]]; then
        fail '检测到旧版单出口安装。为避免覆盖现有线路，请先在另一台新机器测试多配置版；此版本不会自动改动旧配置。'
    fi
}

ensure_ppp_device() {
    if [[ -r /boot/config-$(uname -r) ]] &&
       grep -qx '# CONFIG_PPP is not set' "/boot/config-$(uname -r)"; then
        fail "当前内核 $(uname -r) 未启用 CONFIG_PPP；请切换到支持 PPP 的内核。"
        return 1
    fi
    command -v modprobe >/dev/null 2>&1 && modprobe ppp_generic 2>/dev/null || true
    [[ -e /dev/ppp ]] || mknod -m 600 /dev/ppp c 108 0 2>/dev/null || fail '无法创建 /dev/ppp。'
    [[ -c /dev/ppp ]] || fail '/dev/ppp 不是字符设备。'
    if ! (exec 8<>/dev/ppp) 2>/dev/null; then
        if command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; then
            fail '无法打开 /dev/ppp；容器宿主机需要开放 PPP 字符设备（108:0）。'
        else
            fail '无法打开 /dev/ppp；请检查内核 PPP 模块及设备权限。'
        fi
    fi
}

ask() {
    local var=$1 label=$2 hidden=${3:-no} old answer
    old=${!var-}
    if [[ $hidden == yes ]]; then
        if [[ -n $old ]]; then
            read -r -s -p "$label（回车保留已设置值）: " answer
        else
            read -r -s -p "$label: " answer
        fi
        printf '\n'
    else
        if [[ -n $old ]]; then
            read -r -p "$label [$old]: " answer
        else
            read -r -p "$label: " answer
        fi
    fi
    [[ -n $answer ]] || answer=$old
    printf -v "$var" '%s' "$answer"
}

list_ids() {
    local d
    for d in "$PROFILES"/*; do
        [[ -f $d/settings ]] || continue
        basename "$d"
    done
}

load_profile() {
    local id=$1
    id_ok "$id" || fail '配置 ID 无效。'
    P=$(profile_dir "$id")
    [[ -r $P/settings ]] || fail "配置 $id 不存在。"
    PROFILE_ID=$id
    # Root-owned settings are generated with printf %q; do not import untrusted files.
    source "$P/settings"
}

save_profile() {
    local tmp key
    install -d -m 700 "$P"
    chgrp "l2tps$PROFILE_ID" "$P"
    chmod 710 "$P"
    umask 077
    tmp=$(mktemp "$P/settings.XXXXXX")
    {
        for key in PROFILE_NAME L2TP_SERVER L2TP_USER L2TP_PASS L2TP_PSK L2TP_REMOTE_ID \
                   IKE_MODE CUSTOM_IKE CUSTOM_ESP LAST_GOOD SOCKS_PORT SOCKS_UDP_RANGE \
                   SOCKS_USER SOCKS_PASS SS_PORT SS_METHOD SS_PASS ENTRY_HOST AUTOSTART KEEPALIVE; do
            printf '%s=%q\n' "$key" "${!key-}"
        done
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$P/settings"
}

next_id() {
    local id
    for id in $(seq 1 999); do
        # Retry an incomplete installation using its existing ownership records.
        [[ -f $(profile_dir "$id")/settings ]] || { printf '%s' "$id"; return; }
    done
    fail '最多支持 999 个配置。'
}

port_used_elsewhere() {
    local current=$1 wanted=$2 other
    while read -r other; do
        [[ $other == "$current" ]] && continue
        local p="$(profile_dir "$other")/settings"
        (
            source "$p"
            [[ $SOCKS_PORT == "$wanted" || $SS_PORT == "$wanted" ]] && exit 0
            if [[ -n ${SOCKS_UDP_RANGE:-} && $SOCKS_UDP_RANGE =~ ^([0-9]+)-([0-9]+)$ ]]; then
                (( 10#$wanted >= 10#${BASH_REMATCH[1]} && 10#$wanted <= 10#${BASH_REMATCH[2]} )) && exit 0
            fi
            exit 1
        ) && return 0
    done < <(list_ids)
    return 1
}

validate_profile() {
    [[ $PROFILE_NAME =~ ^[^[:cntrl:]]{1,60}$ ]] || fail '名称不能为空或包含控制字符。'
    [[ $L2TP_SERVER =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail '落地地址/IP 格式不正确。'
    [[ -n $L2TP_USER && -n $L2TP_PASS && -n $L2TP_PSK ]] || fail '落地账号、密码和 PSK 均必填。'
    [[ $L2TP_USER != *$'\n'* && $L2TP_PASS != *$'\n'* && $L2TP_PSK != *$'\n'* ]] || fail '凭据不能包含换行。'
    [[ $L2TP_USER != *'"'* && $L2TP_PASS != *'"'* && $L2TP_PSK != *'"'* ]] || fail '落地凭据不能包含双引号。'
    [[ -z $L2TP_REMOTE_ID || $L2TP_REMOTE_ID =~ ^[A-Za-z0-9_.@:-]+$ ]] || fail '对端 ID 格式不正确。'
    [[ $IKE_MODE == auto || $IKE_MODE == compat || $IKE_MODE == strongswan || $IKE_MODE == custom ]] || fail '提案模式无效。'
    if [[ $IKE_MODE == custom ]]; then
        [[ $CUSTOM_IKE =~ ^[A-Za-z0-9,+!:_-]+$ && $CUSTOM_ESP =~ ^[A-Za-z0-9,+!:_-]+$ ]] || fail '自定义 IKE/ESP 提案格式不正确。'
    fi
    valid_port "$SOCKS_PORT" && valid_port "$SS_PORT" || fail '代理端口必须为 1025-65535。'
    SOCKS_PORT=$((10#$SOCKS_PORT))
    SS_PORT=$((10#$SS_PORT))
    (( 10#$SOCKS_PORT != 10#$SS_PORT )) || fail '同一配置的 SOCKS5 和 SS 端口不能相同。'
    port_used_elsewhere "$PROFILE_ID" "$SOCKS_PORT" && fail "SOCKS5 端口 $SOCKS_PORT 已被其他配置占用。"
    port_used_elsewhere "$PROFILE_ID" "$SS_PORT" && fail "SS 端口 $SS_PORT 已被其他配置占用。"
    [[ $SOCKS_USER =~ ^[A-Za-z0-9._-]{1,32}$ ]] || fail 'SOCKS5 用户名格式不正确。'
    [[ -n $SOCKS_PASS && $SOCKS_PASS != *:* && $SOCKS_PASS != *$'\n'* ]] || fail 'SOCKS5 密码不能为空、含冒号或换行。'
    [[ -n $SS_PASS && $SS_PASS != *'"'* && $SS_PASS != *'\'* && $SS_PASS != *$'\n'* ]] || fail 'SS 密码包含不支持的字符。'
    [[ $SS_METHOD == aes-128-gcm || $SS_METHOD == chacha20-ietf-poly1305 ]] || fail 'SS 加密方式不支持。'
    [[ -z $ENTRY_HOST || $ENTRY_HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail '入口 DDNS 格式不正确。'
    [[ $AUTOSTART == yes || $AUTOSTART == no ]] || fail '开机自启请输入 yes/no。'
    [[ $KEEPALIVE == yes || $KEEPALIVE == no ]] || fail '保活请输入 yes/no。'
    local start end other
    if [[ -n $SOCKS_UDP_RANGE ]]; then
        [[ $SOCKS_UDP_RANGE =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || fail 'SOCKS5 UDP 范围应为 30000-30100。'
        start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
        valid_port "$start" && valid_port "$end" && (( 10#$start <= 10#$end )) || fail 'SOCKS5 UDP 范围无效。'
        (( 10#$SOCKS_PORT < 10#$start || 10#$SOCKS_PORT > 10#$end )) || fail 'SOCKS5 TCP 端口落在 UDP 范围内。'
        (( 10#$SS_PORT < 10#$start || 10#$SS_PORT > 10#$end )) || fail 'SS 端口落在 SOCKS5 UDP 范围内。'
        while read -r other; do
            [[ $other == "$PROFILE_ID" ]] && continue
            (
                source "$(profile_dir "$other")/settings"
                (( 10#$SOCKS_PORT >= 10#$start && 10#$SOCKS_PORT <= 10#$end )) && exit 0
                (( 10#$SS_PORT >= 10#$start && 10#$SS_PORT <= 10#$end )) && exit 0
                if [[ -n ${SOCKS_UDP_RANGE:-} && $SOCKS_UDP_RANGE =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    (( 10#${BASH_REMATCH[1]} <= 10#$end && 10#${BASH_REMATCH[2]} >= 10#$start )) && exit 0
                fi
                exit 1
            ) && fail "UDP 范围与配置 $other 冲突。"
        done < <(list_ids)
    fi
}

prompt_profile() {
    local id=$1
    PROFILE_ID=$id
    P=$(profile_dir "$id")
    if [[ -f $P/settings ]]; then
        load_profile "$id"
    else
        PROFILE_NAME="出口$id" L2TP_SERVER='' L2TP_USER='' L2TP_PASS='' L2TP_PSK=''
        L2TP_REMOTE_ID='' IKE_MODE=auto CUSTOM_IKE='' CUSTOM_ESP='' LAST_GOOD=compat
        SOCKS_PORT=$((1080 + 2 * (10#$id - 1)))
        SS_PORT=$((SOCKS_PORT + 1))
        SOCKS_UDP_RANGE='' SOCKS_USER='' SOCKS_PASS='' SS_METHOD=aes-128-gcm SS_PASS=''
        ENTRY_HOST='' AUTOSTART=yes KEEPALIVE=yes
    fi
    say '请填写落地服务商提供的地址、账号、密码和 PSK。落地 IP 变化时可填写其 DDNS 域名。'
    ask PROFILE_NAME '配置名称'
    ask L2TP_SERVER '落地 L2TP 服务器地址/IP/DDNS'
    ask L2TP_USER '落地 L2TP 用户名'
    ask L2TP_PASS '落地 L2TP 密码' yes
    ask L2TP_PSK '落地 IPsec PSK' yes
    ask L2TP_REMOTE_ID '对端 ID（没有提供就留空；输入 - 清空）'
    [[ $L2TP_REMOTE_ID == - ]] && L2TP_REMOTE_ID=''
    say '提案模式：auto=先兼容提案再尝试 strongSwan 默认；compat=仅兼容；strongswan=仅系统默认；custom=手动。'
    ask IKE_MODE 'IKE/ESP 提案模式'
    if [[ $IKE_MODE == custom ]]; then
        ask CUSTOM_IKE 'IKE 提案'
        ask CUSTOM_ESP 'ESP 提案'
    fi
    ask SOCKS_PORT 'SOCKS5 TCP 端口'
    ask SOCKS_UDP_RANGE 'SOCKS5 UDP 中继范围（例如 30000-30100；回车保持关闭）'
    [[ $SOCKS_UDP_RANGE == 关闭 || $SOCKS_UDP_RANGE == off ]] && SOCKS_UDP_RANGE=''
    ask SS_PORT 'SS TCP/UDP 端口'
    ask SS_METHOD 'SS 加密方式'
    ask SOCKS_USER 'SOCKS5 用户名（首次回车随机；输入 RANDOM 换新）'
    ask SOCKS_PASS 'SOCKS5 密码（首次回车随机；输入 RANDOM 换新）' yes
    ask SS_PASS 'SS 密码（首次回车随机；输入 RANDOM 换新）' yes
    ask ENTRY_HOST '中转机入口 DDNS 域名（可选；输入 - 清空）'
    [[ $ENTRY_HOST == - ]] && ENTRY_HOST=''
    ask AUTOSTART '开机自动连接？yes/no'
    ask KEEPALIVE '断线自动重拨？yes/no'
    if [[ -z $SOCKS_USER || $SOCKS_USER == RANDOM ]]; then
        local candidate
        SOCKS_USER=''
        for _ in 1 2 3 4 5; do
            candidate="s$(random_hex 6)"
            id "$candidate" >/dev/null 2>&1 || { SOCKS_USER=$candidate; break; }
        done
        [[ -n $SOCKS_USER ]] || fail '无法生成未占用的 SOCKS5 用户名。'
        say "SOCKS5 用户名：$SOCKS_USER"
    fi
    [[ -n $SOCKS_PASS && $SOCKS_PASS != RANDOM ]] || { SOCKS_PASS=$(random_hex 16); say '已随机生成 SOCKS5 密码。'; }
    [[ -n $SS_PASS && $SS_PASS != RANDOM ]] || { SS_PASS=$(random_hex 16); say '已随机生成 SS 密码。'; }
    validate_profile
}

resolve_peer() {
    local addr=$1
    timeout 12s getent ahostsv4 "$addr" | awk '$2 == "STREAM" {print $1; exit}'
}

local_source_for() {
    local route source
    route=$(ip -4 route get "$1") || fail '无法查询落地服务器的本机出口路由。'
    source=$(awk '{for (i=1; i<NF; i++) if ($i=="src") {print $(i+1); exit}}' <<< "$route")
    [[ $source =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail '无法确定本机 IPv4 源地址。'
    printf '%s' "$source"
}

load_endpoint() {
    REMOTE_IP='' LOCAL_IP='' ACTIVE_PROPOSAL=compat IFACE=''
    [[ -r $P/endpoint ]] && source "$P/endpoint"
    [[ -r $P/iface ]] && IFACE=$(cat "$P/iface")
    return 0
}

save_endpoint() {
    local tmp
    umask 077
    tmp=$(mktemp "$P/endpoint.XXXXXX")
    {
        printf 'REMOTE_IP=%q\n' "$REMOTE_IP"
        printf 'LOCAL_IP=%q\n' "$LOCAL_IP"
        printf 'ACTIVE_PROPOSAL=%q\n' "$ACTIVE_PROPOSAL"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$P/endpoint"
}

check_distinct_peer() {
    local current=$1 peer=$2 other other_ip other_server other_current
    while read -r other; do
        [[ $other == "$current" ]] && continue
        other_ip=''
        [[ -f $(profile_dir "$other")/endpoint ]] &&
            other_ip=$(sed -n 's/^REMOTE_IP=//p' "$(profile_dir "$other")/endpoint" | head -n 1)
        other_server=$(source "$(profile_dir "$other")/settings"; printf '%s' "$L2TP_SERVER")
        other_current=$(resolve_peer "$other_server" 2>/dev/null || true)
        if [[ $other_ip == "$peer" || $other_current == "$peer" ]]; then
            fail "配置 $other 使用同一个落地 IP ($peer)。同一 IP 上的多个 L2TP 会话暂不支持并行。"
        fi
    done < <(list_ids)
}

ensure_include() {
    local file=$1 target=$2 label=$3
    touch "$file"
    sed -i "/^# BEGIN $label\$/,/^# END $label\$/d" "$file"
    printf '\n# BEGIN %s\ninclude %s\n# END %s\n' "$label" "$target" "$label" >> "$file"
}

render_shared_ipsec() (
    set -e
    local id d psk tmp_conf tmp_sec
    tmp_conf=$(mktemp "$BASE/ipsec.conf.XXXXXX")
    tmp_sec=$(mktemp "$BASE/ipsec.secrets.XXXXXX")
    chmod 600 "$tmp_conf" "$tmp_sec"
    while read -r id; do
        load_profile "$id"
        load_endpoint
        [[ -n $REMOTE_IP && -n $LOCAL_IP ]] || continue
        cat >> "$tmp_conf" <<EOF
conn $(conn_name "$id")
    keyexchange=ikev1
    authby=secret
    type=transport
    left=$LOCAL_IP
    leftprotoport=17/1701
    right=$REMOTE_IP
    rightprotoport=17/1701
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    keyingtries=1
    auto=add
EOF
        [[ -z $L2TP_REMOTE_ID ]] || printf '    rightid=%s\n' "$L2TP_REMOTE_ID" >> "$tmp_conf"
        case $ACTIVE_PROPOSAL in
            compat) printf '    ike=%s\n    esp=%s\n' "$COMPAT_IKE" "$COMPAT_ESP" >> "$tmp_conf" ;;
            custom) printf '    ike=%s\n    esp=%s\n' "$CUSTOM_IKE" "$CUSTOM_ESP" >> "$tmp_conf" ;;
            strongswan) ;;
            *) fail "配置 $id 的提案模式无效。" ;;
        esac
        printf '\n' >> "$tmp_conf"
        psk=$(quote_dq "$L2TP_PSK")
        printf '%s %s : PSK "%s"\n' "$LOCAL_IP" "$REMOTE_IP" "$psk" >> "$tmp_sec"
        if [[ -n $L2TP_REMOTE_ID && $L2TP_REMOTE_ID != "$REMOTE_IP" ]]; then
            printf '%s %s : PSK "%s"\n' "$LOCAL_IP" "$L2TP_REMOTE_ID" "$psk" >> "$tmp_sec"
        fi
    done < <(list_ids)
    mv -f "$tmp_conf" "$BASE/ipsec.conf"
    mv -f "$tmp_sec" "$IPSEC_SECRETS"
    chmod 600 "$BASE/ipsec.conf" "$IPSEC_SECRETS"
)

render_ss() {
    local id=$1 mark
    load_profile "$id"
    mark=$(mark_for "$id")
    cat > "$P/ssserver.json" <<EOF
{
  "server": "0.0.0.0",
  "server_port": $SS_PORT,
  "password": "$SS_PASS",
  "method": "$SS_METHOD",
  "mode": "tcp_and_udp",
  "dns": "system",
  "outbound_fwmark": $((mark)),
  "nofile": 65535
}
EOF
    chmod 640 "$P/ssserver.json"
    chgrp "l2tps$id" "$P/ssserver.json"
    chmod 711 "$BASE" "$PROFILES"
    chgrp "l2tps$id" "$P"
    chmod 710 "$P"
    cat > "$P/options.ppp" <<EOF
ipparam l2tp-socks-$id
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu 1400
mru 1400
nodefaultroute
persist
maxfail 0
holdoff 5
lcp-echo-interval 20
lcp-echo-failure 3
connect-delay 5000
name "$(quote_ppp "$L2TP_USER")"
password "$(quote_ppp "$L2TP_PASS")"
EOF
    chmod 600 "$P/options.ppp"
    cat > "/etc/pam.d/l2tp-socks-$id" <<EOF
auth required pam_unix.so
account required pam_listfile.so item=user sense=allow file=$P/allowed-user onerr=fail
EOF
    printf '%s\n' "$SOCKS_USER" > "$P/allowed-user"
    chmod 600 "$P/allowed-user"
    chmod 644 "/etc/pam.d/l2tp-socks-$id"
}

render_danted() {
    local id=$1 iface=$2
    load_profile "$id"
    [[ $iface =~ ^[a-zA-Z0-9_.-]+$ ]] || fail 'PPP 接口名无效。'
    cat > "$P/danted.conf" <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $SOCKS_PORT
external: $iface
clientmethod: none
socksmethod: pam.username
user.privileged: root
user.notprivileged: l2tpd$id
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect udpassociate
    socksmethod: pam.username
    pam.servicename: l2tp-socks-$id
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: udpreply
}
EOF
    [[ -z $SOCKS_UDP_RANGE ]] || sed -i "/^client pass {/a\\    udp.portrange: $SOCKS_UDP_RANGE" "$P/danted.conf"
    chmod 600 "$P/danted.conf"
}

install_ss_rust() {
    local target tmp bin
    case $(uname -m) in
        x86_64) target=x86_64-unknown-linux-musl ;;
        aarch64) target=aarch64-unknown-linux-musl ;;
        *) fail 'Shadowsocks-Rust 自动安装仅支持 x86_64 和 aarch64。' ;;
    esac
    if [[ -x $LIB/ssserver ]] && "$LIB/ssserver" --version >/dev/null 2>&1; then return; fi
    install -d -m 755 "$LIB"
    tmp=$(mktemp -d)
    say '正在从 Shadowsocks-Rust 官方发布页下载并校验 ssserver。'
    if ! python3 - "$target" "$tmp" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
arch, dest = sys.argv[1], pathlib.Path(sys.argv[2])
api = 'https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest'
req = urllib.request.Request(api, headers={'User-Agent':'l2tp-socks-manager','Accept':'application/vnd.github+json'})
with urllib.request.urlopen(req, timeout=30) as r:
    release = json.load(r)
name = 'shadowsocks-' + release['tag_name'] + '.' + arch + '.tar.xz'
assets = {a['name']:a['browser_download_url'] for a in release.get('assets', [])}
if name not in assets or name + '.sha256' not in assets:
    raise SystemExit('官方发布页未找到对应架构压缩包及 SHA256 文件。')
for asset, out in ((name,dest/'ss.tar.xz'),(name+'.sha256',dest/'ss.sha256')):
    req = urllib.request.Request(assets[asset], headers={'User-Agent':'l2tp-socks-manager'})
    with urllib.request.urlopen(req, timeout=120) as r, open(out,'wb') as f:
        f.write(r.read())
text = (dest/'ss.sha256').read_text(errors='replace')
expected = next((x.lower() for x in text.replace('*',' ').split() if len(x)==64 and all(c in '0123456789abcdefABCDEF' for c in x)),None)
if not expected or hashlib.sha256((dest/'ss.tar.xz').read_bytes()).hexdigest()!=expected:
    raise SystemExit('Shadowsocks-Rust SHA256 校验失败。')
PY
    then rm -rf "$tmp"; fail '下载或校验 ssserver 失败。'; fi
    if ! tar -xJf "$tmp/ss.tar.xz" -C "$tmp"; then rm -rf "$tmp"; fail '解压 ssserver 失败。'; fi
    bin=$(find "$tmp" -type f -name ssserver -print -quit)
    [[ -n $bin ]] || { rm -rf "$tmp"; fail '压缩包内没有 ssserver。'; }
    install -m 755 "$bin" "$LIB/ssserver"
    rm -rf "$tmp"
}

ensure_account() {
    local name=$1 marker=$2
    if id -- "$name" >/dev/null 2>&1; then
        [[ -f $marker ]] || { fail "系统账号 $name 已存在但不属于本脚本。"; return 1; }
        [[ ! -s $marker || $(cat "$marker") == "$name" ]] || {
            fail "账号 $name 的归属记录不一致，请检查 $marker。"
            return 1
        }
    else
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -- "$name" || {
            fail "无法创建系统账号 $name。"
            return 1
        }
    fi
    printf '%s\n' "$name" > "$marker"
    chmod 600 "$marker"
}

remove_owned_accounts() {
    local dir=$1 marker user
    for marker in "$dir"/owner-*; do
        [[ -f $marker ]] || continue
        # Older versions created empty markers; the filename records the user.
        user=${marker##*/owner-}
        [[ $user =~ ^[A-Za-z0-9._-]{1,32}$ ]] || {
            fail "账号归属文件名无效：$marker。"
            return 1
        }
        [[ ! -s $marker || $(cat "$marker") == "$user" ]] || {
            fail "账号归属记录不一致：$marker。"
            return 1
        }
        if id -- "$user" >/dev/null 2>&1; then
            userdel -- "$user" || {
                fail "无法删除账号 $user；保留配置与归属记录，请处理占用后重试。"
                return 1
            }
        fi
    done
}

# Caller holds the policy lock. Keep UID marks even while PPP is down so the
# existing prohibit rules still prevent DNS from falling back to the main route.
render_firewall_locked() {
    local tmp id d_uid s_uid mark iface iface_file
    tmp=$(mktemp "$BASE/firewall.nft.XXXXXX")
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        printf 'flush table inet %s\n' "$NFT_TABLE" > "$tmp"
    fi
    cat >> "$tmp" <<EOF
table inet $NFT_TABLE {
  chain output {
    type route hook output priority mangle; policy accept;
EOF
    while read -r id; do
        id l2tpd"$id" >/dev/null 2>&1 || continue
        id l2tps"$id" >/dev/null 2>&1 || continue
        d_uid=$(id -u "l2tpd$id")
        s_uid=$(id -u "l2tps$id")
        mark=$(mark_for "$id")
        printf '    meta skuid { %s, %s } ct state new ct mark set %s\n' "$d_uid" "$s_uid" "$mark" >> "$tmp"
        printf '    ct mark %s meta mark set ct mark\n' "$mark" >> "$tmp"
    done < <(list_ids)
    printf '  }\n  chain dns_postrouting {\n    type nat hook postrouting priority srcnat; policy accept;\n' >> "$tmp"
    while read -r id; do
        id l2tpd"$id" >/dev/null 2>&1 || continue
        id l2tps"$id" >/dev/null 2>&1 || continue
        iface_file="$(profile_dir "$id")/iface"
        [[ -s $iface_file ]] || continue
        iface=$(cat "$iface_file")
        [[ $iface =~ ^[a-zA-Z0-9_.-]+$ ]] || continue
        # ARPHRD_PPP=512: never apply this exception to an ordinary uplink.
        [[ -r /sys/class/net/"$iface"/type ]] || continue
        [[ $(cat /sys/class/net/"$iface"/type) == 512 ]] || continue
        [[ -n $(ip -4 -o addr show dev "$iface" 2>/dev/null) ]] || continue
        mark=$(mark_for "$id")
        # OUTPUT marking reroutes resolver sockets after their source address
        # was selected. Correct only this profile's IPv4 DNS on its PPP link.
        printf '    meta nfproto ipv4 meta mark %s oifname "%s" meta l4proto { tcp, udp } th dport 53 counter masquerade\n' "$mark" "$iface" >> "$tmp"
    done < <(list_ids)
    printf '  }\n}\n' >> "$tmp"
    nft -f "$tmp" || { rm -f "$tmp"; fail 'nftables 规则加载失败。'; return 1; }
    mv -f "$tmp" "$BASE/firewall.nft"
    chmod 600 "$BASE/firewall.nft"
}

render_firewall() (
    exec 8>/run/l2tp-socks-policy.lock
    flock -w 30 8 || { fail 'PPP 路由操作繁忙。'; return 1; }
    render_firewall_locked
)

rule_line() { ip "$1" -o rule show 2>/dev/null | grep -E "^$2:" || true; }

add_rule_family() {
    local family=$1 prio=$2 mark=$3 table=$4 line
    line=$(rule_line "$family" "$prio")
    if [[ -n $line ]] && { [[ $line != *"fwmark $mark"* ]] || [[ $line != *"lookup $table"* ]]; }; then
        fail "策略路由优先级 $prio 已被系统占用。"
    fi
    [[ -n $line ]] || ip "$family" rule add priority "$prio" fwmark "$mark" table "$table"
    line=$(rule_line "$family" "$((prio+1))")
    if [[ -n $line ]] && { [[ $line != *"fwmark $mark"* ]] || [[ $line != *prohibit* ]]; }; then
        fail "策略路由优先级 $((prio+1)) 已被系统占用。"
    fi
    [[ -n $line ]] || ip "$family" rule add priority "$((prio+1))" fwmark "$mark" prohibit
}

policy_add() {
    local id=$1 mark table prio
    mark=$(mark_for "$id"); table=$(table_for "$id"); prio=$(priority_for "$id")
    add_rule_family -4 "$prio" "$mark" "$table"
    add_rule_family -6 "$prio" "$mark" "$table"
}

policy_del() {
    local id=$1 mark table prio
    mark=$(mark_for "$id"); table=$(table_for "$id"); prio=$(priority_for "$id")
    ip -4 rule del priority "$prio" fwmark "$mark" table "$table" 2>/dev/null || true
    ip -4 rule del priority "$((prio+1))" fwmark "$mark" prohibit 2>/dev/null || true
    ip -6 rule del priority "$prio" fwmark "$mark" table "$table" 2>/dev/null || true
    ip -6 rule del priority "$((prio+1))" fwmark "$mark" prohibit 2>/dev/null || true
    ip -4 route flush table "$table" 2>/dev/null || true
    ip -6 route flush table "$table" 2>/dev/null || true
}

policy_all() {
    local id
    while read -r id; do policy_add "$id"; done < <(list_ids)
}

policy_clear() {
    local id
    while read -r id; do policy_del "$id"; done < <(list_ids)
    if [[ -f $BASE/rp_filter.before ]]; then
        cat "$BASE/rp_filter.before" > /proc/sys/net/ipv4/conf/all/rp_filter
        rm -f "$BASE/rp_filter.before"
    fi
}

ppp_up() (
    local id=$1 iface=$2 table
    id_ok "$id" && [[ $iface =~ ^[a-zA-Z0-9_.-]+$ ]] || return 0
    [[ -f $(profile_dir "$id")/settings ]] || return 0
    exec 8>/run/l2tp-socks-policy.lock
    flock -w 30 8 || { fail 'PPP 路由操作繁忙。'; return 1; }
    load_profile "$id"
    policy_add "$id"
    if [[ ! -f $BASE/rp_filter.before ]]; then
        cat /proc/sys/net/ipv4/conf/all/rp_filter > "$BASE/rp_filter.before"
    fi
    printf '0\n' > /proc/sys/net/ipv4/conf/all/rp_filter
    [[ -w /proc/sys/net/ipv4/conf/"$iface"/rp_filter ]] &&
        printf '0\n' > "/proc/sys/net/ipv4/conf/$iface/rp_filter"
    table=$(table_for "$id")
    ip -4 route replace default dev "$iface" table "$table"
    ip -6 route flush table "$table" 2>/dev/null || true
    if ip -6 addr show dev "$iface" scope global | grep -q 'inet6'; then
        ip -6 route replace default dev "$iface" table "$table"
    fi
    printf '%s\n' "$iface" > "$P/iface"
    chmod 600 "$P/iface"
    render_firewall_locked || return 1
    render_danted "$id" "$iface"
    systemctl restart "l2tp-socks-danted@$id.service" "l2tp-socks-ssserver@$id.service"
    say "配置 $id 已接入 $iface；代理服务已启动。"
)

ppp_down() (
    local id=$1 iface=$2 table current other
    id_ok "$id" || return 0
    [[ -f $(profile_dir "$id")/settings ]] || return 0
    exec 8>/run/l2tp-socks-policy.lock
    flock -w 30 8 || return 0
    P=$(profile_dir "$id")
    current=''
    [[ -f $P/iface ]] && current=$(cat "$P/iface")
    [[ -n $current && $current == "$iface" ]] || return 0
    systemctl stop "l2tp-socks-danted@$id.service" "l2tp-socks-ssserver@$id.service" 2>/dev/null || true
    table=$(table_for "$id")
    ip -4 route flush table "$table" 2>/dev/null || true
    ip -6 route flush table "$table" 2>/dev/null || true
    rm -f "$P/iface"
    render_firewall_locked || return 1
    for other in "$PROFILES"/*/iface; do
        if [[ -f $other ]]; then return 0; fi
    done
    if [[ -f $BASE/rp_filter.before ]]; then
        cat "$BASE/rp_filter.before" > /proc/sys/net/ipv4/conf/all/rp_filter
        rm -f "$BASE/rp_filter.before"
    fi
)

write_units() {
    cat > /etc/systemd/system/l2tp-socks-danted@.service <<'EOF'
[Unit]
Description=L2TP SOCKS5 relay profile %i
After=network-online.target l2tp-socks-policy.service l2tp-socks-firewall.service

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f /etc/l2tp-socks/profiles/%i/danted.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
EOF
    cat > /etc/systemd/system/l2tp-socks-ssserver@.service <<'EOF'
[Unit]
Description=L2TP Shadowsocks relay profile %i
After=network-online.target l2tp-socks-policy.service l2tp-socks-firewall.service

[Service]
Type=simple
User=l2tps%i
Group=l2tps%i
ExecStart=/usr/local/libexec/l2tp-socks/ssserver -c /etc/l2tp-socks/profiles/%i/ssserver.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=true
EOF
    cat > /etc/systemd/system/l2tp-socks-policy.service <<EOF
[Unit]
Description=L2TP SOCKS per-profile policy routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$MANAGER --policy-all
ExecStop=$MANAGER --policy-clear

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/l2tp-socks-firewall.service <<EOF
[Unit]
Description=L2TP SOCKS per-profile traffic marks
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$MANAGER --firewall
ExecStop=$MANAGER --firewall-clear

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/l2tp-socks-autoconnect@.service <<EOF
[Unit]
Description=Connect L2TP SOCKS profile %i at boot
After=network-online.target xl2tpd.service l2tp-socks-policy.service l2tp-socks-firewall.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER --connect %i
TimeoutStartSec=180s
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/l2tp-socks-keepalive@.service <<EOF
[Unit]
Description=Check L2TP SOCKS profile %i and reconnect
After=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGER --healthcheck %i
TimeoutStartSec=180s
EOF
    cat > /etc/systemd/system/l2tp-socks-keepalive@.timer <<'EOF'
[Unit]
Description=Keep L2TP SOCKS profile %i connected

[Timer]
OnBootSec=90s
OnUnitInactiveSec=45s
AccuracySec=10s
Unit=l2tp-socks-keepalive@%i.service

[Install]
WantedBy=timers.target
EOF
    cat > /usr/local/libexec/l2tp-socks/ppp-hook <<EOF
#!/usr/bin/env bash
set -e
[[ \${6:-} =~ ^l2tp-socks-([1-9][0-9]{0,2})\$ ]] || exit 0
id=\${BASH_REMATCH[1]}
case \$(basename "\$0") in
    90-l2tp-socks-up) exec $MANAGER --ppp-up "\$id" "\${1:-}" ;;
    90-l2tp-socks-down) exec $MANAGER --ppp-down "\$id" "\${1:-}" ;;
esac
EOF
    chmod 700 /usr/local/libexec/l2tp-socks/ppp-hook
    install -m 700 /usr/local/libexec/l2tp-socks/ppp-hook /etc/ppp/ip-up.d/90-l2tp-socks-up
    install -m 700 /usr/local/libexec/l2tp-socks/ppp-hook /etc/ppp/ip-down.d/90-l2tp-socks-down
    systemctl daemon-reload
}

install_system() {
    root_required
    require_fresh_layout
    ( . /etc/os-release; [[ $ID == debian || $ID == ubuntu ]] ) || fail '仅支持 Debian 和 Ubuntu。'
    ensure_ppp_device
    install -d -m 711 "$BASE" "$PROFILES"
    install -d -m 755 "$LIB" /etc/ipsec.d /etc/ppp/ip-up.d /etc/ppp/ip-down.d
    if [[ ! -f $BASE/packages.before ]]; then
        dpkg --get-selections | awk '$2=="install" {print $1}' | sort -u > "$BASE/packages.before"
    fi
    if [[ ! -f $BASE/multi-profile.version ]]; then
        say '正在安装 Debian/Ubuntu 依赖。'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y strongswan xl2tpd ppp dante-server nftables libpam-modules python3 curl xz-utils
        if ! grep -Fxq dante-server "$BASE/packages.before"; then
            systemctl disable --now danted.service 2>/dev/null || true
        fi
        dpkg --get-selections | awk '$2=="install" {print $1}' | sort -u > "$BASE/packages.after"
        comm -13 "$BASE/packages.before" "$BASE/packages.after" > "$BASE/packages.added"
    fi
    install_ss_rust
    if [[ $(readlink -f "$0") != "$MANAGER" ]]; then
        install -m 755 "$(readlink -f "$0")" "$MANAGER"
    fi
    write_units
    ensure_include /etc/ipsec.conf "$BASE/ipsec.conf" L2TP_SOCKS_MULTI
    ensure_include /etc/ipsec.secrets "$IPSEC_SECRETS" L2TP_SOCKS_MULTI
    : > "$BASE/multi-profile.version"
    chmod 600 "$BASE/multi-profile.version"
    render_shared_ipsec
    systemctl enable --now l2tp-socks-policy.service l2tp-socks-firewall.service
}

apply_startup() {
    local id=$1
    load_profile "$id"
    if [[ $AUTOSTART == yes ]]; then
        systemctl enable "l2tp-socks-autoconnect@$id.service" >/dev/null
    else
        systemctl disable "l2tp-socks-autoconnect@$id.service" >/dev/null 2>&1 || true
    fi
    if [[ $AUTOSTART == yes && $KEEPALIVE == yes ]]; then
        systemctl enable "l2tp-socks-keepalive@$id.timer" >/dev/null
    else
        systemctl disable "l2tp-socks-keepalive@$id.timer" >/dev/null 2>&1 || true
    fi
    [[ $KEEPALIVE == yes ]] || systemctl stop "l2tp-socks-keepalive@$id.timer" 2>/dev/null || true
}

save_configured_profile() {
    local id=$1 old_user='' name
    if [[ -f $P/settings ]]; then
        old_user=$(sed -n 's/^SOCKS_USER=//p' "$P/settings" | head -n 1)
    fi
    install -d -m 700 "$P"
    ensure_account "l2tpd$id" "$P/owner-l2tpd$id"
    ensure_account "l2tps$id" "$P/owner-l2tps$id"
    ensure_account "$SOCKS_USER" "$P/owner-$SOCKS_USER"
    printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASS" | chpasswd
    save_profile
    if [[ -n $old_user && $old_user != "$SOCKS_USER" && -f $P/owner-$old_user ]]; then
        if ! id -- "$old_user" >/dev/null 2>&1 || userdel -- "$old_user"; then
            rm -f "$P/owner-$old_user"
        else
            say "提示：旧 SOCKS5 账号 $old_user 暂未删除，已保留归属记录供卸载时重试。" >&2
        fi
    fi
    rm -f "$P/endpoint" "$P/iface"
    render_ss "$id"
    render_shared_ipsec
    if pgrep -x charon >/dev/null 2>&1; then
        ipsec reload || fail 'IPsec 配置重载失败。'
        ipsec rereadsecrets || fail 'IPsec 密钥重载失败。'
    fi
    policy_add "$id"
    render_firewall
    apply_startup "$id"
}

setup_profile() {
    root_required
    require_fresh_layout
    local id=${1:-} existing=no
    if [[ -z $id ]]; then id=$(next_id); fi
    id_ok "$id" || fail '配置 ID 无效。'
    [[ -f $(profile_dir "$id")/settings ]] && existing=yes
    prompt_profile "$id"
    install_system
    if [[ $existing == yes ]]; then
        # Subshell keeps the newly entered values in this process.
        (disconnect_profile "$id")
    fi
    save_configured_profile "$id"
    say "配置 $id（$PROFILE_NAME）已保存，SOCKS5=$SOCKS_PORT，SS=$SS_PORT。"
    read -r -p '现在连接此出口？输入 y：' answer
    if [[ $answer == y || $answer == Y ]]; then connect_profile "$id"; fi
}

ipsec_ready() {
    local id=$1 status name
    name=$(conn_name "$id")
    status=$(timeout 8s ipsec statusall 2>/dev/null || true)
    grep -Eq "$name\\[[0-9]+\\]:.*ESTABLISHED" <<< "$status" &&
        grep -Eq "$name\\{[0-9]+\\}:.*INSTALLED" <<< "$status"
}

vpn_healthy() {
    local id=$1 iface table
    load_profile "$id"; load_endpoint
    [[ -n $IFACE ]] || return 1
    ipsec_ready "$id" || return 1
    ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q ' inet ' || return 1
    table=$(table_for "$id")
    ip -4 route show table "$table" | grep -q "^default dev $IFACE"
}

stop_profile_services() {
    local id=$1
    systemctl stop "l2tp-socks-danted@$id.service" "l2tp-socks-ssserver@$id.service" 2>/dev/null || true
    local table
    table=$(table_for "$id")
    ip -4 route flush table "$table" 2>/dev/null || true
    ip -6 route flush table "$table" 2>/dev/null || true
}

disconnect_profile() {
    local id=$1
    load_profile "$id"
    if [[ ${2:-} != keep-timer ]]; then
        systemctl stop "l2tp-socks-keepalive@$id.timer" 2>/dev/null || true
    fi
    stop_profile_services "$id"
    if systemctl is-active --quiet xl2tpd.service && command -v xl2tpd-control >/dev/null 2>&1; then
        xl2tpd-control disconnect-lac "$(conn_name "$id")" >/dev/null 2>&1 || true
        xl2tpd-control remove-lac "$(conn_name "$id")" >/dev/null 2>&1 || true
    fi
    ipsec down "$(conn_name "$id")" >/dev/null 2>&1 || true
    if [[ -f $P/iface ]]; then
        ppp_down "$id" "$(cat "$P/iface")" || true
    fi
    say "配置 $id 已断开；其他出口保持运行。"
}

proposal_order() {
    case $IKE_MODE in
        auto)
            if [[ $LAST_GOOD == strongswan ]]; then printf 'strongswan\ncompat\n'; else printf 'compat\nstrongswan\n'; fi ;;
        *) printf '%s\n' "$IKE_MODE" ;;
    esac
}

connect_profile() {
    local id=$1 resolved source_ip previous_ip proposal connected=no i
    load_profile "$id"
    ensure_ppp_device
    [[ -f $BASE/multi-profile.version ]] || fail '请先安装/配置。'
    resolved=$(resolve_peer "$L2TP_SERVER") || fail "无法解析落地服务器 $L2TP_SERVER。"
    [[ $resolved =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail '落地服务器没有有效 IPv4 地址。'
    source_ip=$(local_source_for "$resolved") || return
    check_distinct_peer "$id" "$resolved"
    load_endpoint
    previous_ip=$REMOTE_IP
    if [[ $resolved == "$previous_ip" && $source_ip == "$LOCAL_IP" ]] && vpn_healthy "$id"; then
        systemctl start "l2tp-socks-danted@$id.service" "l2tp-socks-ssserver@$id.service"
        if [[ $KEEPALIVE == yes ]]; then systemctl start "l2tp-socks-keepalive@$id.timer"; fi
        say "配置 $id 已在线。"
        return
    fi
    disconnect_profile "$id" keep-timer >/dev/null
    load_profile "$id"
    REMOTE_IP=$resolved LOCAL_IP=$source_ip
    systemctl start l2tp-socks-policy.service l2tp-socks-firewall.service
    policy_add "$id"
    systemctl start xl2tpd.service
    if ! pgrep -x charon >/dev/null 2>&1; then
        # Query one unit directly; grep -q can cause SIGPIPE with pipefail.
        if [[ $(systemctl show --property=LoadState --value strongswan-starter.service 2>/dev/null) == loaded ]]; then
            systemctl start strongswan-starter.service
        elif [[ $(systemctl show --property=LoadState --value strongswan.service 2>/dev/null) == loaded ]]; then
            systemctl start strongswan.service
        else
            fail '未找到 strongSwan IPsec 服务；请确认 strongswan-starter 软件包已安装。'
            return 1
        fi
    fi
    while read -r proposal; do
        ACTIVE_PROPOSAL=$proposal
        save_endpoint
        render_shared_ipsec
        ipsec reload || fail 'IPsec 配置重载失败。'
        ipsec rereadsecrets || fail 'IPsec 密钥重载失败。'
        say "配置 $id：协商 $proposal 提案，落地 $resolved，最长等待 50 秒。"
        if timeout --foreground 50s ipsec up "$(conn_name "$id")"; then
            connected=yes
            LAST_GOOD=$proposal
            save_profile
            break
        fi
        ipsec down "$(conn_name "$id")" >/dev/null 2>&1 || true
    done < <(proposal_order)
    if [[ $connected != yes ]]; then
        fail "配置 $id 的 IPsec 未连通。可能是提案、PSK、对端服务或 UDP 500/4500；请查看 journalctl -t charon -n 80。"
    fi
    for i in $(seq 1 15); do
        [[ -p /var/run/xl2tpd/l2tp-control ]] && break
        sleep 1
    done
    [[ -p /var/run/xl2tpd/l2tp-control ]] || fail 'xl2tpd 控制接口未就绪。'
    xl2tpd-control remove-lac "$(conn_name "$id")" >/dev/null 2>&1 || true
    xl2tpd-control add-lac "$(conn_name "$id")" "pppoptfile=$P/options.ppp" "lns=$resolved" 'redial=yes' ||
        fail '无法向 xl2tpd 添加此配置。'
    xl2tpd-control connect-lac "$(conn_name "$id")" || fail 'xl2tpd 发起连接失败。'
    if [[ $KEEPALIVE == yes ]]; then systemctl start "l2tp-socks-keepalive@$id.timer"; fi
    for i in $(seq 1 25); do
        [[ -s $P/iface ]] && break
        sleep 1
    done
    if [[ -s $P/iface ]]; then
        say "配置 $id 已连接，PPP 接口：$(cat "$P/iface")。"
    else
        fail "配置 $id 的 IPsec 已连接，但 PPP 尚未建立；请查看 journalctl -u xl2tpd -n 80。"
    fi
}

healthcheck_profile() {
    local id=$1 current
    [[ -f $(profile_dir "$id")/settings ]] || return 0
    load_profile "$id"
    [[ $KEEPALIVE == yes ]] || return 0
    current=$(resolve_peer "$L2TP_SERVER" 2>/dev/null || true)
    if vpn_healthy "$id" && [[ -n $current && $current == "$REMOTE_IP" ]]; then
        systemctl start "l2tp-socks-danted@$id.service" "l2tp-socks-ssserver@$id.service"
        return 0
    fi
    if [[ -z $current && -n ${IFACE:-} ]] && vpn_healthy "$id"; then
        say "配置 $id 的 DDNS 暂时无法解析；保持当前连接。"
        return 0
    fi
    say "配置 $id 已断线或落地 IP 变化；正在重拨。"
    connect_profile "$id"
}

show_profiles() {
    local id status iface
    if [[ ! -d $PROFILES ]] || [[ -z $(list_ids) ]]; then
        say '暂无 L2TP 出口配置。'
        return
    fi
    printf '\n%-5s %-20s %-30s %-8s %-8s %-10s\n' 'ID' '名称' '落地服务器' 'SOCKS5' 'SS' '状态'
    while read -r id; do
        load_profile "$id"
        iface=''
        [[ -s $P/iface ]] && iface=$(cat "$P/iface")
        status=断开
        [[ -n $iface ]] && ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q ' inet ' && status="$iface 在线"
        printf '%-5s %-20.20s %-30.30s %-8s %-8s %-10s\n' "$id" "$PROFILE_NAME" "$L2TP_SERVER" "$SOCKS_PORT" "$SS_PORT" "$status"
    done < <(list_ids)
}

show_profile_status() {
    local id=$1 iface table mark
    load_profile "$id"; load_endpoint
    iface=${IFACE:-未连接}
    table=$(table_for "$id"); mark=$(mark_for "$id")
    printf '配置 %s：%s\n落地：%s\n当前解析：%s\nPPP 接口：%s\nSOCKS5：TCP %s\nSS：TCP/UDP %s（%s）\n提案模式：%s，最近成功：%s\n开机自启：%s；保活：%s\n' \
        "$id" "$PROFILE_NAME" "$L2TP_SERVER" "${REMOTE_IP:-未解析}" "$iface" "$SOCKS_PORT" "$SS_PORT" "$SS_METHOD" "$IKE_MODE" "$LAST_GOOD" "$AUTOSTART" "$KEEPALIVE"
    printf '策略标记：%s；路由表：%s\n' "$mark" "$table"
    ip -4 route show table "$table" || true
    printf 'SOCKS5 服务：'; systemctl is-active "l2tp-socks-danted@$id.service" 2>/dev/null || true
    printf 'SS 服务：'; systemctl is-active "l2tp-socks-ssserver@$id.service" 2>/dev/null || true
    printf '保活定时器：'; systemctl is-active "l2tp-socks-keepalive@$id.timer" 2>/dev/null || true
}

show_client_info() {
    local id=$1 host
    load_profile "$id"
    host=$ENTRY_HOST
    [[ -n $host ]] || host=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || printf '中转机公网IP')
    say "配置 $id 的客户端信息（仅当前 root 终端显示）："
    printf 'SOCKS5：%s:%s\n用户名：%s\n密码：%s\n' "$host" "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASS"
    printf 'SS：%s:%s\n加密：%s\n密码：%s\n' "$host" "$SS_PORT" "$SS_METHOD" "$SS_PASS"
    [[ -z $SOCKS_UDP_RANGE ]] || printf 'SOCKS5 UDP 中继：%s\n' "$SOCKS_UDP_RANGE"
    say '云商安全组需放行对应 TCP/UDP 端口。'
}

configure_startup() {
    local id=$1
    load_profile "$id"
    ask AUTOSTART '开机自动连接？yes/no'
    ask KEEPALIVE '断线自动重拨？yes/no'
    [[ $AUTOSTART == yes || $AUTOSTART == no ]] || fail '开机自启请输入 yes/no。'
    [[ $KEEPALIVE == yes || $KEEPALIVE == no ]] || fail '保活请输入 yes/no。'
    save_profile
    apply_startup "$id"
    if [[ $KEEPALIVE == yes && -s $P/iface ]]; then
        systemctl start "l2tp-socks-keepalive@$id.timer"
    fi
    say "配置 $id：开机自启=$AUTOSTART，保活=$KEEPALIVE。"
}

remove_profile() {
    local id=$1
    load_profile "$id"
    disconnect_profile "$id"
    systemctl disable --now "l2tp-socks-autoconnect@$id.service" "l2tp-socks-keepalive@$id.timer" >/dev/null 2>&1 || true
    policy_del "$id"
    remove_owned_accounts "$P" || return 1
    rm -rf -- "$P"
    render_shared_ipsec
    render_firewall
    ipsec reload >/dev/null 2>&1 || true
    ipsec rereadsecrets >/dev/null 2>&1 || true
    say "配置 $id 已删除。"
}

delete_one() {
    local id=$1 answer
    load_profile "$id"
    read -r -p "删除配置 $id（$PROFILE_NAME）及其账号/服务？输入 DELETE：" answer
    [[ $answer == DELETE ]] || { say '已取消。'; return; }
    remove_profile "$id"
}

uninstall_all() {
    local answer id self dir
    say '将删除全部出口、服务、代理账号、配置和管理脚本。'
    read -r -p '确认彻底卸载请输入 DELETE-ALL：' answer
    [[ $answer == DELETE-ALL ]] || { say '已取消。'; return; }
    if [[ -s $BASE/packages.added ]]; then
        local -a packages
        mapfile -t packages < "$BASE/packages.added"
        say '以下是本脚本安装期间新增软件包的卸载预览：'
        apt-get -s purge "${packages[@]}" || fail 'APT 卸载预览失败。'
        read -r -p '确认上述软件包一并卸载请输入 y：' answer
        [[ $answer == y || $answer == Y ]] || { say '已取消彻底卸载；未删除配置。'; return; }
    fi
    while read -r id; do remove_profile "$id" || return 1; done < <(list_ids)
    # Interrupted installations may have ownership records but no settings yet.
    for dir in "$PROFILES"/*; do
        [[ -d $dir && ! -f $dir/settings ]] || continue
        id=${dir##*/}
        id_ok "$id" || continue
        stop_profile_services "$id"
        systemctl disable --now "l2tp-socks-autoconnect@$id.service" "l2tp-socks-keepalive@$id.timer" >/dev/null 2>&1 || true
        remove_owned_accounts "$dir" || return 1
    done
    systemctl disable --now l2tp-socks-policy.service l2tp-socks-firewall.service 2>/dev/null || true
    policy_clear
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" || true
    [[ -f /etc/ipsec.conf ]] && sed -i '/# BEGIN L2TP_SOCKS_MULTI/,/# END L2TP_SOCKS_MULTI/d' /etc/ipsec.conf
    [[ -f /etc/ipsec.secrets ]] && sed -i '/# BEGIN L2TP_SOCKS_MULTI/,/# END L2TP_SOCKS_MULTI/d' /etc/ipsec.secrets
    rm -f "$IPSEC_SECRETS" /etc/ppp/ip-up.d/90-l2tp-socks-up /etc/ppp/ip-down.d/90-l2tp-socks-down
    rm -f /etc/systemd/system/l2tp-socks-{danted,ssserver,autoconnect,keepalive}@.service
    rm -f /etc/systemd/system/l2tp-socks-{policy,firewall}.service /etc/systemd/system/l2tp-socks-keepalive@.timer
    systemctl daemon-reload
    if [[ -s $BASE/packages.added ]]; then
        mapfile -t packages < "$BASE/packages.added"
        apt-get purge -y "${packages[@]}" || fail 'APT 卸载未完成；管理脚本暂保留以便重试。'
    fi
    rm -rf -- "$LIB" "$BASE"
    self=$(readlink -f "$0")
    rm -f "$MANAGER"
    [[ $self == "$MANAGER" ]] || rm -f -- "$self"
    say '多出口配置及脚本已彻底卸载。'
}

select_id() {
    local answer
    show_profiles >&2
    read -r -p '请输入配置 ID：' answer
    id_ok "$answer" || fail '配置 ID 无效。'
    [[ -f $(profile_dir "$answer")/settings ]] || fail "配置 $answer 不存在。"
    printf '%s' "$answer"
}

run_manager_locked() {
    exec 9>/run/l2tp-socks-manager.lock
    flock -w 240 9 || fail '另一个配置操作正在进行，请稍后重试。'
    "$@"
}

menu_action() {
    local choice=$1 id
    case $choice in
        1) run_manager_locked setup_profile ;;
        2) id=$(select_id); run_manager_locked setup_profile "$id" ;;
        3) id=$(select_id); run_manager_locked connect_profile "$id" ;;
        4) id=$(select_id); run_manager_locked disconnect_profile "$id" ;;
        5) show_profiles; id=$(select_id); show_profile_status "$id" ;;
        6) id=$(select_id); show_client_info "$id" ;;
        7) id=$(select_id); run_manager_locked configure_startup "$id" ;;
        8) id=$(select_id); run_manager_locked delete_one "$id" ;;
        9) run_manager_locked uninstall_all ;;
        *) fail '无效操作。' ;;
    esac
}

main() {
    root_required
    case ${1:-} in
        --policy-all) policy_all; return ;;
        --policy-clear) policy_clear; return ;;
        --firewall) render_firewall; return ;;
        --firewall-clear) nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" || true; return ;;
        --ppp-up) ppp_up "${2:-}" "${3:-}"; return ;;
        --ppp-down) ppp_down "${2:-}" "${3:-}"; return ;;
        --connect) run_manager_locked connect_profile "${2:-}"; return ;;
        --healthcheck)
            exec 9>/run/l2tp-socks-manager.lock
            flock -n 9 || return 0
            healthcheck_profile "${2:-}"; return ;;
        --action) menu_action "${2:-}"; return ;;
        '') ;;
        *) fail '未知命令参数。'; return ;;
    esac
    require_fresh_layout
    while true; do
        printf '\n==== L2TP/IPsec 多出口代理管理 ====\n'
        printf '1. 新增出口\n2. 修改出口\n3. 连接出口\n4. 断开出口\n5. 出口列表与状态\n6. 显示客户端信息\n7. 保活与开机自启\n8. 删除单个出口\n9. 彻底卸载并删除脚本\n0. 退出\n'
        read -r -p '请选择：' choice || return 0
        case $choice in
            [1-9])
                if bash "$(readlink -f "$0")" --action "$choice"; then
                    [[ $choice == 9 && ! -f $MANAGER ]] && return 0
                else
                    say '操作未完成，请查看上面的错误信息。'
                fi ;;
            0) return 0 ;;
            *) say '无效选项。' ;;
        esac
    done
}

main "$@"
