#!/usr/bin/env bash
# VLESS+WS+TLS 一键管理脚本
# Debian 12 专用，集成 Cloudflare/Let’s Encrypt 证书、Nginx 修复、BBR 加速

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

CONFIG_FILE="/root/vless-config.txt"
XRAY_CONF="/usr/local/etc/xray/config.json"
WWW="/var/www/html"

fix_nginx() {
  echo -e "${YELLOW}检查 Nginx...${NC}"
  if [ ! -f /etc/nginx/nginx.conf ]; then
    echo -e "${RED}未找到 /etc/nginx/nginx.conf，正在重新安装 Nginx${NC}"
    apt purge -y nginx nginx-core nginx-common nginx-full || true
    rm -rf /etc/nginx
    apt update
    apt install -y nginx
  fi
}

install_node() {
  read -p "请输入域名: " DOMAIN
  [ -z "$DOMAIN" ] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }

  read -p "请输入 WebSocket 路径 (默认 /ws): " WS_PATH
  WS_PATH=${WS_PATH:-/ws}; [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

  read -p "请输入 UUID (回车自动生成): " UUID
  [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)

  echo "选择证书方式:"
  echo " 1) Cloudflare Origin CA"
  echo " 2) Let’s Encrypt"
  read -p "请选择 (1/2 默认1): " CHOICE
  CHOICE=${CHOICE:-1}

  apt update -y
  apt install -y curl wget unzip jq ca-certificates socat python3 python3-pip nginx

  # 安装 Xray
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

  # Xray 配置
  mkdir -p "$(dirname "$XRAY_CONF")"
  cat > "$XRAY_CONF" <<EOF
{
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "level": 0 } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
  systemctl enable --now xray

  # 证书
  SSL_CERT="/etc/ssl/$DOMAIN.crt"
  SSL_KEY="/etc/ssl/$DOMAIN.key"
  if [ "$CHOICE" = "2" ]; then
    apt install -y snapd
    snap install core; snap refresh core
    snap install --classic certbot || true
    ln -sf /snap/bin/certbot /usr/bin/certbot
    apt install -y python3-certbot-nginx
    certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN"
    SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  else
    echo -e "${YELLOW}请在脚本中配置 Cloudflare API 来申请 Origin CA${NC}"
    exit 1
  fi

  # 伪装页面
  mkdir -p "$WWW"
  echo "<h1>Welcome to $DOMAIN</h1>" > "$WWW/index.html"

  # Nginx 配置
  fix_nginx
  NGX_CONF="/etc/nginx/sites-available/$DOMAIN"
  cat > "$NGX_CONF" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WWW; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WWW;
    index index.html;
    location $WS_PATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
NGX
  ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/"$DOMAIN"
  nginx -t && systemctl restart nginx

  # VLESS 链接
  WS_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH'))")
  VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_ESCAPED}#${DOMAIN}"

  cat > "$CONFIG_FILE" <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $WS_PATH
证书: $SSL_CERT
私钥: $SSL_KEY
客户端链接:
$VLESS_URI
EOF
  echo -e "${GREEN}安装完成！信息保存在 $CONFIG_FILE${NC}"
  echo "$VLESS_URI"
}

show_info() {
  [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo "未安装节点"
}

check_status() {
  systemctl status xray --no-pager
  systemctl status nginx --no-pager
}

check_cert() {
  if [ ! -f "$CONFIG_FILE" ]; then echo "未安装节点"; return; fi
  source <(grep -E "域名:|证书:" "$CONFIG_FILE" | sed 's/: /=/g')
  if [ -f "$证书" ]; then
    openssl x509 -noout -dates -in "$证书"
  else
    echo "证书不存在"
  fi
}

delete_all() {
  systemctl stop xray nginx || true
  apt purge -y xray nginx certbot || true
  rm -rf /usr/local/etc/xray /var/log/xray /etc/nginx /etc/letsencrypt /etc/ssl/*.crt /etc/ssl/*.key "$CONFIG_FILE"
  echo -e "${RED}已删除所有配置${NC}"
}

enable_bbr() {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  echo -e "${GREEN}BBR 已启用${NC}"
}

menu() {
  clear
  echo "==== VLESS 节点管理菜单 ===="
  echo "1) 安装/重新安装节点"
  echo "2) 查看节点信息"
  echo "3) 查看 Xray / Nginx 状态"
  echo "4) 查看证书状态"
  echo "5) 删除所有配置"
  echo "6) 开启 BBR 加速"
  echo "0) 退出"
  read -p "请选择 (0-6): " choice
  case "$choice" in
    1) install_node ;;
    2) show_info ;;
    3) check_status ;;
    4) check_cert ;;
    5) delete_all ;;
    6) enable_bbr ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

while true; do menu; read -p "按回车继续..." dummy; done
