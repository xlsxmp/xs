#!/bin/bash
# ==============================================
# Debian 12 一键搭建 VLESS + XHTTP + CDN（橙云 TLS）
# 源站不启用 TLS，TLS 由 Cloudflare 负责
# ==============================================
set -euo pipefail

YELLOW="\033[1;33m"
GREEN="\033[1;32m"
RED="\033[1;31m"
NC="\033[0m"

info() { echo -e "${YELLOW}$1${NC}"; }
success() { echo -e "${GREEN}$1${NC}"; }
error() { echo -e "${RED}$1${NC}"; exit 1; }

# ====== 权限/系统检查 ======
[ "$EUID" -ne 0 ] && error "请使用 root 运行"
grep -qi "debian" /etc/os-release || error "仅支持 Debian"
grep -qi "12" /etc/os-release || error "仅支持 Debian 12"

# ====== 输入域名 ======
info "请输入你的 CDN 域名（已解析到本机并开启 Cloudflare 橙云）:"
read -r DOMAIN
[ -z "$DOMAIN" ] && error "域名不能为空"

# ====== Cloudflare 橙云检测 ======
info "检测 Cloudflare 橙云状态..."
CF_IP=$(curl -s https://cloudflare.com/cdn-cgi/trace | grep ip | cut -d= -f2 || true)
SERVER_IP=$(curl -s ipv4.icanhazip.com || true)

if [ "$CF_IP" = "$SERVER_IP" ]; then
    info "⚠ 你似乎没有通过 Cloudflare 访问（可能未开启橙云）"
else
    success "Cloudflare 橙云已生效"
fi

# ====== 检查端口占用 ======
if lsof -i:80 >/dev/null 2>&1; then
    error "端口 80 已被占用，请先关闭占用程序"
fi

# ====== 生成 UUID & 路径 ======
UUID=$(cat /proc/sys/kernel/random/uuid)
XHTTP_PATH="/$(openssl rand -hex 8)"

success "UUID: $UUID"
success "XHTTP 路径: $XHTTP_PATH"

# ====== 安装依赖 ======
info "安装依赖..."
apt update -y >/dev/null
apt install -y curl wget unzip openssl >/dev/null
success "依赖安装完成"

# ====== 安装 Xray ======
info "获取 Xray 最新版本..."
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f4)

# fallback
if [ -z "$XRAY_VER" ]; then
    info "GitHub API 受限，使用 fallback..."
    XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases | grep tag_name | head -n1 | cut -d '"' -f4)
fi

[ -z "$XRAY_VER" ] && error "获取 Xray 版本失败"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) XRAY_ARCH="Xray-linux-64" ;;
  aarch64|arm64) XRAY_ARCH="Xray-linux-arm64" ;;
  armv7*) XRAY_ARCH="Xray-linux-arm7" ;;
  *) error "不支持的架构: $ARCH" ;;
esac

info "下载 Xray-core $XRAY_VER ..."
TMP_DIR=$(mktemp -d)
wget -q -O "$TMP_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ARCH}.zip"

unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR"
install -m 755 "$TMP_DIR/xray" /usr/local/bin/xray
mkdir -p /usr/local/etc/xray
rm -rf "$TMP_DIR"

success "Xray 安装完成"

# ====== 写入 Xray 配置 ======
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
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
success "Xray 配置完成"

# ====== systemd 服务 ======
info "创建 Xray systemd 服务..."
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=nobody
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray >/dev/null
systemctl restart xray || error "Xray 启动失败"

success "Xray 服务启动成功"

# ====== 输出节点信息 ======
INFO_FILE="/root/vless_xhttp_info.txt"
cat > "$INFO_FILE" <<EOF
===========================================
🎉 Debian 12 VLESS+XHTTP+CDN 部署完成
===========================================
UUID: $UUID
XHTTP 路径: $XHTTP_PATH
域名: $DOMAIN

VLESS 链接:
vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=xhttp&path=$XHTTP_PATH&mode=auto&fp=randomized&alpn=h2&sni=$DOMAIN#VLESS-XHTTP-CDN

说明:
- 源站不启用 TLS
- Cloudflare 负责 TLS (橙云)
===========================================
EOF

success "部署完成，信息保存到: $INFO_FILE"
cat "$INFO_FILE"
