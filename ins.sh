#!/usr/bin/env bash
# install_vless_auto.sh
# Debian 12 适用：一键安装 Xray(VLESS+WS) + nginx 反代 + TLS (Let’s Encrypt 或 Cloudflare Origin CA)
set -euo pipefail
IFS=$'\n\t'

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行脚本（sudo）${NC}" && exit 1
fi

# 检查系统为 Debian（宽松检查，支持 Debian 10-12）
if ! grep -qE "Debian GNU/Linux [1][0-2]" /etc/os-release; then
  echo -e "${YELLOW}警告：非 Debian 10-12 系统，可能不完全兼容。继续请按 Y。${NC}"
  read -p "继续？ (y/N): " ok
  case "$ok" in [yY]) ;; *) echo "退出"; exit 1 ;; esac
fi

echo -e "${YELLOW}=== VLESS+WS+TLS 一键安装（含 Cloudflare Origin CA 自动申请）===${NC}"

# 用户输入
read -p "请输入域名（例如 vps.example.com）: " DOMAIN
if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; exit 1; fi

read -p "请输入 WebSocket 路径（默认 /ws ）: " WS_PATH
WS_PATH=${WS_PATH:-/ws}
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

read -p "请输入 UUID（回车自动生成）: " UUID
if [ -z "$UUID" ]; then UUID=$(cat /proc/sys/kernel/random/uuid); echo -e "${GREEN}已生成 UUID: $UUID${NC}"; fi

echo "证书方式:"
echo "  1) Cloudflare Origin CA（自动通过 Cloudflare API 生成并安装）"
echo "  2) Let’s Encrypt (certbot, http 验证)"
read -p "请选择 (1/2, 默认1): " CHOICE
CHOICE=${CHOICE:-1}

read -p "若要使用 Cloudflare API，请输入 CF API Token（回车跳过）: " CF_API_TOKEN
if [ -z "$CF_API_TOKEN" ]; then
  read -p "若无 Token，可输入 Cloudflare 邮箱 (回车跳过) : " CF_EMAIL
  read -p "请输入 Cloudflare Global API Key (回车跳过) : " CF_GLOBAL_KEY
fi

# 更新安装依赖
echo -e "${YELLOW}更新系统并安装依赖...${NC}"
apt update -y
apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip

# 安装 certbot 与 nginx 插件（仅在选择 Let’s Encrypt 时）
if [ "$CHOICE" = "2" ]; then
  apt install -y snapd
  snap install core && snap refresh core
  snap install --classic certbot || { echo -e "${RED}certbot 安装失败${NC}"; exit 1; }
  ln -sf /snap/bin/certbot /usr/bin/certbot
  apt install -y python3-certbot-nginx || { echo -e "${RED}python3-certbot-nginx 安装失败${NC}"; exit 1; }
fi

# 安装 Xray
echo -e "${YELLOW}安装 Xray...${NC}"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || {
  echo -e "${RED}Xray 安装失败${NC}"; exit 1;
}

# 检查端口 10000 是否被占用
if ss -tuln | grep -q ":10000"; then
  echo -e "${RED}端口 10000 已被占用，请释放该端口或修改脚本${NC}"
  exit 1
fi

# HIDEPATH 设置
HIDEPATH="$WS_PATH"

# 写入 Xray 配置
XRAY_CONF="/usr/local/etc/xray/config.json"
mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "level": 0 } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$HIDEPATH" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

systemctl enable xray
systemctl restart xray || { echo -e "${RED}Xray 启动失败${NC}"; exit 1; }

# 证书路径
SSL_CERT="/etc/ssl/$DOMAIN.crt"
SSL_KEY="/etc/ssl/$DOMAIN.key"

# 创建 nginx 配置（在 Let’s Encrypt 前，确保 server_name 存在）
NGX_CONF="/etc/nginx/sites-available/$DOMAIN"
if [ -f "$NGX_CONF" ]; then
  echo -e "${YELLOW}警告：$DOMAIN 的 nginx 配置已存在，将被覆盖。${NC}"
  read -p "继续？ (y/N): " ok
  case "$ok" in [yY]) ;; *) echo "退出"; exit 1 ;; esac
fi

# 确保 /etc/ssl 目录安全
mkdir -p /etc/ssl
chmod 700 /etc/ssl

# 为 Let’s Encrypt 创建临时的 HTTP server block
if [ "$CHOICE" = "2" ]; then
  cat > "$NGX_CONF" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/html;
    location /.well-known/acme-challenge/ { }
    location / { return 301 https://\$host\$request_uri; }
}
NGX
  ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/"$DOMAIN"
  nginx -t || { echo -e "${RED}nginx 配置测试失败${NC}"; exit 1; }
  systemctl restart nginx || { echo -e "${RED}nginx 启动失败${NC}"; exit 1; }
fi

# 证书申请
if [ "$CHOICE" = "1" ]; then
  echo -e "${YELLOW}通过 Cloudflare API 申请 Origin CA 证书...${NC}"
  if [ -n "${CF_API_TOKEN-}" ]; then
    AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN&status=active" -H "$AUTH_HEADER" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  else
    APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  fi
  if [ -z "$ZONE_ID" ]; then
    echo -e "${RED}无法获取 Cloudflare ZONE_ID，请检查域名或 API 凭据${NC}"
    exit 1
  fi
  BODY=$(jq -n --arg hn "$DOMAIN" '{ "hostnames": [$hn], "request_type":"origin-rsa", "requested_validity":5475 }' || {
    echo -e "${RED}jq 命令生成 JSON 失败，请检查 jq 安装或语法${NC}"
    exit 1
  })
  if [ -n "${CF_API_TOKEN-}" ]; then
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "$AUTH_HEADER" -H "Content-Type: application/json" --data "$BODY")
  else
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" --data "$BODY")
  fi
  CERT=$(echo "$RESP" | jq -r '.result.certificate')
  KEY=$(echo "$RESP" | jq -r '.result.private_key')
  if [ -z "$CERT" ] || [ -z "$KEY" ]; then
    echo -e "${RED}Cloudflare 证书申请失败，请检查 API 凭据或网络${NC}"
    exit 1
  fi
  echo "$CERT" > "$SSL_CERT"
  echo "$KEY" > "$SSL_KEY"
  chmod 600 "$SSL_KEY"
else
  echo -e "${YELLOW}使用 Let’s Encrypt 申请证书...${NC}"
  certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" || {
    echo -e "${RED}Let’s Encrypt 证书申请失败，请检查日志 /var/log/letsencrypt/letsencrypt.log${NC}"
    exit 1
  }
  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    echo -e "${RED}Let’s Encrypt 证书文件未找到${NC}"
    exit 1
  }
fi

# 生成伪装页面
WWW="/var/www/html"
mkdir -p "$WWW"
cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;padding:40px;">
<h1>Welcome to $DOMAIN</h1><p>This is a static page.</p></body></html>
HTML
chown -R www-data:www-data "$WWW"
chmod -R 755 "$WWW"

# 写入最终 nginx 配置
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
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    server_tokens off;

    root $WWW;
    index index.html;

    location $HIDEPATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
    }

    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
NGX

ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/"$DOMAIN"
nginx -t || { echo -e "${RED}nginx 配置测试失败${NC}"; exit 1; }
systemctl restart nginx || { echo -e "${RED}nginx 启动失败${NC}"; exit 1; }

# URL encode HIDEPATH
HIDEPATH_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$HIDEPATH', safe=''))" || {
  echo -e "${RED}URL 编码失败，请检查 Python3 安装${NC}"
  exit 1
})
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}#${DOMAIN}"

cat > /root/vless-config.txt <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $HIDEPATH
证书: $SSL_CERT
私钥: $SSL_KEY

客户端链接:
$VLESS_URI

重要提示：请将此文件 (/root/vless-config.txt) 安全保存并在配置客户端后删除。
推荐客户端：v2rayN (Windows), v2rayNG (Android), Nekoray (跨平台)
EOF

echo -e "${GREEN}安装完成！配置信息已保存到 /root/vless-config.txt${NC}"
echo "---- 客户端链接 ----"
echo "$VLESS_URI"
echo "---- 结束 ----"
echo -e "${YELLOW}提示：请将 /root/vless-config.txt 安全保存并在配置客户端后删除。${NC}"
