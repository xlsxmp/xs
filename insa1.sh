#!/usr/bin/env bash
# install_vless_auto.sh
# Debian 12 适用：一键安装 Xray (VLESS+WS) + Nginx 反代 + TLS（Cloudflare Origin CA 或 Let’s Encrypt）
# 修正版：修正 Cloudflare Origin CA API、增强健壮性与日志目录、改进 URI 参数
set -euo pipefail
IFS=$'\n\t'

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行脚本（sudo）${NC}" && exit 1
fi

# 检查系统为 Debian 12（宽松判断）
if ! grep -q 'VERSION_ID="12"' /etc/os-release; then
  echo -e "${YELLOW}警告：检测到非 Debian 12 系统，脚本在其它系统上可能不完全兼容。继续请按 Y。${NC}"
  read -p "继续？ (y/N): " ok
  case "$ok" in [yY]) ;; *) echo "退出"; exit 1 ;; esac
fi

echo -e "${YELLOW}=== VLESS+WS+TLS 一键安装（含 Cloudflare Origin CA 自动申请）===${NC}"

# 输入
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

CF_API_TOKEN=""
CF_EMAIL=""
CF_GLOBAL_KEY=""

if [ "$CHOICE" = "1" ]; then
  read -p "若要使用 Cloudflare API，请输入 CF API Token（推荐，权限需有 Origin CA）: " CF_API_TOKEN || true
  if [ -z "$CF_API_TOKEN" ]; then
    read -p "若无 Token，可输入 Cloudflare 邮箱: " CF_EMAIL || true
    read -p "请输入 Cloudflare Global API Key: " CF_GLOBAL_KEY || true
    if [ -z "$CF_EMAIL" ] || [ -z "$CF_GLOBAL_KEY" ]; then
      echo -e "${RED}未提供有效的 Cloudflare 凭证，无法申请证书${NC}"
      exit 1
    fi
  fi
fi

# 更新安装依赖
echo -e "${YELLOW}更新系统并安装依赖...${NC}"
apt update -y || { echo -e "${RED}apt 更新失败${NC}"; exit 1; }
apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip || { echo -e "${RED}依赖安装失败${NC}"; exit 1; }

# 启用并启动 nginx
systemctl enable --now nginx || { echo -e "${RED}nginx 启动失败${NC}"; exit 1; }

# 安装 certbot（仅在选择 2 时）
if [ "$CHOICE" = "2" ]; then
  apt install -y snapd || { echo -e "${RED}snapd 安装失败${NC}"; exit 1; }
  snap install core && snap refresh core || { echo -e "${RED}snap core 安装/更新失败${NC}"; exit 1; }
  snap install --classic certbot || { echo -e "${RED}certbot 安装失败${NC}"; exit 1; }
  ln -sf /snap/bin/certbot /usr/bin/certbot
  apt install -y python3-certbot-nginx || true
fi

# 安装 Xray
echo -e "${YELLOW}安装 Xray...${NC}"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || {
  echo -e "${RED}Xray 安装失败${NC}"; exit 1;
}

# 日志目录
mkdir -p /var/log/xray
chown nobody:nogroup /var/log/xray || true

# HIDEPATH 设置
HIDEPATH="$WS_PATH"

# 写入 Xray 配置
XRAY_CONF="/usr/local/etc/xray/config.json"
mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$HIDEPATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

systemctl enable --now xray || { echo -e "${RED}Xray 启动失败${NC}"; exit 1; }
systemctl restart xray || { echo -e "${RED}Xray 重启失败${NC}"; journalctl -u xray --no-pager -n 50; exit 1; }

# 证书路径初始化
SSL_CERT="/etc/ssl/$DOMAIN.crt"
SSL_KEY="/etc/ssl/$DOMAIN.key"

# 证书申请
if [ "$CHOICE" = "1" ]; then
  echo -e "${YELLOW}通过 Cloudflare API 申请 Origin CA 证书...${NC}"
  # 组装认证头
  AUTH_HEADER=""
  if [ -n "$CF_API_TOKEN" ]; then
    AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
  else
    AUTH_HEADER="X-Auth-Email: $CF_EMAIL"
    AUTH_HEADER2="X-Auth-Key: $CF_GLOBAL_KEY"
  fi

  BODY=$(jq -n --arg hn "$DOMAIN" '{ "hostnames": [$hn], "request_type":"origin-rsa", "requested_validity":5475 }')

  if [ -n "$CF_API_TOKEN" ]; then
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" \
      -H "$AUTH_HEADER" -H "Content-Type: application/json" --data "$BODY")
  else
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" \
      -H "$AUTH_HEADER" -H "$AUTH_HEADER2" -H "Content-Type: application/json" --data "$BODY")
  fi

  SUCCESS=$(echo "$RESP" | jq -r '.success')
  if [ "$SUCCESS" != "true" ]; then
    echo -e "${RED}Cloudflare Origin CA 证书申请失败！返回信息:${NC}"
    echo "$RESP"
    exit 1
  fi

  CERT=$(echo "$RESP" | jq -r '.result.certificate')
  KEY=$(echo "$RESP" | jq -r '.result.private_key')

  if [ -z "$CERT" ] || [ -z "$KEY" ] || [ "$CERT" = "null" ] || [ "$KEY" = "null" ]; then
    echo -e "${RED}Cloudflare API 未返回证书内容，请检查 API 权限（需 Origin CA）${NC}"
    exit 1
  fi

  echo "$CERT" > "$SSL_CERT"
  echo "$KEY" > "$SSL_KEY"
  chmod 600 "$SSL_KEY"

else
  echo -e "${YELLOW}使用 Let’s Encrypt 申请证书（HTTP 验证）...${NC}"
  # 基础站点用于 HTTP 验证
  WWW="/var/www/html"
  mkdir -p "$WWW"
  cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;padding:40px;">
<h1>Welcome to $DOMAIN</h1><p>This is a static page.</p></body></html>
HTML
  chown -R www-data:www-data "$WWW"
  chmod -R 755 "$WWW"

  # 先部署一个临时 HTTP server_name 站点以完成验证
  NGX_TMP="/etc/nginx/sites-available/${DOMAIN}_http_temp"
  cat > "$NGX_TMP" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    root $WWW;
    location /.well-known/acme-challenge/ { root $WWW; }
    location / { try_files \$uri \$uri/ =404; }
}
NGX
  ln -sf "$NGX_TMP" "/etc/nginx/sites-enabled/${DOMAIN}_http_temp"
  nginx -t || { echo -e "${RED}nginx 配置测试失败（临时站点）${NC}"; exit 1; }
  systemctl reload nginx || { echo -e "${RED}nginx reload 失败${NC}"; exit 1; }

  # 使用 nginx 插件申请证书
  certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" || { echo -e "${RED}Let’s Encrypt 申请失败${NC}"; exit 1; }
  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

  if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    echo -e "${RED}证书文件不存在：$SSL_CERT 或 $SSL_KEY${NC}"; exit 1
  fi
fi

# 生成伪装页面（增强随机性）
WWW="/var/www/html"
mkdir -p "$WWW"
RANDOM_TITLE=$(tr -dc 'a-z' </dev/urandom | head -c 8)
cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$RANDOM_TITLE</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; padding: 40px; color: #222; }
a { color: #06c; text-decoration: none; }
</style></head>
<body>
<h1>$RANDOM_TITLE</h1>
<p>This is a static page.</p>
<p><a href="/">Home</a></p>
</body></html>
HTML
chown -R www-data:www-data "$WWW"
chmod -R 755 "$WWW"

# Nginx 配置（HTTPS + 反代 WS）
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
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    server_tokens off;

    root $WWW;
    index index.html;

    # WebSocket 反代到 Xray
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

    # 其余静态资源
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
NGX

# 使能最终站点，移除临时站点（如存在）
ln -sf "$NGX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
if [ -f "/etc/nginx/sites-enabled/${DOMAIN}_http_temp" ]; then
  rm -f "/etc/nginx/sites-enabled/${DOMAIN}_http_temp"
  rm -f "/etc/nginx/sites-available/${DOMAIN}_http_temp"
fi

nginx -t || { echo -e "${RED}nginx 配置测试失败（最终站点）${NC}"; exit 1; }
systemctl reload nginx || { echo -e "${RED}nginx reload 失败${NC}"; exit 1; }

# URL encode HIDEPATH
HIDEPATH_ESCAPED=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${HIDEPATH}", safe=''))
PY
)

# 生成客户端链接（增加 fp=randomized）
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}&fp=randomized#${DOMAIN}"

# 输出配置文件
cat > /root/vless-config.txt <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $HIDEPATH
证书: $SSL_CERT
私钥: $SSL_KEY

客户端链接:
$VLESS_URI
EOF

echo -e "${GREEN}安装完成！配置信息已保存到 /root/vless-config.txt${NC}"
echo "---- 客户端链接 ----"
echo "$VLESS_URI"
echo "---- 结束 ----"
```
