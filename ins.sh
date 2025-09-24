#!/bin/bash
# Auth: happylife
# Desc: Xray VLESS+WS+TLS + CF CDN 自动部署交互式脚本 (Debian 12)
# Usage: bash xray_ws_tls_cf_interactive.sh

set -e

echo "=== Xray VLESS+WS+TLS + Cloudflare CDN 自动部署 ==="

# -------- 1. 用户输入域名 --------
read -p "请输入你的域名 (必须已解析到当前服务器IP): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "域名不能为空！"
    exit 1
fi

# -------- 2. 检查域名是否开启 CF 代理（橙云） --------
CF_STATUS=$(curl -s "https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A" -H 'accept: application/dns-json' | grep -o 'cdn.cloudflare.net\|104.?.?.?')
if [[ "$CF_STATUS" != "" ]]; then
    echo "[Info] 域名 $DOMAIN 已开启 Cloudflare 代理（橙云）"
    CF_ENABLED=true
else
    echo "[Warning] 域名 $DOMAIN 未开启 Cloudflare 代理，建议开启以使用 WS+TLS 套 CDN"
    CF_ENABLED=false
fi

# -------- 3. 用户选择端口 --------
echo "注意：Cloudflare 套 WS+TLS 必须使用支持端口：443/8443/2053/2083/2087/2096/8443"
read -p "请输入 Xray WS TLS 端口 (建议 443): " XRAY_PORT
if [ -z "$XRAY_PORT" ]; then XRAY_PORT=443; fi

# -------- 4. 随机生成 UUID 和 WS 路径 --------
UUID=$(uuidgen)
WS_PATH="/$(pwgen -A0 6 8 | xargs | sed 's/ /\//g')"
SSL_DIR="/usr/local/etc/xray/ssl/$(date +%F-%H-%M-%S)"
mkdir -p "$SSL_DIR"

# -------- 5. 安装依赖 --------
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y nginx curl pwgen openssl netcat cron lsof uuid-runtime
systemctl enable nginx
systemctl stop nginx

# -------- 6. 检查域名解析 --------
LOCAL_IP=$(curl -s ifconfig.me)
RESOLVE_IP=$(dig +short "$DOMAIN" | tail -n1)
if [ "$LOCAL_IP" != "$RESOLVE_IP" ]; then
    echo "域名解析不正确！请确保 $DOMAIN 解析到本机 IP"
    exit 1
fi

# -------- 7. 安装 acme.sh 并申请证书 --------
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$DOMAIN" -k ec-256 --alpn
~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
    --fullchainpath "$SSL_DIR/xray.crt" \
    --keypath "$SSL_DIR/xray.key" --ecc
chown www-data:www-data "$SSL_DIR/xray.crt" "$SSL_DIR/xray.key"

# 自动续期脚本
cat >/usr/local/bin/ssl_renew.sh <<EOF
#!/bin/bash
systemctl stop nginx
~/.acme.sh/acme.sh --cron --home "/root/.acme.sh" &>/root/renew_ssl.log
systemctl start nginx
EOF
chmod +x /usr/local/bin/ssl_renew.sh
(crontab -l; echo "15 03 * * * /usr/local/bin/ssl_renew.sh") | crontab -

# -------- 8. 安装 Xray --------
bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
systemctl enable xray

# -------- 9. 配置 Xray --------
mkdir -p /usr/local/etc/xray
cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": $XRAY_PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID","level":1}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "$WS_PATH"
      },
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$SSL_DIR/xray.crt",
          "keyFile": "$SSL_DIR/xray.key"
        }]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# -------- 10. 配置 Nginx 反代 --------
cat >/etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $SSL_DIR/xray.crt;
    ssl_certificate_key $SSL_DIR/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+AESGCM:EECDH+CHACHA20:!MD5;

    root /usr/share/nginx/html;

    location $WS_PATH {
        proxy_redirect off;
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

# -------- 11. 启动服务 --------
systemctl restart xray
nginx -t && systemctl restart nginx

# -------- 12. 输出节点信息 --------
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?type=ws&security=tls&host=${DOMAIN}&path=${WS_PATH}&tls=1#${DOMAIN}_vless_ws_tls"

echo
echo "===== 部署完成 ====="
echo "域名: $DOMAIN"
echo "端口: 443"
echo "协议: VLESS+WS+TLS"
echo "UUID: $UUID"
echo "WebSocket路径: $WS_PATH"
echo
echo "【Clash / V2RayNG 节点链接】"
echo "$VLESS_LINK"
echo
if [ "$CF_ENABLED" = true ]; then
    echo "[Info] 你的域名已开启 Cloudflare（橙云），节点可直接套 CF CDN 使用"
else
    echo "[Warning] 你的域名未开启 Cloudflare（橙云），请开启以获得 CDN 加速"
fi
