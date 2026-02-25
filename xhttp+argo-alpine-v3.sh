#!/bin/sh
# ==============================================
# 企业级 Xray + Cloudflare Argo 安装脚本
# 支持 Alpine VPS
# ==============================================

# ==============================
# 颜色定义
# ==============================
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
RED="\033[1;31m"
NC="\033[0m"

info() { echo -e "${YELLOW}$1${NC}"; }
success() { echo -e "${GREEN}$1${NC}"; }
error() { echo -e "${RED}$1${NC}"; exit 1; }

set -e

# ==============================
# 0. 工具函数
# ==============================
retry_download() {
    URL="$1"
    OUT="$2"
    RETRY=${3:-3}
    for i in $(seq 1 $RETRY); do
        info "下载 ($i/$RETRY): $URL"
        if wget -q -O "$OUT" "$URL"; then
            success "下载成功: $OUT"
            return 0
        else
            info "下载失败，重试..."
            sleep 2
        fi
    done
    error "下载失败: $URL"
}

validate_domain() {
    DOMAIN="$1"
    if ! echo "$DOMAIN" | grep -Eiq '^([a-zA-Z0-9][-a-zA-Z0-9]{0,62}\.)+[a-zA-Z]{2,63}$'; then
        error "域名格式不正确: $DOMAIN"
    fi
}

validate_token() {
    TOKEN="$1"
    if ! echo "$TOKEN" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        error "Cloudflare Tunnel Token 格式不正确"
    fi
}

check_port() {
    PORT="$1"
    if netstat -tuln | grep -q ":$PORT "; then
        error "端口 $PORT 已被占用"
    fi
}

# ==============================
# 1. 输入信息
# ==============================
info "请输入你的 CDN 域名（必须已解析到本机并开启CF橙云）:"
read -r CDN_DOMAIN
validate_domain "$CDN_DOMAIN"

info "请输入你的 Argo 域名（Zero Trust Public Hostname）:"
read -r ARGO_DOMAIN
validate_domain "$ARGO_DOMAIN"

info "请输入你的 Cloudflare Tunnel Token (UUID 格式):"
read -r ARGO_TOKEN
validate_token "$ARGO_TOKEN"

# 生成 UUID 和路径
UUID=$(cat /proc/sys/kernel/random/uuid)
XHTTP_PATH="/$(head -c 8 /dev/urandom | md5sum | head -c 8)-xhttp"
ARGO_PATH="/$(head -c 8 /dev/urandom | md5sum | head -c 8)-argo"

success "UUID: $UUID"
success "XHTTP 路径: $XHTTP_PATH"
success "Argo 路径: $ARGO_PATH"

# ==============================
# 2. 安装依赖
# ==============================
info "安装依赖..."
apk update >/dev/null 2>&1 || error "apk update 失败"
apk add --no-cache curl wget unzip ca-certificates gcompat libc6-compat net-tools >/dev/null 2>&1 || error "依赖安装失败"
success "依赖安装完成"

# ==============================
# 3. 检测端口
# ==============================
check_port 80
check_port 8081

# ==============================
# 4. 安装 Xray-core
# ==============================
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) XRAY_ARCH="Xray-linux-64" ;;
    aarch64|arm64) XRAY_ARCH="Xray-linux-arm64" ;;
    armv7*) XRAY_ARCH="Xray-linux-arm7" ;;
    *) error "不支持的架构: $ARCH" ;;
esac

info "获取最新 Xray-core 版本..."
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f4)
[ -z "$XRAY_VER" ] && error "获取 Xray 版本失败"
success "最新版本: $XRAY_VER"

TMP_XRAY="/tmp/xray.zip"
retry_download "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ARCH}.zip" "$TMP_XRAY"

mkdir -p /usr/local/bin /usr/local/etc/xray
unzip -q "$TMP_XRAY" -d /tmp/xray_ext || error "解压失败"
[ ! -f /tmp/xray_ext/xray ] && error "xray 文件不存在"
mv /tmp/xray_ext/xray /usr/local/bin/xray || error "安装失败"
chmod +x /usr/local/bin/xray
rm -rf "$TMP_XRAY" /tmp/xray_ext
success "Xray 安装完成: $(/usr/local/bin/xray -version 2>/dev/null)"

# ==============================
# 5. 写入 Xray 配置
# ==============================
info "写入 Xray 配置..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [
    {
      "port": 80,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto",
          "host": "$CDN_DOMAIN"
        }
      }
    },
    {
      "port": 8081,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$ARGO_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
success "配置写入完成"

# ==============================
# 6. OpenRC 服务 - Xray
# ==============================
info "创建 Xray 服务..."
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF

chmod +x /etc/init.d/xray
rc-update add xray default >/dev/null 2>&1
rc-service xray restart >/dev/null 2>&1 || error "Xray 启动失败"
success "Xray 服务启动成功"

# ==============================
# 7. 安装 cloudflared
# ==============================
TMP_CF="/tmp/cloudflared"
retry_download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "$TMP_CF"
mv "$TMP_CF" /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

mkdir -p /root/.cloudflared
echo "$ARGO_TOKEN" > /root/.cloudflared/token
chmod 600 /root/.cloudflared/token
success "cloudflared 安装完成"

# ==============================
# 8. OpenRC 服务 - cloudflared
# ==============================
info "创建 cloudflared 服务..."
cat > /etc/init.d/cloudflared <<'EOF'
#!/sbin/openrc-run
description="Cloudflared Argo Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --ha-connections 1 --protocol http2 --loglevel error --edge-ip-version 4 run --token-file /root/.cloudflared/token"
command_background=true
pidfile="/run/cloudflared.pid"
depend() { need net; }
EOF

chmod +x /etc/init.d/cloudflared
rc-update add cloudflared default >/dev/null 2>&1
rc-service cloudflared restart >/dev/null 2>&1 || error "cloudflared 启动失败"
success "cloudflared 服务启动成功"

# ==============================
# 9. 输出节点信息
# ==============================
INFO_FILE="/root/xray_nodes.txt"
cat > "$INFO_FILE" <<EOF
===========================================
🎉 Alpine 企业版 Xray + Argo 部署完成！
===========================================

UUID: $UUID

-------------------------------------------
节点 1：VLESS + XHTTP + Cloudflare CDN
vless://$UUID@$CDN_DOMAIN:443?encryption=none&security=tls&type=xhttp&path=$XHTTP_PATH&mode=auto&sni=$CDN_DOMAIN#VLESS-XHTTP-CF

节点 2：VLESS + WS + Argo Tunnel
vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&path=$ARGO_PATH&sni=$ARGO_DOMAIN#VLESS-Argo
===========================================
EOF

success "部署完成，节点信息保存到: $INFO_FILE"
cat "$INFO_FILE"
