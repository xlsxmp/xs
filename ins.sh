#!/usr/bin/env bash
# install_vless_auto.sh
# Debian 12 适用：一键安装 Xray(VLESS+WS) + nginx 反代 + TLS (Let’s Encrypt 或 Cloudflare Origin CA)
# 特点：可自动通过 Cloudflare API 生成 Origin CA 证书或使用 certbot (可选 DNS 验证)
set -euo pipefail
IFS=$'\n\t'

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行脚本（sudo）${NC}" && exit 1
fi

# 检查系统为 Debian 12（宽松判断）
if ! grep -q "VERSION_ID=\"12\"" /etc/os-release; then
  echo -e "${YELLOW}警告：检测到非 Debian 12 系统，脚本在其它系统上可能不完全兼容。继续请按 Y。${NC}"
  read -p "继续？ (y/N): " ok
  case "$ok" in [yY]) ;; *) echo "退出"; exit 1 ;; esac
fi

echo -e "${YELLOW}=== VLESS+WS+TLS 一键安装（含 Cloudflare Origin CA 自动申请）===${NC}"

read -p "请输入域名（例如 vps.example.com）: " DOMAIN
if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; exit 1; fi

read -p "请输入 WebSocket 路径（默认 /ws ，不要在末尾加?或#）: " WS_PATH
WS_PATH=${WS_PATH:-/ws}
# 确保以 / 开头
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

read -p "请输入 UUID（回车自动生成）: " UUID
if [ -z "$UUID" ]; then UUID=$(cat /proc/sys/kernel/random/uuid); echo -e "${GREEN}已生成 UUID: $UUID${NC}"; fi

echo "证书方式:"
echo "  1) Cloudflare Origin CA（自动通过 Cloudflare API 生成并安装）"
echo "  2) Let’s Encrypt (certbot, http 验证)"
read -p "请选择 (1/2, 默认1): " CHOICE
CHOICE=${CHOICE:-1}

# 可选：Cloudflare API 凭证（用于自动生成 Origin CA 或自动建 DNS）
read -p "若要使用 Cloudflare API，请输入 CF API Token（推荐，回车跳过）: " CF_API_TOKEN
if [ -z "$CF_API_TOKEN" ]; then
  read -p "若无 Token，可输入 Cloudflare 邮箱 (回车跳过): " CF_EMAIL
  read -p "请输入 Cloudflare Global API Key (回车跳过): " CF_GLOBAL_KEY
fi

# 更新并安装依赖
echo -e "${YELLOW}更新系统并安装依赖...${NC}"
apt update -y
apt install -y curl wget unzip nginx jq ca-certificates socat

# 安装 certbot 与 dns 插件（按需）
if [ "$CHOICE" = "2" ]; then
  apt install -y snapd
  snap install core && snap refresh core
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi
# certbot DNS plugin for cloudflare (if user wants dns verification)
apt install -y python3-certbot-dns-cloudflare || true

# 安装 Xray（官方脚本）
echo -e "${YELLOW}安装 Xray...${NC}"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || {
  echo -e "${RED}Xray 安装失败，退出${NC}"; exit 1;
}

# 生成隐藏路径（可选：如果你希望使用自定义 WS_PATH，把下面替换为 WS_PATH）
HIDEPATH="$WS_PATH"   # 若希望随机可改成下面注释的那行
# HIDEPATH="/api/v2/$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | cut -c1-32)/"

# 写入 Xray 配置（监听 127.0.0.1:10000）
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

systemctl enable --now xray || true
sleep 1
systemctl restart xray || true

# 证书处理
SSL_CERT="/etc/ssl/$DOMAIN.crt"
SSL_KEY="/etc/ssl/$DOMAIN.key"

if [ "$CHOICE" = "1" ]; then
  # Cloudflare Origin CA 自动申请
  echo -e "${YELLOW}通过 Cloudflare API 申请 Origin CA 证书...${NC}"
  # 先获取 Zone ID (尝试完整域名 -> apex)
  if [ -n "${CF_API_TOKEN-}" ]; then
    AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
    # try to get zone by domain
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN&status=active" -H "$AUTH_HEADER" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  else
    # if user provided email+global key, find apex zone
    APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" \
      -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  fi

  # fallback: if zone id still empty, try apex from domain
  if [ -z "$ZONE_ID" ]; then
    APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    echo -e "${YELLOW}未直接找到 zone，尝试 apex: $APEX${NC}"
    if [ -n "${CF_API_TOKEN-}" ]; then
      ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "$AUTH_HEADER" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
    else
      ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
    fi
  fi

  if [ -z "$ZONE_ID" ]; then
    echo -e "${RED}无法通过 Cloudflare API 获取 Zone ID。请确认域名已添加到你的 Cloudflare 账户，或使用 Let’s Encrypt。${NC}"
    exit 1
  fi

  # Create Origin CA certificate via API (global endpoint)
  BODY=$(jq -n --arg hn "$DOMAIN" '{ "hostnames": [$hn], "request_type":"origin-rsa", "requested_validity":5475 }')
  if [ -n "${CF_API_TOKEN-}" ]; then
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$BODY")
  else
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" --data "$BODY")
  fi

  OK=$(echo "$RESP" | jq -r '.success')
  if [ "$OK" != "true" ]; then
    echo -e "${RED}Cloudflare API 返回错误：${NC}"
    echo "$RESP" | jq -C '.errors, .messages'
    exit 1
  fi

  CERT=$(echo "$RESP" | jq -r '.result.certificate')
  KEY=$(echo "$RESP" | jq -r '.result.private_key')
  if [ -z "$CERT" ] || [ -z "$KEY" ]; then
    echo -e "${RED}未取得 certificate/private_key，请检查 API 权限${NC}"
    exit 1
  fi

  mkdir -p /etc/ssl
  echo "$CERT" > "$SSL_CERT"
  echo "$KEY"  > "$SSL_KEY"
  chmod 600 "$SSL_KEY"
  echo -e "${GREEN}Cloudflare Origin CA 证书已保存：${SSL_CERT} , ${SSL_KEY}${NC}"

  # 可选：自动创建/更新 DNS A 记录 并开启 Proxy
  # 取当前公网 IP
  MYIP=$(curl -s http://ifconfig.me || curl -s https://ifconfig.co)
  if [ -n "$MYIP" ]; then
    echo -e "${YELLOW}检测到公网 IP: $MYIP 。尝试在 Cloudflare 添加 A 记录并开启代理（橙云）...${NC}"
    # check if record exists
    if [ -n "${CF_API_TOKEN-}" ]; then
      EXIST=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
    else
      EXIST=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json")
    fi
    RID=$(echo "$EXIST" | jq -r '.result[0].id // empty')
    if [ -n "$RID" ]; then
      # update
      if [ -n "${CF_API_TOKEN-}" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$MYIP\",\"ttl\":1,\"proxied\":true}" > /dev/null
      else
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$MYIP\",\"ttl\":1,\"proxied\":true}" > /dev/null
      fi
      echo -e "${GREEN}已更新 Cloudflare DNS 记录并开启代理（橙云）${NC}"
    else
      # create
      if [ -n "${CF_API_TOKEN-}" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$MYIP\",\"ttl\":1,\"proxied\":true}" > /dev/null
      else
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$MYIP\",\"ttl\":1,\"proxied\":true}" > /dev/null
      fi
      echo -e "${GREEN}已在 Cloudflare 创建 A 记录并开启代理（橙云）${NC}"
    fi
  else
    echo -e "${YELLOW}无法检测公网 IP，跳过自动建 DNS。请手动在 CF 中添加 A 记录，并开启代理（橙云）。${NC}"
  fi

else
  # Let’s Encrypt via certbot (http-01)
  echo -e "${YELLOW}使用 Let’s Encrypt 申请证书（http-01）...${NC}"
  apt install -y python3-certbot-nginx
  certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" || {
    echo -e "${RED}certbot 申请失败，请检查域名解析与 80 端口是否可达${NC}"; exit 1;
  }
  SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  echo -e "${GREEN}Let’s Encrypt 证书已申请：${SSL_CERT}${NC}"
fi

# 生成简单伪装页面
WWW="/var/www/html"
mkdir -p "$WWW"
cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;padding:40px;">
<h1>Welcome to $DOMAIN</h1><p>This is a static page.</p></body></html>
HTML
chown -R www-data:www-data "$WWW"
chmod -R 755 "$WWW"

# 写 nginx 配置
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
nginx -t
systemctl restart nginx || { echo -e "${RED}nginx 启动失败，请检查日志${NC}"; exit 1; }
echo -e "${GREEN}nginx 已配置并启动${NC}"

# 输出客户端链接（URL encode path）
ENC_PATH=$(python3 - <<PY
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
 "$HIDEPATH")
VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${ENC_PATH}#${DOMAIN}"

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
