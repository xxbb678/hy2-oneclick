#!/bin/sh
# ============================================================
# SOCKS5 代理一键搭建（合并版：多系统 + 纯 IPv6/WARP 修复）
# 支持：Alpine / Debian / Ubuntu，自动识别 IPv4 / 纯 IPv6，兼容 WARP 出站
# 用法：改下面参数，保存为 sk5.sh 后执行： sh sk5.sh
# ============================================================

# 以下参数会在安装时交互式询问；也可用环境变量预先指定（非交互场景）
PORT="${SK5_PORT:-}"
USER="${SK5_USER:-}"
PASS="${SK5_PASS:-}"

set -e

# ---------- 卸载模式 ----------
# 安装：sh sk5.sh
# 卸载：sh sk5.sh uninstall
uninstall_sk5() {
    echo "==> 开始卸载 SOCKS5 代理"

    if command -v apk >/dev/null 2>&1; then
        rc-service sockd stop 2>/dev/null || true
        rc-update del sockd default 2>/dev/null || true
        rm -f /etc/sockd.conf /etc/danted.conf
        deluser "$USER" 2>/dev/null || true
        apk del dante-server dante-server-openrc 2>/dev/null || true

    elif command -v apt-get >/dev/null 2>&1; then
        systemctl stop danted microsocks 2>/dev/null || true
        systemctl disable danted microsocks 2>/dev/null || true
        rm -f /etc/danted.conf /etc/sockd.conf
        rm -f /etc/systemd/system/microsocks.service
        systemctl daemon-reload 2>/dev/null || true
        userdel -f "$USER" 2>/dev/null || true

        dpkg-query -W -f='${Status}' dante-server 2>/dev/null | grep -q 'install ok installed' && apt-get remove --purge -y dante-server || true
        dpkg-query -W -f='${Status}' microsocks 2>/dev/null | grep -q 'install ok installed' && apt-get remove --purge -y microsocks || true
        apt-get autoremove -y 2>/dev/null || true
    else
        echo "❌ 未识别的系统"
        exit 1
    fi

    echo ""
    echo "=== 卸载验证 ==="
    if netstat -tulnp 2>/dev/null | grep -q ":${PORT} "; then
        echo "⚠️ 端口 ${PORT} 仍在使用"
        netstat -tulnp 2>/dev/null | grep ":${PORT} " || true
        exit 1
    elif ss -tulnp 2>/dev/null | grep -q ":${PORT} "; then
        echo "⚠️ 端口 ${PORT} 仍在使用"
        ss -tulnp 2>/dev/null | grep ":${PORT} " || true
        exit 1
    else
        echo "✅ SOCKS5 已卸载，端口 ${PORT} 已释放"
    fi
}

case "${1:-install}" in
    uninstall|remove|del)
        uninstall_sk5
        exit 0
        ;;
    install|"")
        ;;
    *)
        echo "用法：sh $0 [install|uninstall]"
        exit 1
        ;;
esac

# ---------- 交互式采集参数 ----------
# 仅安装时询问；环境变量已指定则跳过。
# 管道方式（curl ... | sh）下 stdin 被脚本本体占用，改从 /dev/tty 读取。
# 生成 16 位随机密码（兼容 busybox 与 GNU coreutils）
gen_pass() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 8
    elif [ -r /dev/urandom ]; then
        od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
    else
        head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# URL 编码（用于 TG 链接中的用户名/密码）
urlenc() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null && return
    fi
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/@/%40/g' -e 's/#/%23/g' -e 's/ /%20/g' -e 's/+/%2B/g'
}

ask_params() {
    # 若三个参数都已由环境变量提供，直接返回
    if [ -n "$PORT" ] && [ -n "$USER" ] && [ -n "$PASS" ]; then
        echo "    使用环境变量参数: 端口=$PORT 用户=$USER"
        return 0
    fi

    _TTY=/dev/tty
    _HAS_TTY=0
    if [ -e "$_TTY" ]; then
        if (: < "$_TTY") 2>/dev/null; then
            _HAS_TTY=1
        fi
    fi
    if [ "$_HAS_TTY" = "0" ]; then
        # 无交互终端：用默认值兜底
        [ -z "$PORT" ] && PORT=21461
        [ -z "$USER" ] && USER="admin"
        if [ -z "$PASS" ]; then
            PASS=$(gen_pass)
        fi
        echo "    无交互终端，使用默认参数: 端口=$PORT 用户=$USER"
        return 0
    fi

    # 端口
    if [ -z "$PORT" ]; then
        while :; do
            printf "
请输入监听端口 (1-65535，直接回车默认 21461): " > "$_TTY"
            read -r _p < "$_TTY" || _p=""
            [ -z "$_p" ] && { PORT=21461; break; }
            case "$_p" in
                *[!0-9]*|'') echo "⚠ 端口必须是数字" > "$_TTY" ;;
                *) if [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; then PORT="$_p"; break; else echo "⚠ 端口超出 1-65535" > "$_TTY"; fi ;;
            esac
        done
    fi

    # 用户名
    if [ -z "$USER" ]; then
        while :; do
            printf "请输入认证用户名 (直接回车默认 admin): " > "$_TTY"
            read -r _u < "$_TTY" || _u=""
            [ -z "$_u" ] && { USER="admin"; break; }
            case "$_u" in
                *[!A-Za-z0-9_.@-]*) echo "⚠ 用户名只能含字母、数字、_ . @ -" > "$_TTY" ;;
                *) USER="$_u"; break ;;
            esac
        done
    fi

    # 密码
    if [ -z "$PASS" ]; then
        while :; do
            printf "请输入认证密码 (直接回车自动生成 16 位随机密码): " > "$_TTY"
            read -r _pw < "$_TTY" || _pw=""
            [ -z "$_pw" ] && { PASS=$(gen_pass); break; }
            case "$_pw" in
                *[!A-Za-z0-9_.@#%+=-]*) echo "⚠ 密码含不支持的字符（可用：字母数字 _ . @ # % + = - ）" > "$_TTY" ;;
                *) PASS="$_pw"; break ;;
            esac
        done
    fi

    echo "" > "$_TTY"
    echo "    将使用：端口=$PORT  用户名=$USER" > "$_TTY"
}

ask_params

# ---------- 网络检测 ----------
# 取默认出站网卡
IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && IFACE=$(ip -6 route 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && IFACE=eth0

# WARP 网卡（先识别，后续 IPv4 检测须排除它，否则纯 IPv6 机上的 WARP IPv4 会被误判为原生 IPv4）
WARP_IF=""
for c in WARP warp wgcf wg0 warp0; do
    ip link show "$c" >/dev/null 2>&1 && { WARP_IF="$c"; break; }
done
WARP_V4=""
[ -n "$WARP_IF" ] && WARP_V4=$(ip -4 addr show dev "$WARP_IF" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

# 取原生 IPv4：按网卡逐个过滤，排除回环与 WARP 网卡。
# 这样多网卡/多 IPv4 也不会误判：只要没有非 WARP 网卡的全局 IPv4，就是纯 IPv6。
IPV4=""
for dev in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2}'); do
    [ "$dev" = "lo" ] && continue
    [ -n "$WARP_IF" ] && [ "$dev" = "$WARP_IF" ] && continue
    # 排除虚拟网卡：docker0 / br-* / veth* / virbr* / tun/tap / tailscale / podman / cni，
    # 否则容器环境下 Docker 网桥的 172.17.x.x 会被误判为原生 IPv4。
    case "$dev" in
        docker*|br-*|veth*|virbr*|tun*|tap*|tailscale*|podman*|cni*|flannel*|cali*|kube*) continue ;;
    esac
    addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$addr" ]; then
        IPV4="$addr"
        break
    fi
done
# 取 IPv6 地址（排除 WARP 2606:4700 段和 link-local）
IPV6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -vE '^2606:4700|^fe80' | head -1)

echo "    网卡=$IFACE  原生IPv4=${IPV4:-无}  IPv6=${IPV6:-无}  WARP=${WARP_IF:-无}(${WARP_V4:-无})"

# 判定模式：有原生 IPv4 用 v4，否则纯 v6（WARP 的 IPv4 不计入）
if [ -n "$IPV4" ]; then MODE="v4"; else MODE="v6"; fi
echo "    对网络模式: $MODE"

# ---------- 生成 dante 配置主体 ----------
# 纯 IPv6 模式下同时生成两条 socks pass 规则（→ IPv6 与 → IPv4），
# 解决旧版脚本只有单条规则导致 IPv4 目标不可达的问题。
gen_conf() {
    # $1 = 监听行, $2 = external 行(s), $3 = client to, $4 = socks to (v4), $5 = 输出路径, $6 = socks to (v6, 可选)
    {
        echo "logoutput: syslog"
        echo "$1"
        echo "$2"
        echo ""
        echo "socksmethod: username"
        echo "user.privileged: root"
        echo "user.notprivileged: nobody"
        echo ""
        echo "client pass {"
        echo "    from: $3 to: $3"
        echo "    log: error"
        echo "}"
        echo ""
        echo "socks pass {"
        echo "    from: $3 to: $4"
        echo "    command: bind connect udpassociate"
        echo "    log: error"
        echo "}"
        if [ -n "$6" ]; then
            echo ""
            echo "socks pass {"
            echo "    from: $3 to: $6"
            echo "    command: bind connect udpassociate"
            echo "    log: error"
            echo "}"
        fi
    } > "$5"
}

# ============================================================
# Alpine
# ============================================================
if command -v apk >/dev/null 2>&1; then
    echo "==> 检测到 Alpine Linux"
    apk update >/dev/null 2>&1
    apk add dante-server >/dev/null 2>&1

    if [ "$MODE" = "v4" ]; then
        CONF_INTERNAL="internal: 0.0.0.0 port = ${PORT}"
        CONF_EXTERNAL="external: ${IPV4}"
        CONF_TO="0.0.0.0/0"
        CONF_V6=""
    else
        CONF_INTERNAL="internal: :: port = ${PORT}"
        if [ -n "$WARP_V4" ]; then
            CONF_EXTERNAL="external: ${IPV6}
external: ${WARP_V4}"
        else
            CONF_EXTERNAL="external: ${IPV6}"
        fi
        CONF_TO="::/0"
        CONF_V6="::/0"
    fi
    gen_conf "$CONF_INTERNAL" "$CONF_EXTERNAL" "$CONF_TO" "0.0.0.0/0" /etc/sockd.conf "$CONF_V6"

    id "$USER" >/dev/null 2>&1 || adduser -D -H -s /sbin/nologin "$USER"
    echo "${USER}:${PASS}" | chpasswd
    rc-update add sockd default >/dev/null 2>&1 || true
    rc-service sockd restart
    sleep 2
    SERVICE="sockd"

# ============================================================
# Debian / Ubuntu
# ============================================================
elif command -v apt-get >/dev/null 2>&1; then
    echo "==> 检测到 Debian/Ubuntu"
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confold >/dev/null 2>&1 || true
    apt-get update -qq || true

    if apt-cache policy dante-server 2>/dev/null | grep -q Candidate; then
        echo "    使用 dante-server"
        apt-get install -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" dante-server

        if [ "$MODE" = "v4" ]; then
            CONF_INTERNAL="internal: 0.0.0.0 port = ${PORT}"
            CONF_EXTERNAL="external: ${IPV4}"
            CONF_TO="0.0.0.0/0"
            CONF_V6=""
        else
            CONF_INTERNAL="internal: :: port = ${PORT}"
            if [ -n "$WARP_V4" ]; then
                CONF_EXTERNAL="external: ${IPV6}
external: ${WARP_V4}"
            else
                CONF_EXTERNAL="external: ${IPV6}"
            fi
            CONF_TO="::/0"
            CONF_V6="::/0"
        fi
        gen_conf "$CONF_INTERNAL" "$CONF_EXTERNAL" "$CONF_TO" "0.0.0.0/0" /etc/danted.conf "$CONF_V6"

        id "$USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$USER"
        echo "${USER}:${PASS}" | chpasswd
        systemctl enable danted >/dev/null 2>&1 || true
        systemctl restart danted
        sleep 2
        SERVICE="danted"
    else
        echo "    源里无 dante，改用 microsocks"
        apt-get install -y microsocks
        LISTEN_IP="0.0.0.0"
        [ "$MODE" = "v6" ] && LISTEN_IP="::"
        cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=microsocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/microsocks -i ${LISTEN_IP} -p ${PORT} -u "${USER}" -P "${PASS}"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable microsocks >/dev/null 2>&1 || true
        systemctl restart microsocks
        sleep 2
        SERVICE="microsocks"
    fi
else
    echo "❌ 未识别的系统（仅支持 Alpine / Debian / Ubuntu）"
    exit 1
fi

# ---------- 验证 ----------
echo ""
echo "=== 验证结果 ==="
echo "服务:  $SERVICE"
if command -v apk >/dev/null 2>&1; then
    rc-service "$SERVICE" status 2>&1 | head -2
else
    systemctl is-active "$SERVICE" 2>/dev/null
fi
netstat -tlnp 2>/dev/null | grep ":${PORT}" || ss -tlnp 2>/dev/null | grep ":${PORT}"

# 取公网 IP（v4 优先，v6 备用）
PUBIP=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -s6 --max-time 8 https://api64.ipify.org 2>/dev/null || echo "<你的公网IP>")

# 安装过程输出较多，清屏后在顶部突出显示节点信息
command -v clear >/dev/null 2>&1 && clear 2>/dev/null || printf '\033[2J\033[H'
_UE=$(urlenc "$USER")
_PE=$(urlenc "$PASS")

echo ""
echo "================ 完成 ================"
echo "模式:   $MODE"
echo "地址:   ${PUBIP}"
echo "端口:   ${PORT}"
echo "用户名: ${USER}"
echo "密码:   ${PASS}"
if [ "$MODE" = "v6" ]; then
    echo "TG链接: tg://socks?server=[${IPV6}]&port=${PORT}&user=${_UE}&pass=${_PE}"
else
    echo "TG链接: tg://socks?server=${PUBIP}&port=${PORT}&user=${_UE}&pass=${_PE}"
fi
echo "======================================"