#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户！${NC}"
    exit 1
fi

# 检查系统是否为 Debian 12
if ! grep -q "Debian GNU/Linux 12" /etc/os-release; then
    echo -e "${RED}此脚本仅支持 Debian 12 系统！${NC}"
    exit 1
fi

# 交互式输入
echo -e "${YELLOW}=== VLESS + WebSocket + TLS + Cloudflare CDN 搭建脚本 ===${NC}"
read -p "请输入您的域名（例如 example.com）: " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空！${NC}"
    exit 1
fi

read -p "请输入 WebSocket 路径（默认 /ws）： " WS_PATH
WS_PATH=${WS_PATH:-/ws}

read -p "请输入 UUID（留空将自动生成）： " UUID
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "${GREEN}已自动生成 UUID: $UUID${NC}"
fi

read -p "请输入 Cloudflare API 密钥（可选，留空跳过）： " CF_API_KEY
read -p "请输入 Cloudflare 账户邮箱（可选，留空跳过）： " CF_EMAIL

# 更新系统并安装依赖
echo -e "${YELLOW}正在更新系统并安装依赖...${NC}"
apt update && apt upgrade -y
apt install -y curl wget unzip nginx certbot python3-certbot-nginx jq

# 安装 Xray
echo -e "${YELLOW}正在安装 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
if [ $? -ne 0 ]; then
    echo -e "${RED}Xray 安装失败！请检查网络或手动安装。${NC}"
    exit 1
fi

# 配置 Xray
echo -e "${YELLOW}正在配置 Xray...${NC}"
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
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

# 启动 Xray
systemctl enable xray
systemctl restart xray
if [ $? -ne 0 ]; then
    echo -e "${RED}Xray 启动失败！请检查配置文件。${NC}"
    exit 1
fi
echo -e "${GREEN}Xray 配置完成并启动成功！${NC}"

# 申请 TLS 证书
echo -e "${YELLOW}正在申请 Let’s Encrypt TLS 证书...${NC}"
if [ -n "$CF_API_KEY" ] && [ -n "$CF_EMAIL" ]; then
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials <(echo -e "dns_cloudflare_email = $CF_EMAIL\ndns_cloudflare_api_key = $CF_API_KEY") -d $DOMAIN --email admin@$DOMAIN --agree-tos --non-interactive
else
    certbot certonly --nginx -d $DOMAIN --email admin@$DOMAIN --agree-tos --non-interactive
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}TLS 证书申请失败！请检查域名解析或 Cloudflare 配置。${NC}"
    exit 1
fi
echo -e "${GREEN}TLS 证书申请成功！${NC}"

# 配置 Nginx 反向代理
echo -e "${YELLOW}正在配置 Nginx 反向代理...${NC}"
cat > /etc/nginx/sites-available/vless << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

# 启用 Nginx 配置
ln -sf /etc/nginx/sites-available/vless /etc/nginx/sites-enabled/
nginx -t
if [ $? -ne 0 ]; then
    echo -e "${RED}Nginx 配置测试失败！请检查配置文件。${NC}"
    exit 1
fi

systemctl restart nginx
echo -e "${GREEN}Nginx 配置完成并重启成功！${NC}"

# 配置 Cloudflare CDN
echo -e "${YELLOW}正在配置 Cloudflare CDN...${NC}"
if [ -n "$CF_API_KEY" ] && [ -n "$CF_EMAIL" ]; then
    # 获取 Cloudflare 区域 ID
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ]; then
        echo -e "${RED}无法获取 Cloudflare 区域 ID！请检查 API 密钥或域名。${NC}"
    else
        # 设置 DNS 记录
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "X-Auth-Email: $CF_EMAIL" \
            -H "X-Auth-Key: $CF_API_KEY" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$(curl -s ifconfig.me)\",\"ttl\":1,\"proxied\":true}" > /dev/null
        echo -e "${GREEN}Cloudflare CDN 配置完成！${NC}"
    fi
else
    echo -e "${YELLOW}未提供 Cloudflare API 密钥，跳过 CDN 配置。确保已在 Cloudflare 手动配置 CDN！${NC}"
fi

# 输出配置信息
echo -e "${GREEN}=== 搭建完成！以下是您的配置信息 ===${NC}"
echo "域名: $DOMAIN"
echo "UUID: $UUID"
echo "WebSocket 路径: $WS_PATH"
echo "TLS: Enabled (Let’s Encrypt)"
echo "Nginx 反向代理: 端口 443"
echo "Cloudflare CDN: $([ -n "$CF_API_KEY" ] && echo "Enabled" || echo "Manual configuration required")"
echo -e "${YELLOW}请在客户端配置 VLESS + WebSocket + TLS，并确保 Cloudflare 的 SSL/TLS 设置为 'Full (strict)'。${NC}"
echo -e "${GREEN}客户端配置示例:${NC}"
echo "vless://$UUID@$DOMAIN:443?security=tls&type=ws&path=$WS_PATH#VLESS-WS-TLS"

# 保存配置信息到文件
echo -e "域名: $DOMAIN\nUUID: $UUID\nWebSocket 路径: $WS_PATH\nTLS: Enabled\nNginx 反向代理: 端口 443\nCloudflare CDN: $([ -n "$CF_API_KEY" ] && echo "Enabled" || echo "Manual configuration required")\n\n客户端配置:\nvless://$UUID@$DOMAIN:443?security=tls&type=ws&path=$WS_PATH#VLESS-WS-TLS" > /root/vless-config.txt
echo -e "${GREEN}配置信息已保存到 /root/vless-config.txt${NC}"
