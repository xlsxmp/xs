#!/bin/bash

# Debian 12 一键安装 VLESS + WebSocket + TLS + Nginx + Cloudflare CDN
# 证书通过 acme.sh + Cloudflare DNS-01 模式自动申请/续期
# 交互式脚本，会提示你输入必要信息
# 作者：Grok（专业修订版）

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== VLESS-WS-TLS + Nginx + Cloudflare 一键脚本（专业版） ===${NC}"
echo -e "${YELLOW}适用于 Debian 12，证书使用 Cloudflare DNS-01 验证${NC}"
echo

# 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请用 root 权限运行此脚本 (sudo bash $0)${NC}"
   exit 1
fi

# 检查系统版本
if ! grep -qi "debian" /etc/os-release || ! grep -q "VERSION_ID=\"12\"" /etc/os-release; then
    echo -e "${YELLOW}警告：此脚本针对 Debian 12 设计，当前系统可能不是 Debian 12。继续可能会出问题。${NC}"
    read -p "仍然继续？(y/N): " CONT
    if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        exit 1
    fi
fi

# 交互式输入
read -p "请输入你的域名（例如 vless.example.com）: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}域名不能为空！${NC}"
    exit 1
fi

echo
echo -e "${YELLOW}Cloudflare API 认证方式：${NC}"
echo "1) 使用 API Token（推荐，仅授予 DNS 编辑权限）"
echo "2) 使用 Global API Key（不推荐，权限过大）"
read -p "请选择 [1/2，默认 1]: " CF_MODE
CF_MODE=${CF_MODE:-1}

CF_EMAIL=""
CF_TOKEN=""
CF_KEY=""

if [[ "$CF_MODE" == "1" ]]; then
    read -p "请输入 Cloudflare 账户邮箱（仅用于标记，可留空）: " CF_EMAIL
    read -p "请输入 Cloudflare API Token（仅 DNS 权限）: " CF_TOKEN
    if [[ -z "$CF_TOKEN" ]]; then
        echo -e "${RED}API Token 不能为空！${NC}"
        exit 1
    fi
elif [[ "$CF_MODE" == "2" ]]; then
    read -p "请输入 Cloudflare 账户邮箱（用于 API 认证）: " CF_EMAIL
    read -p "请输入 Cloudflare Global API Key: " CF_KEY
    if [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
        echo -e "${RED}Cloudflare 邮箱和 Global API Key 不能为空！${NC}"
        exit 1
    fi
else
    echo -e "${RED}无效选择${NC}"
    exit 1
fi

read -p "请输入 WebSocket 路径（建议随机，例如 /ray2026 ，必须以 / 开头）[默认 /vlessws]: " WS_PATH
WS_PATH=${WS_PATH:-/vlessws}
if [[ "${WS_PATH:0:1}" != "/" ]]; then
    echo -e "${RED}WS 路径必须以 / 开头，例如 /ray2026${NC}"
    exit 1
fi

read -p "请输入 Xray 监听端口（本地端口，建议 10000-20000 随机）[默认 10000]: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-10000}
if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || (( XRAY_PORT < 1 || XRAY_PORT > 65535 )); then
    echo -e "${RED}端口必须是 1-65535 之间的数字${NC}"
    exit 1
fi

# 生成 UUID
if command -v uuidgen >/dev/null 2>&1; then
    UUID=$(uuidgen)
else
    UUID=$(cat /proc/sys/kernel/random/uuid)
fi

echo
echo -e "${GREEN}配置信息确认：${NC}"
echo "域名:        $DOMAIN"
echo "WS 路径:     $WS_PATH"
echo "Xray 端口:   $XRAY_PORT"
echo "UUID:        $UUID"
echo "CF 模式:     $([[ "$CF_MODE" == "1" ]] && echo 'API Token' || echo 'Global API Key')"
echo
read -p "确认无误？(y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消安装"
    exit 0
fi

# 更新系统并安装必要软件
echo -e "${GREEN}正在更新系统并安装依赖...${NC}"
apt update && apt upgrade -y
apt install -y curl wget socat nginx unzip uuid-runtime cron git

# 安装 acme.sh
echo -e "${GREEN}正在安装 acme.sh...${NC}"
if [[ ! -d "/root/.acme.sh" ]]; then
    curl https://get.acme.sh | sh -s email="${CF_EMAIL:-admin@$DOMAIN}"
fi
ACME_SH="/root/.acme.sh/acme.sh"
chmod +x "$ACME_SH"
"$ACME_SH" --upgrade --auto-upgrade
"$ACME_SH" --set-default-ca --server letsencrypt

# 设置 Cloudflare DNS 环境变量
echo -e "${GREEN}配置 Cloudflare DNS 认证环境变量...${NC}"
if [[ "$CF_MODE" == "1" ]]; then
    export CF_Token="$CF_TOKEN"
    # acme.sh 使用 CF_Token 即可，无需邮箱
else
    export CF_Key="$CF_KEY"
    export CF_Email="$CF_EMAIL"
fi

# 申请证书（仅域名本身，不申请通配符）
echo -e "${GREEN}正在申请 Let's Encrypt 证书（Cloudflare DNS-01）...${NC}"
"$ACME_SH" --issue --dns dns_cf -d "$DOMAIN" --force --log

# 安装证书到指定目录
CERT_PATH="/etc/ssl/vless/${DOMAIN}"
mkdir -p "$CERT_PATH"
"$ACME_SH" --install-cert -d "$DOMAIN" \
    --key-file "$CERT_PATH/privkey.pem" \
    --fullchain-file "$CERT_PATH/fullchain.pem" \
    --reloadcmd "systemctl reload nginx || true"

# 安装 Xray
echo -e "${GREEN}正在安装最新版 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 配置 Xray（VLESS + WS，无 TLS，由 Nginx 终止 TLS）
echo -e "${GREEN}正在写入 Xray 配置...${NC}"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

systemctl daemon-reload
systemctl restart xray
systemctl enable xray

# 配置 Nginx（伪装网站 + WS 代理）
echo -e "${GREEN}正在配置 Nginx...${NC}"
rm -rf /var/www/html
if ! git clone https://github.com/johnrosen1/vps.git /var/www/html 2>/dev/null; then
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Welcome</title>
</head>
<body>
  <h1>Welcome</h1>
  <p>This is a normal HTTPS website.</p>
</body>
</html>
HTML
fi

cat > /etc/nginx/conf.d/vless.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH/fullchain.pem;
    ssl_certificate_key $CERT_PATH/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # 伪装网站
    root /var/www/html;
    index index.html;

    # WebSocket 反代到 Xray（注意：这里直接使用变量 WS_PATH）
    location $WS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t
systemctl restart nginx
systemctl enable nginx

# 设置自动续期
echo -e "${GREEN}设置证书自动续期...${NC}"
cat > /etc/cron.daily/acme-renew <<EOF
#!/bin/bash
$ACME_SH --cron --home /root/.acme.sh > /dev/null 2>&1
systemctl reload nginx || true
EOF
chmod +x /etc/cron.daily/acme-renew

echo
echo -e "${GREEN}=== 安装完成！===${NC}"
echo
echo -e "${YELLOW}重要提醒：${NC}"
echo "1. 请登录 Cloudflare 面板，将域名 $DOMAIN 对应的 DNS 记录切换为 Proxied（橙云）模式"
echo "2. 等待几分钟让 DNS 传播和证书生效"
echo
echo -e "${GREEN}客户端配置（VLESS）：${NC}"
echo "地址 (address): $DOMAIN"
echo "端口 (port): 443"
echo "用户 ID (id): $UUID"
echo "加密 (encryption): none"
echo "传输协议 (network): ws"
echo "WS 路径 (path): $WS_PATH"
echo "底层传输安全 (tls): tls"
echo "SNI/Host: $DOMAIN"
echo
echo "推荐客户端：v2rayN、v2rayNG、Nekobox、Clash Meta 等"
echo
echo -e "${GREEN}如需卸载：xray uninstall && rm -rf /etc/ssl/vless /root/.acme.sh /etc/nginx/conf.d/vless.conf${NC}"
echo -e "${YELLOW}卸载后记得：systemctl restart nginx${NC}"
