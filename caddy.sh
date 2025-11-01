#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "=========================================="
echo "🚀 Debian12 VPS 一键部署: Xray + Caddy + Cloudflare DNS-01"
echo "=========================================="

# === 用户输入 ===
read -p "请输入你的域名 (example.com): " DOMAIN
read -p "请输入 Cloudflare API Token: " CF_TOKEN

# === 基础变量 ===
UUID=$(cat /proc/sys/kernel/random/uuid)
WSPATH="/$(head -c 16 /dev/urandom | md5sum | cut -c1-8)"

echo
echo ">>> 生成 UUID: $UUID"
echo ">>> 随机路径: $WSPATH"
echo ">>> 域名: $DOMAIN"
echo

# === 安装依赖 ===
echo ">>> 安装系统依赖..."
apt update -y
apt install -y curl wget socat ufw debian-keyring debian-archive-keyring apt-transport-https

# === 配置防火墙 ===
echo ">>> 配置防火墙规则..."
ufw allow 443/tcp || true
ufw allow 80/tcp || true
ufw reload || true

# === 安装 Caddy（带 DNS 插件）===
echo ">>> 安装 Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt update
apt install -y caddy

# === 设置 Cloudflare Token 环境变量 ===
echo ">>> 配置 Cloudflare API Token..."
export CLOUDFLARE_API_TOKEN="$CF_TOKEN"
echo "CLOUDFLARE_API_TOKEN=$CF_TOKEN" >> /etc/environment

# === 安装 Xray ===
echo ">>> 安装 Xray..."
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

# === 写入 Xray 配置 ===
echo ">>> 写入 Xray 配置..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "email": "user@$DOMAIN" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WSPATH" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF

# === 写入 Caddyfile ===
echo ">>> 写入 Caddy 配置..."
cat > /etc/caddy/Caddyfile <<EOF
{
    acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    email admin@$DOMAIN
}

$DOMAIN {
    encode gzip
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    @ws {
        path $WSPATH
    }
    reverse_proxy @ws 127.0.0.1:10000
    root * /var/www/html
    file_server
}
EOF

# === 重启服务 ===
echo ">>> 启动并启用服务..."
systemctl daemon-reload
systemctl restart xray
systemctl restart caddy
systemctl enable xray caddy

# === 输出 VLESS 链接 ===
VLESS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$WSPATH#$DOMAIN"

echo
echo "=========================================="
echo "✅ 部署完成！节点信息如下："
echo "------------------------------------------"
echo "$VLESS_LINK"
echo "------------------------------------------"
echo "📁 节点信息已保存至 /root/vless.txt"
echo "📜 Cloudflare DNS 模式证书自动续期（无需额外设置）"
echo "=========================================="

echo "[$(date '+%F %T')] $VLESS_LINK" >> /root/vless.txt
