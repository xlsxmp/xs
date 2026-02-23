#!/bin/sh

# ================================
#  Alpine: VLESS + WS + Argo + Sing-box
#  后台运行 + OpenRC 自启 + 节点信息写入
# ================================

set -u

SINGBOX_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="${SINGBOX_DIR}/config.json"
NODE_INFO="${SINGBOX_DIR}/node_info.json"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=3270
WS_PATH="/ws-$(date +%H%M%S)"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行"
        exit 1
    fi
}

install_base() {
    apk update || true
    apk add curl wget tar jq bash iproute2 iputils ca-certificates || true
}

# ---------------------------
# 下载 sing-box（正确文件名）
# ---------------------------
download_singbox() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        *) SB_ARCH="amd64" ;;
    esac

    VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    VER_NUM=${VER#v}

    FILE="sing-box-${VER_NUM}-linux-${SB_ARCH}.tar.gz"

    URL1="https://github.com/SagerNet/sing-box/releases/download/${VER}/${FILE}"
    URL2="https://ghproxy.net/${URL1}"

    echo "下载 sing-box：${URL1}"
    wget -qO /tmp/sb.tar.gz "$URL1" || wget -qO /tmp/sb.tar.gz "$URL2"

    if ! tar -tzf /tmp/sb.tar.gz >/dev/null 2>&1; then
        echo "❌ 下载失败：tar.gz 无效"
        exit 1
    fi
}

install_singbox() {
    mkdir -p "$SINGBOX_DIR"
    download_singbox

    tar -xf /tmp/sb.tar.gz -C /tmp
    DIR=$(find /tmp -maxdepth 1 -type d -name "sing-box-*")
    install -m 0755 "$DIR/sing-box" "$SINGBOX_BIN"
}

# ---------------------------
# 生成 sing-box 配置
# ---------------------------
generate_singbox_config() {
    mkdir -p "$SINGBOX_DIR"
    cat > "$SINGBOX_CONF" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${PORT},
      "users": [{ "uuid": "${UUID}" }],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

# ---------------------------
# OpenRC 服务（后台运行）
# ---------------------------
install_singbox_service() {
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
command="${SINGBOX_BIN}"
command_args="run -c ${SINGBOX_CONF}"
command_background="yes"
pidfile="/var/run/sing-box.pid"
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box
    rc-service sing-box restart || true
}

# ---------------------------
# 安装 cloudflared
# ---------------------------
install_cloudflared() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) CF_ARCH="amd64" ;;
        aarch64) CF_ARCH="arm64" ;;
        *) CF_ARCH="amd64" ;;
    esac

    URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    wget -qO "$CLOUDFLARED_BIN" "$URL"
    chmod +x "$CLOUDFLARED_BIN"
}

# ---------------------------
# Argo（后台运行）
# ---------------------------
setup_argo() {
    echo "请输入 Cloudflare Argo Token："
    read -r ARGO_TOKEN

    echo "请输入绑定域名（例如：argo.example.com）："
    read -r DOMAIN

    cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
command="${CLOUDFLARED_BIN}"
command_args="tunnel run --token ${ARGO_TOKEN}"
command_background="yes"
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/argo
    rc-update add argo
    rc-service argo restart || true

    mkdir -p "$SINGBOX_DIR"
    cat > "$NODE_INFO" <<EOF
{
  "uuid": "${UUID}",
  "domain": "${DOMAIN}",
  "ws_path": "${WS_PATH}",
  "port": 443,
  "vless_url": "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# ---------------------------
# 输出节点信息
# ---------------------------
show_info() {
    echo "====================================="
    echo " Sing-box + VLESS + WS + Argo 已安装"
    echo "-------------------------------------"
    jq -r '.vless_url' "$NODE_INFO"
    echo "-------------------------------------"
    echo "节点信息文件：$NODE_INFO"
    echo "Sing-box 配置：$SINGBOX_CONF"
    echo "====================================="
}

# ---------------------------
# 主流程
# ---------------------------
check_root
install_base
install_singbox
generate_singbox_config
install_singbox_service
install_cloudflared
setup_argo
show_info
