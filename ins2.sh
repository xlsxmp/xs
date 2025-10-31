#!/usr/bin/env bash
# install_vless_auto_v2.sh
# Debian 12 优化版：一键安装 Xray (VLESS+WS) + nginx 反代 + TLS
# 特性：
#  - 更稳健的 Cloudflare Zone 处理
#  - Let’s Encrypt 验证顺序与 standalone 兼容
#  - 可选 Xray 日志等级、自定义端口
#  - 防止覆盖已有配置的交互
#  - 统一证书目录 /etc/xray/ssl/<domain>
#  - 添加自动续期 (crontab)
#  - 简单的探测防护（非 websocket 请求返回 404）
#  - 启动检查与友好错误提示

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行脚本（sudo）${NC}" && exit 1
fi

# 预设
XRAY_PORT=10000
XRAY_LISTEN="127.0.0.1"
NGINX_ROOT="/var/www/html"
DEFAULT_WSPATH="/ws"
SSL_BASE_DIR="/etc/xray/ssl"

# 检查系统 (宽松判断)
if ! grep -q "VERSION_ID=\"12\"" /etc/os-release; then
  echo -e "${YELLOW}警告：检测到非 Debian 12 系统，脚本在其它系统上可能不完全兼容。继续请按 Y。${NC}"
  read -r -p "继续？ (y/N): " ok
  case "$ok" in [yY]) ;; *) echo "退出"; exit 1 ;; esac
fi

echo -e "${YELLOW}=== VLESS+WS+TLS 一键安装 v2 ===${NC}"

read -r -p "请输入域名（例如 vps.example.com）: " DOMAIN
if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空${NC}"; exit 1; fi

read -r -p "请输入 WebSocket 路径（默认 ${DEFAULT_WSPATH}）: " WS_PATH
WS_PATH=${WS_PATH:-$DEFAULT_WSPATH}
if [[ "${WS_PATH:0:1}" != "/" ]]; then WS_PATH="/$WS_PATH"; fi

read -r -p "请输入 UUID（回车自动生成）: " UUID
if [ -z "$UUID" ]; then UUID=$(cat /proc/sys/kernel/random/uuid); echo -e "${GREEN}已生成 UUID: $UUID${NC}"; fi

read -r -p "请输入 Xray 日志等级 (none/error/warning/info/debug, 默认 warning): " LOGLEVEL
LOGLEVEL=${LOGLEVEL:-warning}

read -r -p "请输入 Xray 监听端口（本地，默认 ${XRAY_PORT}）: " XRAY_PORT_INPUT
XRAY_PORT=${XRAY_PORT_INPUT:-$XRAY_PORT}

echo "证书方式:"
echo "  1) Cloudflare Origin CA（推荐：通过 API 生成）"
echo "  2) Let’s Encrypt (certbot, standalone/http)"
read -r -p "请选择 (1/2, 默认1): " CHOICE
CHOICE=${CHOICE:-1}

CF_API_TOKEN=''
CF_EMAIL=''
CF_GLOBAL_KEY=''
if [ "$CHOICE" = "1" ]; then
  read -r -p "若要使用 Cloudflare API，请输入 CF API Token（回车跳过）: " CF_API_TOKEN
  if [ -z "$CF_API_TOKEN" ]; then
    read -r -p "若无 Token，可输入 Cloudflare 邮箱 (回车跳过) : " CF_EMAIL
    read -r -p "请输入 Cloudflare Global API Key (回车跳过) : " CF_GLOBAL_KEY
  fi
fi

# 防止覆盖
XRAY_CONF="/usr/local/etc/xray/config.json"
if [ -f "$XRAY_CONF" ]; then
  echo -e "${YELLOW}检测到已存在 Xray 配置文件: $XRAY_CONF${NC}"
  read -r -p "是否覆盖已有配置并继续？(y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

# 更新并安装依赖
echo -e "${YELLOW}更新系统并安装依赖...${NC}"
apt update -y
apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip pwgen

# certbot & plugins（按需）
if [ "$CHOICE" = "2" ]; then
  apt install -y snapd
  snap install core || true
  snap refresh core || true
  snap install --classic certbot || true
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi
apt install -y python3-certbot-dns-cloudflare || true

# 安装 Xray（若已有安装则跳过）
if ! command -v xray >/dev/null 2>&1; then
  echo -e "${YELLOW}安装 Xray...${NC}"
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || { echo -e "${RED}Xray 安装失败${NC}"; exit 1; }
else
  echo -e "${GREEN}检测到已安装 Xray，跳过安装${NC}"
fi

# 创建 ssl 目录
SSL_DIR="$SSL_BASE_DIR/$DOMAIN"
mkdir -p "$SSL_DIR"

# 证书申请
SSL_CERT="$SSL_DIR/fullchain.pem"
SSL_KEY="$SSL_DIR/privkey.pem"

if [ "$CHOICE" = "1" ]; then
  echo -e "${YELLOW}通过 Cloudflare API 申请 Origin CA 证书...${NC}"

  if [ -n "$CF_API_TOKEN" ]; then
    AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
    # 尝试获取 zone 使用 apex（二级域）作为后备
    APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "$AUTH_HEADER" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  else
    # 使用邮箱+global key
    APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
  fi

  if [ -z "$ZONE_ID" ]; then
    echo -e "${RED}无法获取 Zone ID，请检查域名与 Cloudflare 账号权限。若不使用 Cloudflare，请选择 Let\'s Encrypt。${NC}"
    exit 1
  fi

  BODY=$(jq -n --arg hn "$DOMAIN" '{ "hostnames": [$hn], "request_type":"origin-rsa", "requested_validity":5475 }')
  if [ -n "$CF_API_TOKEN" ]; then
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "$AUTH_HEADER" -H "Content-Type: application/json" --data "$BODY")
  else
    RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" -H "Content-Type: application/json" --data "$BODY")
  fi

  CERT=$(echo "$RESP" | jq -r '.result.certificate // empty')
  KEY=$(echo "$RESP" | jq -r '.result.private_key // empty')
  if [ -z "$CERT" ] || [ -z "$KEY" ]; then
    echo -e "${RED}Cloudflare 证书申请失败，响应:$(echo "$RESP" | jq -c '.')${NC}"
    exit 1
  fi

  echo "$CERT" > "$SSL_CERT"
  echo "$KEY" > "$SSL_KEY"
  chmod 600 "$SSL_KEY"
  echo -e "${GREEN}已保存 Cloudflare Origin CA 证书到 $SSL_DIR${NC}"
else
  echo -e "${YELLOW}使用 Let\'s Encrypt 申请证书（standalone 模式）...${NC}"
  # 停止 nginx 以确保 certbot standalone 可以绑定 80
  systemctl stop nginx || true
  certbot certonly --standalone -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" --non-interactive || {
    echo -e "${RED}Certbot 申请失败，尝试 --nginx 模式...${NC}"
    systemctl start nginx || true
    certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" || { echo -e "${RED}Certbot (nginx) 也失败，退出${NC}"; exit 1; }
  }
  # 恢复 nginx（如果之前停止）
  systemctl start nginx || true
  LE_DIR="/etc/letsencrypt/live/$DOMAIN"
  if [ ! -d "$LE_DIR" ]; then
    echo -e "${RED}未找到 Let\'s Encrypt 输出目录: $LE_DIR${NC}"; exit 1
  fi
  cp "$LE_DIR/fullchain.pem" "$SSL_CERT"
  cp "$LE_DIR/privkey.pem" "$SSL_KEY"
  chmod 600 "$SSL_KEY"
  echo -e "${GREEN}已将 Let\'s Encrypt 证书复制到 $SSL_DIR${NC}"
fi

# 生成伪装页面（覆盖或创建）
mkdir -p "$NGINX_ROOT"
cat > "$NGINX_ROOT/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;padding:40px;">
<h1>Welcome to $DOMAIN</h1><p>This is a static page.</p></body></html>
HTML
chown -R www-data:www-data "$NGINX_ROOT"
chmod -R 755 "$NGINX_ROOT"

# 写入 Xray 配置
mkdir -p "$(dirname "$XRAY_CONF")"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "$LOGLEVEL" },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "listen": "$XRAY_LISTEN",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "level": 0 } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# 启用并重启 xray
systemctl enable --now xray || true
systemctl restart xray || true

# 检查 xray 状态
if ! systemctl is-active --quiet xray; then
  echo -e "${RED}Xray 启动失败，请检查 /var/log/xray/error.log${NC}"
  exit 1
fi

# Nginx 配置
NGX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat > "$NGX_CONF" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $NGINX_ROOT; }
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

    root $NGINX_ROOT;
    index index.html;

    # 只允许 websocket 升级请求访问 hidepath，其他返回 404
    location = $WS_PATH {
        if (
            \$http_upgrade != "websocket"
        ) {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://$XRAY_LISTEN:$XRAY_PORT;
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

# 测试 nginx 并重启
nginx -t || { echo -e "${RED}nginx 配置测试失败，请检查 /var/log/nginx/error.log${NC}"; exit 1; }
systemctl restart nginx || { echo -e "${RED}nginx 启动失败${NC}"; exit 1; }

# 创建自动续期任务（只在使用 Let's Encrypt 时需要）
if [ "$CHOICE" = "2" ]; then
  (crontab -l 2>/dev/null || true; echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx") | crontab -
  echo -e "${GREEN}已安装 certbot 自动续期定时任务（每日 03:00 尝试）${NC}"
fi

# URL encode path
WS_PATH_ESCAPED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$WS_PATH")
VLESS_URI_PLAIN="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH_ESCAPED}#${DOMAIN}"

# 保存到文件
CFG_OUT="/root/vless-config-v2.txt"
cat > "$CFG_OUT" <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $WS_PATH
证书目录: $SSL_DIR
Xray 监听: $XRAY_LISTEN:$XRAY_PORT

客户端链接:
$VLESS_URI_PLAIN

Xray 配置文件: $XRAY_CONF
Nginx 配置文件: $NGX_CONF
EOF

chmod 600 "$CFG_OUT"

echo -e "${GREEN}安装完成！配置信息已保存到 $CFG_OUT${NC}"
echo "---- 客户端链接 ----"
echo "$VLESS_URI_PLAIN"
echo "---- 结束 ----"

# 额外提示
cat <<MSG

常见下一步建议：
  - 若使用 Cloudflare，请在 Cloudflare DNS 面板将该域名的代理 (orange cloud) 设为 Proxied（根据需要）
  - 若希望更严格的防探测，可将 websocket 路径设置为更复杂的随机字符串
  - 若你希望我把脚本改为支持 XHTTP 或 Argo，请直接告诉我
MSG
