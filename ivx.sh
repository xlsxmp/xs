#!/bin/bash
# ===========================================================
# VLESS + XHTTP + TLS + Nginx + Cloudflare CDN 一键部署脚本
# 适用于 Debian / Ubuntu
# ===========================================================

set -e

echo -e "\n=== 🚀 VLESS + XHTTP + TLS + Nginx 安装脚本 ===\n"

# 🧩 基础变量
read -p "请输入你的域名（已解析到当前服务器IP）: " DOMAIN
read -p "请输入用于申请证书的邮箱地址: " EMAIL

UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_PATH="/$(head -c 8 /dev/urandom | md5sum | cut -c1-8)"
XRAY_CONF_DIR="/usr/local/etc/xray"
NGINX_CONF_DIR="/etc/nginx/conf.d"
WEB_ROOT="/var/www/html"

echo -e "\n🆔 生成的 UUID: $UUID"
echo -e "🪶 随机路径: $XRAY_PATH"
echo -e "🌐 域名: $DOMAIN"
echo -e "\n⏳ 开始安装依赖...\n"

# 📦 安装依赖
apt update -y
apt install -y nginx certbot python3-certbot-nginx curl socat unzip jq

# ⚙️ 安装 Xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install

# 🔐 申请 TLS 证书
echo -e "\n🪪 申请 Let's Encrypt 证书..."
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# 🧱 创建 Nginx 配置
cat > $NGINX_CONF_DIR/xhttp.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root $WEB_ROOT;
    index index.html;

    # XHTTP 转发
    location $XRAY_PATH {
        proxy_redirect off;
        proxy_pass http://unix:/dev/shm/xhttp.sock;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 🧠 创建 Xray 配置
mkdir -p $XRAY_CONF_DIR

cat > $XRAY_CONF_DIR/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "/dev/shm/xhttp.sock,0666",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XRAY_PATH",
          "host": ["$DOMAIN"],
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# 🚀 启动服务
systemctl enable xray
systemctl restart xray
systemctl restart nginx

# 🌐 节点信息
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=xhttp&path=${XRAY_PATH}&host=${DOMAIN}#VLESS-XHTTP-TLS-CDN"

# 💾 保存节点信息
cat > /root/vless_info.txt <<EOF
==============================
 VLESS + XHTTP + TLS + Nginx
==============================
域名: $DOMAIN
UUID: $UUID
路径: $XRAY_PATH
端口: 443
证书: /etc/letsencrypt/live/$DOMAIN/
节点链接:
$VLESS_LINK
==============================
说明: 
✅ Cloudflare CDN 可直接开启橙云加速
✅ 浏览器访问 https://$DOMAIN 可看到伪装网站
EOF

clear
echo -e "\n✅ 安装完成！节点信息如下：\n"
cat /root/vless_info.txt
