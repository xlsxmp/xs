#!/bin/bash

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本"
  exit 1
fi

# 检查系统是否为Debian 12
if [ ! -f /etc/debian_version ] || [ "$(cat /etc/debian_version | cut -d'.' -f1)" != "12" ]; then
  echo "此脚本仅支持Debian 12"
  exit 1
fi

# 更新系统并安装必要工具
apt update && apt upgrade -y
apt install -y curl wget unzip nginx uuid-runtime certbot python3-certbot-nginx

# 获取用户输入
read -p "请输入您的域名（例如：example.com）: " DOMAIN
read -p "请输入VLESS监听端口（默认8443）: " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-8443}
UUID=$(uuidgen)
read -p "请输入Cloudflare CDN的代理端口（默认443）: " CF_PORT
CF_PORT=${CF_PORT:-443}

# 安装Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 创建Xray配置文件
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0,
            "email": "user@example.com"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "http",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
            }
          ]
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

# 获取SSL证书
certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN

# 配置Nginx反向代理
cat > /etc/nginx/sites-available/vless << EOF
server {
    listen $CF_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 启用Nginx配置
ln -s /etc/nginx/sites-available/vless /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 启动Xray
systemctl enable xray
systemctl restart xray

# 输出客户端配置信息
echo "VLESS配置信息："
echo "地址: $DOMAIN"
echo "端口: $CF_PORT"
echo "UUID: $UUID"
echo "协议: VLESS"
echo "传输: XHTTP"
echo "安全: TLS"
echo "请将上述信息配置到您的VLESS客户端，并确保Cloudflare CDN已启用代理（橙色云图标）"
