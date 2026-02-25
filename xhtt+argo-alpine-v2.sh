#!/bin/sh

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
# 1. 输入信息
# ==============================
info "请输入你的 CDN 域名（必须已解析到本机并开启CF橙云）:"
read -r CDN_DOMAIN

info "请输入你的 Argo 域名（Zero Trust Public Hostname）:"
read -r ARGO_DOMAIN

info "请输入你的 Cloudflare Tunnel Token:"
read -r ARGO_TOKEN

[ -z "$CDN_DOMAIN" ] && error "CDN_DOMAIN 不能为空"
[ -z "$ARGO_DOMAIN" ] && error "ARGO_DOMAIN 不能为空"
[ -z "$ARGO_TOKEN" ] && error "ARGO_TOKEN 不能为空"

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
apk add --no-cache curl wget unzip ca-certificates gcompat libc6-compat >/dev/null 2>&1 || error "依赖安装失败"
success "依赖安装完成"

# ==============================
# 3. 安装 Xray
# ==============================
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) XRAY_ARCH="Xray-linux-64" ;;
  aarch64 | arm64) XRAY_ARCH="Xray-linux-arm64" ;;
  *) error "不支持的架构: $ARCH" ;;
esac

info "获取最新 Xray 版本..."
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f4)
[ -z "$XRAY_VER" ] && error "获取 Xray 版本失败"
success "最新版本: $XRAY_VER"

URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ARCH}.zip"

info "下载 Xray..."
wget -q -O /tmp/xray.zip "$URL" || error "Xray 下载失败"

mkdir -p /usr/local/bin /usr/local/etc/xray
unzip -q /tmp/xray.zip -d /tmp/xray_ext || error "解压失败"

[ ! -f /tmp/xray_ext/xray ] && error "xray 文件不存在"

mv /tmp/xray_ext/xray /usr/local/bin/xray || error "安装失败"
chmod +x /usr/local/bin/xray
rm -rf /tmp/xray.zip /tmp/xray_ext

/usr/local/bin/xray -version >/dev/null 2>&1 || error "Xray 安装校验失败"
success "Xray 安装完成"

# ==============================
# 4. 写入配置
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
# 5. OpenRC - Xray
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
# 6. 安装 cloudflared
# ==============================
info "安装 cloudflared..."
wget -q -O /usr/local/bin/cloudflared \
https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
|| error "cloudflared 下载失败"

chmod +x /usr/local/bin/cloudflared

mkdir -p /root/.cloudflared
echo "$ARGO_TOKEN" > /root/.cloudflared/token
chmod 600 /root/.cloudflared/token
success "cloudflared 安装完成"

# ==============================
# 7. OpenRC - cloudflared
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
success "cloudflared 启动成功"

# ==============================
# 8. 输出节点
# ==============================
INFO_FILE="/root/xray_nodes.txt"

cat > "$INFO_FILE" <<EOF
部署完成

UUID: $UUID

VLESS-XHTTP:
vless://$UUID@$CDN_DOMAIN:443?encryption=none&security=tls&type=xhttp&path=$XHTTP_PATH&mode=auto&sni=$CDN_DOMAIN

VLESS-Argo:
vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&path=$ARGO_PATH&sni=$ARGO_DOMAIN
EOF

success "部署完成"
info "节点信息已保存: $INFO_FILE"
cat "$INFO_FILE"
