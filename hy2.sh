#!/usr/bin/env bash
set -e

### ===== 配置参数 =====
SERVER_NAME="www.bing.com"
TAG="HY2"
WORKDIR="/etc/hysteria"
BIN="/usr/local/bin/hysteria"
YQ_BIN="/usr/local/bin/yq"
CONF="$WORKDIR/config.yaml"
PORT_FILE="$WORKDIR/port.txt"
UUID_FILE="$WORKDIR/uuid.txt"
CERT_FILE="$WORKDIR/server.crt"
KEY_FILE="$WORKDIR/server.key"
PINSHA_FILE="$WORKDIR/pinsha256.txt"
### =====================

GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
CYAN='\e[36m'
NC='\e[0m'

[[ "$(id -u)" != "0" ]] && { echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; }

# 环境判断
if command -v apk >/dev/null 2>&1; then
    OS="alpine"
elif command -v apt >/dev/null 2>&1; then
    OS="debian"
else
    echo -e "${RED}❌ 仅支持 Alpine / Debian / Ubuntu${NC}"
    exit 1
fi

# 生成 UUID
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -xN16 /dev/urandom | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8}'
    fi
}

# ---------------- 网络环境识别 ----------------
# 按网卡排除 WARP 与 docker 等虚拟网卡，判定原生 IPv4 / 纯 IPv6
# 返回：模式|IP地址|WARP网卡|出口网卡
EXCLUDE_RE='^(lo|docker.*|br-.*|veth.*|virbr.*|tun.*|tap.*|tailscale.*|podman.*|cni.*|flannel.*|cali.*|kube.*|wgcf.*|warp.*|WARP.*)$'

# 判断是否为私有 / 不可路由地址
_is_private() {
    case "$1" in
        10.*|192.168.*|127.*|169.254.*|0.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        fd*|fc*|fe80*|::1) return 0 ;;
        *) return 1 ;;
    esac
}

# 通过外部 API 获取真实公网出口 IP（NAT/内网环境必备）
# $1: 4 或 6，指定优先协议
fetch_public_ip() {
    local fam="${1:-4}" ip="" u
    if [ "$fam" = "6" ]; then
        for u in https://api64.ipify.org https://ifconfig.me/ip https://ip.sb; do
            ip=$(curl -s6 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
            case "$ip" in *:*) printf '%s' "$ip"; return 0 ;; esac
        done
    else
        for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://ip.sb; do
            ip=$(curl -s4 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
            case "$ip" in
                ""|*:*) ;;
                [0-9]*.[0-9]*) printf '%s' "$ip"; return 0 ;;
            esac
        done
    fi
    return 1
}

detect_net() {
    local warp_if="" dev addr v6 pub
    for c in WARP warp wgcf wg0 warp0; do
        if ip link show "$c" >/dev/null 2>&1; then warp_if="$c"; break; fi
    done

    # 优先原生公网 IPv4；若为内网地址则探测真实公网出口（NAT）
    for dev in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        echo "$dev" | grep -qE "$EXCLUDE_RE" && continue
        [ -n "$warp_if" ] && [ "$dev" = "$warp_if" ] && continue
        addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [ -z "$addr" ] && continue
        if _is_private "$addr"; then
            pub=$(fetch_public_ip 4)
            if [ -n "$pub" ]; then echo "NAT|$pub|$warp_if|$dev"; return; fi
            continue
        fi
        echo "IPv4|$addr|$warp_if|$dev"; return
    done

    # 原生公网 IPv6；内网（ULA 等）同样探测公网出口
    for dev in $(ip -6 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        echo "$dev" | grep -qE "$EXCLUDE_RE" && continue
        [ -n "$warp_if" ] && [ "$dev" = "$warp_if" ] && continue
        v6=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -vE '^2606:4700|^fe80' | head -1)
        [ -z "$v6" ] && continue
        if _is_private "$v6"; then
            pub=$(fetch_public_ip 6)
            if [ -n "$pub" ]; then echo "NAT6|$pub|$warp_if|$dev"; return; fi
            continue
        fi
        echo "IPv6|$v6|$warp_if|$dev"; return
    done

    # 都没命中：直接向外部查公网出口
    pub=$(fetch_public_ip 4)
    if [ -n "$pub" ]; then echo "NAT|$pub|$warp_if|"; return; fi
    pub=$(fetch_public_ip 6)
    if [ -n "$pub" ]; then echo "NAT6|$pub|$warp_if|"; return; fi

    echo "unknown||$warp_if|"
}
# ---------------- pinSHA256 处理 ----------------
# 校验并规范化：合法为 64 位 base64 或 64 位十六进制（冒号格式自动转换），否则返回空
normalize_pinsha() {
    local v
    v=$(printf '%s' "$1" | tr -d '[:space:]')
    [ -z "$v" ] && return 0
    if printf '%s' "$v" | grep -qE '^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$'; then
        v=$(printf '%s' "$v" | tr -d ':' | tr 'a-f' 'A-F')
    fi
    if printf '%s' "$v" | grep -qE '^[A-Za-z0-9+/]{43}=$|^[A-Za-z0-9+/]{44}$|^[0-9A-Fa-f]{64}$'; then
        printf '%s' "$v"
    fi
}

# 从证书公钥直接算 SHA-256 指纹（最可靠的一手来源）
calc_pinsha_from_cert() {
    local fp
    [ -f "$CERT_FILE" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0
    fp=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
    normalize_pinsha "$fp"
}

# 获取 pinSHA256（优先读存储文件，无则现算，最后校验）
get_pin_sha256() {
    local v=""
    if [ -f "$PINSHA_FILE" ]; then
        v=$(cat "$PINSHA_FILE" 2>/dev/null)
    fi
    v=$(normalize_pinsha "$v")
    if [ -z "$v" ]; then
        v=$(calc_pinsha_from_cert)
    fi
    printf '%s' "$v"
}

# 检测端口在外部是否可达（用一个临时 UDP 服务 + 反向验证）
# 这里采用轻量方式：检查端口是否已被占用 + 可选的外部回显测试
_port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -uln 2>/dev/null | grep -q ":$p " && return 0
        ss -tln 2>/dev/null | grep -q ":$p " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -uln 2>/dev/null | grep -q ":$p " && return 0
        netstat -tln 2>/dev/null | grep -q ":$p " && return 0
    fi
    return 1
}

# 智能选择端口：若用户指定则直接用（并提醒）；
# 否则在 10000-65535 范围内找一个未被占用的端口
pick_port() {
    local want="${1:-}" i p tries=0
    if [ -n "$want" ]; then
        if _port_in_use "$want"; then
            echo -e "${YELLOW}⚠️ 端口 $want 已被本机占用，改用随机端口${NC}" >&2
        else
            printf '%s' "$want"; return 0
        fi
    fi
    for i in $(seq 1 60); do
        p=$(( ( RANDOM % 55535 ) + 10000 ))
        if ! _port_in_use "$p"; then
            printf '%s' "$p"; return 0
        fi
    done
    printf '%s' "$(( ( RANDOM % 55535 ) + 10000 ))"
}

# 重启服务
restart_service() {
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria restart
    else
        systemctl restart hysteria
    fi
}

# 显示配置信息
show_info() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 配置文件不存在${NC}"
        return
    fi

    PORT=$($YQ_BIN '.listen' "$CONF" | sed 's/://g')
    UUID=$($YQ_BIN '.auth.userpass | keys | .[0]' "$CONF")
    if [ -z "$UUID" ] || [ "$UUID" = "null" ]; then
        UUID=$(cat "$UUID_FILE" 2>/dev/null)
    fi
    PINSHA256=$(get_pin_sha256)

    echo -e "${YELLOW}正在检测网络环境...${NC}"
    NETLINE=$(detect_net)
    NET_MODE=$(echo "$NETLINE" | cut -d'|' -f1)
    PUB_IP=$(echo "$NETLINE" | cut -d'|' -f2)
    WARP_IF=$(echo "$NETLINE" | cut -d'|' -f3)
    IFACE=$(echo "$NETLINE" | cut -d'|' -f4)

    if [ -z "$PUB_IP" ]; then
        PUB_IP=$(fetch_public_ip 4) || PUB_IP=$(fetch_public_ip 6) || PUB_IP=""
    fi

    LINK_HOST="$PUB_IP"
    case "$PUB_IP" in *:*) LINK_HOST="[$PUB_IP]" ;; esac

    echo -e "\n${GREEN}========== Hysteria2 配置信息 ==========${NC}"
    echo -e "🌐 网络模式: ${YELLOW}$NET_MODE${NC}"
    echo -e "🛰️ 出口网卡: ${YELLOW}${IFACE:-未知}${NC}"
    echo -e "🔀 WARP网卡: ${YELLOW}${WARP_IF:-无}${NC}"
    echo -e "📌 节点地址: ${YELLOW}$LINK_HOST${NC}"
    echo -e "🎲 监听端口: ${YELLOW}$PORT${NC}"
    echo -e "🆔 认证UUID: ${YELLOW}$UUID${NC}"
    if [ -n "$PINSHA256" ]; then
        echo -e "🔑 pinSHA256: ${YELLOW}$PINSHA256${NC}"
    else
        echo -e "🔑 pinSHA256: ${RED}未取得${NC}"
        _fp=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
        [ -n "$_fp" ] && echo -e "   ${YELLOW}证书实际指纹(SHA-256): $_fp${NC}"
        echo -e "   ${YELLOW}提示：ipinSHA256 缺失时客户端将依赖证书校验或 insecure 模式，建议重装以重建证书指纹${NC}"
    fi

    if [ -n "$PUB_IP" ]; then
        echo -e "\n${GREEN}📎 节点链接:${NC}"
        echo -e "${YELLOW}hy2://$UUID@$LINK_HOST:$PORT?sni=$SERVER_NAME&alpn=h3&insecure=1&pinSHA256=$PINSHA256#${TAG}_${NET_MODE}${NC}"
        case "$NET_MODE" in
            NAT|NAT6)
                echo -e "${YELLOW}⚠ 当前为 NAT 环境，链接使用公网出口 IP。若连不上，请确认服务商已将该 UDP 端口映射到本机${NC}"
                ;;
        esac
    else
        echo -e "${RED}❌ 无法检测到公网 IP${NC}"
    fi
    echo -e "${GREEN}===============================================${NC}\n"
}

# 更改端口
change_port() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    OLD_PORT=$($YQ_BIN '.listen' "$CONF" | sed 's/://g')
    echo -e "当前端口为: ${YELLOW}$OLD_PORT${NC}"
    echo -ne "${YELLOW}请输入新端口 (回车10000-65535随机): ${NC}"
    read NEW_PORT

    if [ -n "$NEW_PORT" ]; then
        if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
            echo -e "${RED}❌ 输入无效${NC}"; return
        fi
    fi
    NEW_PORT=$(pick_port "$NEW_PORT")
    $YQ_BIN -i ".listen = \":$NEW_PORT\"" "$CONF"
    echo "$NEW_PORT" > "$PORT_FILE"

    command -v ufw >/dev/null 2>&1 && ufw allow "$NEW_PORT"/udp
    restart_service
    echo -e "${GREEN}✅ 端口已更改为 $NEW_PORT${NC}"
    show_info
}

# 安装
install_hy2() {
    echo -e "${YELLOW}▶ 正在安装依赖 ...${NC}"
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache curl openssl ca-certificates bash
    else
        apt update && apt install -y curl openssl ca-certificates bash
    fi

    if [ ! -f "$YQ_BIN" ]; then
        echo -e "${YELLOW}▶ 安装 yq 工具...${NC}"
        YQ_ARCH=$(uname -m)
        case "$YQ_ARCH" in
            x86_64) YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
            aarch64) YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
            *) echo "❌ 不支持的架构"; exit 1 ;;
        esac
        curl -L -o "$YQ_BIN" "$YQ_URL" && chmod +x "$YQ_BIN"
    fi

    mkdir -p "$WORKDIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE="hysteria-linux-amd64" ;;
        aarch64) FILE="hysteria-linux-arm64" ;;
        *) echo "❌ 不支持的架构"; exit 1 ;;
    esac

    echo -e "${YELLOW}▶ 下载 Hysteria2...${NC}"
    curl -L -o "$BIN" "https://download.hysteria.network/app/latest/$FILE"
    chmod +x "$BIN"

    UUID=$(gen_uuid)

    # NAT 环境提醒：本机无法感知宿主机端口映射，建议手动指定已映射的 UDP 端口
    _NETPRE=$(detect_net | cut -d'|' -f1)
    case "$_NETPRE" in
        NAT|NAT6)
            echo -e "${YELLOW}⚠ 检测到 NAT 内网环境：请手动输入服务商已映射的 UDP 端口（回车随机可能不通）${NC}"
            ;;
    esac

    echo -ne "${YELLOW}请输入监听端口 (UDP，回车自动选可用端口): ${NC}"
    read -r _IN_PORT
    if [ -n "$_IN_PORT" ]; then
        if [[ ! "$_IN_PORT" =~ ^[0-9]+$ ]] || [ "$_IN_PORT" -lt 1 ] || [ "$_IN_PORT" -gt 65535 ]; then
            echo -e "${RED}❌ 端口无效，自动选择可用端口${NC}"
            _IN_PORT=""
        fi
    fi
    PORT=$(pick_port "$_IN_PORT")
    echo -e "${GREEN}✓ 将使用端口: $PORT (UDP)${NC}"

    echo "$UUID" > "$UUID_FILE"
    echo "$PORT" > "$PORT_FILE"

    # 先清除旧的 pinSHA256，避免重装时残留旧指纹误导客户端
    rm -f "$PINSHA_FILE"

    echo -e "${YELLOW}▶ 使用 hysteria cert 生成自签名证书...${NC}"
    cd /root

    CERT_LOG="/tmp/hysteria_cert.log"
    $BIN cert > "$CERT_LOG" 2>&1
    echo -e "${GREEN}✅ 证书生成完成${NC}"

    mv -f server.crt "$CERT_FILE" 2>/dev/null || true
    mv -f server.key "$KEY_FILE" 2>/dev/null || true

    # 多源提取：1) hysteria cert 日志  2) 从证书直接算（最可靠）
    PINSHA256=$(grep -oE 'pinSHA256:[[:space:]]*[A-Za-z0-9+/=]+' "$CERT_LOG" 2>/dev/null | head -n1 | sed 's/pinSHA256:[[:space:]]*//')
    PINSHA256=$(normalize_pinsha "$PINSHA256")
    if [ -z "$PINSHA256" ]; then
        echo -e "${YELLOW}⚠️ 日志中未取到指纹，改从证书直接计算...${NC}"
        PINSHA256=$(calc_pinsha_from_cert)
    fi

    if [ -n "$PINSHA256" ]; then
        _tmp_pin="${PINSHA_FILE}.tmp.$$"
        printf '%s\n' "$PINSHA256" > "$_tmp_pin"
        chmod 600 "$_tmp_pin"
        mv -f "$_tmp_pin" "$PINSHA_FILE"
        echo -e "${GREEN}✅ pinSHA256 已提取并安全保存 (600): $PINSHA256${NC}"
    else
        echo -e "${RED}❌ 未能获取合法 pinSHA256${NC}"
        echo -e "${YELLOW}日志内容：${NC}"
        cat "$CERT_LOG"
    fi
    rm -f "$CERT_LOG"

    # 写入配置（UUID 认证）
    cat > "$CONF" <<EOF
listen: :$PORT
resolver:
  type: tls
  tls:
    addr: 1.1.1.1:853
    timeout: 5s
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
  sniGuard: disable
  alpn:
    - h3
auth:
  type: userpass
  userpass:
    $UUID: $UUID
masquerade:
  type: proxy
  proxy:
    url: https://$SERVER_NAME
    rewriteHost: true
EOF

    if [ "$OS" = "alpine" ]; then
        cat > /etc/init.d/hysteria <<EOF
#!/sbin/openrc-run
name="hysteria"
command="$BIN"
command_args="server -c $CONF"
command_background=true
pidfile="/run/hysteria.pid"
supervisor="supervise-daemon"
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default
    else
        cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Service
After=network.target
[Service]
ExecStart=$BIN server -c $CONF
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria
    fi

    restart_service
    echo -e "${GREEN}✅ Hysteria2 安装完成 ${NC}"

    NETLINE=$(detect_net)
    NET_MODE=$(echo "$NETLINE" | cut -d'|' -f1)
    PUB_IP=$(echo "$NETLINE" | cut -d'|' -f2)
    WARP_IF=$(echo "$NETLINE" | cut -d'|' -f3)
    IFACE=$(echo "$NETLINE" | cut -d'|' -f4)
    if [ -z "$PUB_IP" ]; then
        PUB_IP=$(fetch_public_ip 4) || PUB_IP=$(fetch_public_ip 6) || PUB_IP=""
    fi
    case "$PUB_IP" in *:*) LINK_HOST="[$PUB_IP]" ;; *) LINK_HOST="$PUB_IP" ;; esac

    LISTEN_ST="未检测到"
    if ss -uln 2>/dev/null | grep -q ":$PORT"; then
        LISTEN_ST="正常"
    elif netstat -uln 2>/dev/null | grep -q ":$PORT"; then
        LISTEN_ST="正常"
    fi

    # NAT 环境提醒：端口映射由宿主机控制，本机无法自检外部可达性
    case "$NET_MODE" in
        NAT|NAT6)
            echo -e "${YELLOW}⚠ NAT 环境：端口映射由宿主机控制，若外部连不通请确认该端口 UDP 映射已开放${NC}"
            ;;
    esac

    clear
    echo -e "${GREEN}=============== 安装完成 ===============${NC}"
    echo -e "系统:     $OS"
    echo -e "网络模式: $NET_MODE"
    echo -e "出口网卡: ${IFACE:-未知}  (WARP: ${WARP_IF:-无})"
    echo -e "节点地址: $LINK_HOST"
    echo -e "监听端口: $PORT (UDP)  监听状态: $LISTEN_ST"
    echo -e "认证UUID: $UUID"
    if [ -n "$PINSHA256" ]; then
        echo -e "pinSHA256: $PINSHA256"
    else
        echo -e "pinSHA256: 未取得（客户端将依赖 insecure 模式，建议重装）"
    fi
    echo -e "SNI:      $SERVER_NAME"
    echo -e ""
    echo -e "${GREEN}📎 节点链接:${NC}"
    echo -e "${YELLOW}hy2://$UUID@$LINK_HOST:$PORT?sni=$SERVER_NAME&alpn=h3&insecure=1&pinSHA256=$PINSHA256#${TAG}_${NET_MODE}${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 卸载
uninstall_hy2() {
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    if [ "$OS" = "alpine" ]; then
        rc-service hysteria stop || true
        rc-update del hysteria || true
        rm -f /etc/init.d/hysteria
    else
        systemctl stop hysteria || true
        systemctl disable hysteria || true
        rm -f /etc/systemd/system/hysteria.service
        systemctl daemon-reload
    fi
    rm -rf "$WORKDIR"
    rm -f "$BIN"
    echo -e "${GREEN}✅ 卸载成功${NC}"
}

# 端口健康检查：起临时 UDP 回显，提示从外部验证
check_port_reachability() {
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}❌ 请先安装 Hysteria2${NC}"; return
    fi
    local p linkip
    p=$($YQ_BIN '.listen' "$CONF" | sed 's/.*://')
    linkip=$(detect_net | cut -d'|' -f2)
    echo ""
    echo -e "${GREEN}========== 端口可达性检查 ==========${NC}"
    echo -e "当前端口: ${YELLOW}$p (UDP)${NC}"
    echo -e "节点地址: ${YELLOW}$linkip${NC}"
    echo ""
    echo -e "${YELLOW}请在另一台机器（有公网出口）上执行以下命令验证：${NC}"
    echo -e "  ${CYAN}nc -u -z -v $linkip $p${NC}"
    echo -e "  ${CYAN}# 或用 hysteria 客户端导入链接直接测试${NC}"
    echo ""
    local st="未检测到"
    if ss -uln 2>/dev/null | grep -q ":$p"; then st="本机监听正常"; fi
    echo -e "本机监听: ${YELLOW}$st${NC}"
    echo -e ""
    echo -e "${YELLOW}提示：UDP 无连接，nc -u -z 返回 open 不代表真可达。最准确的方法是用 hysteria 客户端实际连一次。${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 主菜单
while true; do
    if [ "$OS" = "alpine" ]; then
        if rc-service hysteria status 2>/dev/null | grep -q "started"; then
            STATUS="${GREEN}正在运行${NC}"
        else
            STATUS="${RED}未安装或未运行${NC}"
        fi
    else
        if systemctl is-active --quiet hysteria 2>/dev/null; then
            STATUS="${GREEN}正在运行${NC}"
        else
            STATUS="${RED}未安装或未运行${NC}"
        fi
    fi

    clear
    echo -e "${GREEN}===============================================${NC}"
    echo -e " Hysteria2 一键管理脚本 (UUID 版)"
    echo -e " 当前系统: $OS"
    echo -e " Hy2状态： $STATUS"
    echo -e "${GREEN}===============================================${NC}"
    echo -e " ${CYAN}[1]${NC} 安装 Hysteria2"
    echo -e " ${CYAN}[2]${NC} 查看配置节点链接"
    echo -e " ${CYAN}[3]${NC} 更改监听端口"
    echo -e " ${CYAN}[4]${NC} 重启服务"
    echo -e " ${CYAN}[5]${NC} 卸载 Hysteria2"
    echo -e " ${CYAN}[6]${NC} 端口可达性检查"
    echo -e " ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    echo -ne "请输入数字选择 [0-6]: "
    read choice

    case $choice in
        1) install_hy2 ;;
        2) show_info ;;
        3) change_port ;;
        4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;;
        5) uninstall_hy2 ;;
        6) check_port_reachability ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择${NC}"; sleep 1 ;;
    esac

    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
    clear
done