#!/bin/bash
# ============================================================
#  VLESS + XHTTP + TLS + Cloudflare CDN 一键安装脚本
#  适配 Xray-core v25+，无需 Nginx/Caddy
#  ✅ 已改为 Cloudflare DNS API 模式申请证书
# ============================================================

set -euo pipefail

# 🧩 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "❌ 必须以 root 权限运行"
    exit 1
fi

# 🧱 安装依赖
apt update -y
apt install -y curl wget unzip socat openssl cron

# 📥 安装 acme.sh
if [ ! -d ~/.acme.sh ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 📄 输入信息
echo "请输入你的域名 (必须已解析到 Cloudflare):"
read DOMAIN
echo "请输入你的 Cloudflare API Token（仅需 Zone 权限）:"
read CF_Token
echo "请输入你的 Cloudflare 账号邮箱:"
read CF_Email

# ☁️ 使用 Cloudflare DNS API 方式签发证书
export CF_Token="$CF_Token"
export CF_Email="$CF_Email"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256

mkdir -p /etc/xray
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/xray/privkey.pem \
    --fullchain-file /etc/xray/fullchain.pem \
    --ecc


# ⚙️ 安装 Xray-core
mkdir -p /usr/local/bin
wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -O /tmp/xray.zip
unzip -o /tmp/xray.zip -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm /tmp/xray.zip

# 🧠 生成 UUID 和路径
UUID=$(xray uuid)
PATH_ID="/$(head -c 8 /dev/urandom | md5sum | cut -c1-6)"

# 📝 写入配置文件
cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "email": "user@$DOMAIN"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "certificates": [
            {
              "certificateFile": "/etc/xray/fullchain.pem",
              "keyFile": "/etc/xray/privkey.pem"
            }
          ]
        },
        "xhttpSettings": {
          "path": "$PATH_ID"
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

# 🧩 写入 systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 🔓 开放端口
if command -v ufw >/dev/null; then
    ufw allow 443/tcp
    ufw reload
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --reload
fi

# ✅ 输出结果
clear
echo "✅ 安装完成！"
echo "---------------------------------------"
echo " VLESS + XHTTP + TLS + CF CDN 已部署"
echo "---------------------------------------"
echo "节点信息如下："
echo "vless://$UUID@ip.sb:443?type=xhttp&host=${DOMAIN}&security=tls&path=%2F${PATH_ID#*/}&mode=packet-up&sni=$DOMAIN&alpn=h2%2Chttp%2F1.1&fp=Chrome#VLESS-XHTTP-TLS"
echo ""
echo "📜 证书路径: /etc/xray/fullchain.pem"
echo "🔑 私钥路径: /etc/xray/privkey.pem"
echo "⚙️  Xray配置: /etc/xray/config.json"
echo ""
echo "💡 在 Cloudflare 面板中确保："
echo "   - 代理状态为橙色云 ☁️"
echo "   - SSL 模式设为 Full (strict)"
echo "---------------------------------------"
