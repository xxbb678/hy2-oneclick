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

detect_net() {
    local warp_if="" dev addr v6
    for c in WARP warp wgcf wg0 warp0; do
        if ip link show "$c" >/dev/null 2>&1; then warp_if="$c"; break; fi
    done

    for dev in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        echo "$dev" | grep -qE "$EXCLUDE_RE" && continue
        [ -n "$warp_if" ] && [ "$dev" = "$warp_if" ] && continue
        addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$addr" ] && { echo "IPv4|$addr|$warp_if|$dev"; return; }
    done

    for dev in $(ip -6 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
        echo "$dev" | grep -qE "$EXCLUDE_RE" && continue
        [ -n "$warp_if" ] && [ "$dev" = "$warp_if" ] && continue
        v6=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -vE '^2606:4700|^fe80' | head -1)
        [ -n "$v6" ] && { echo "IPv6|$v6|$warp_if|$dev"; return; }
    done

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
        PUB_IP=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || echo "")
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

    [[ -z "$NEW_PORT" ]] && NEW_PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 输入无效${NC}"; return
    fi
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

    echo -ne "${YELLOW}请输入监听端口 (回车10000-65535随机): ${NC}"
    read PORT
    [[ -z "$PORT" ]] && PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}❌ 端口无效，使用随机端口${NC}"
        PORT=$(( ( RANDOM % 55535 ) + 10000 ))
    fi

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
    [ -z "$PUB_IP" ] && PUB_IP=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || echo "")
    case "$PUB_IP" in *:*) LINK_HOST="[$PUB_IP]" ;; *) LINK_HOST="$PUB_IP" ;; esac

    LISTEN_ST="未检测到"
    if ss -uln 2>/dev/null | grep -q ":$PORT"; then
        LISTEN_ST="正常"
    elif netstat -uln 2>/dev/null | grep -q ":$PORT"; then
        LISTEN_ST="正常"
    fi

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
    echo -e " ${CYAN}[0]${NC} 退出脚本"
    echo -e "${GREEN}===============================================${NC}"
    echo -ne "请输入数字选择 [0-5]: "
    read choice

    case $choice in
        1) install_hy2 ;;
        2) show_info ;;
        3) change_port ;;
        4) restart_service && echo -e "${GREEN}服务已重启${NC}" ;;
        5) uninstall_hy2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择${NC}"; sleep 1 ;;
    esac

    echo -e "\n${YELLOW}按任意键返回主菜单...${NC}"
    read -n 1 -s -r
    clear
done
