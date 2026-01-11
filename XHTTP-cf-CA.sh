#!/bin/bash
# ============================================================
#  VLESS + XHTTP + TLS + Cloudflare CDN 一键安装脚本
#  使用 Cloudflare Origin CA 证书（参考已实测成功代码）
#  适配 Xray-core v25+，无需 Nginx/Caddy/acme.sh
# ============================================================

set -euo pipefail

# 🧩 检查 root
if [ "$(id -u)" != "0" ]; then
    echo "❌ 必须以 root 权限运行"
    exit 1
fi

# 🧱 安装依赖
apt update -y
apt install -y curl wget unzip socat openssl jq

# 📄 输入信息
echo "请输入你的域名 (必须已解析到本机 IP):"
read -r DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "❌ 域名不能为空"
  exit 1
fi

echo "请输入 Cloudflare 账户邮箱:"
read -r CF_EMAIL
if [ -z "$CF_EMAIL" ]; then
  echo "❌ Cloudflare 邮箱不能为空"
  exit 1
fi

echo "请输入 Cloudflare Global API Key:"
read -r CF_GLOBAL_KEY
if [ -z "$CF_GLOBAL_KEY" ]; then
  echo "❌ Cloudflare Global API Key 不能为空"
  exit 1
fi

# 🔐 生成私钥与 CSR（完全参考你提供的脚本逻辑）
SSL_CERT="/etc/xray/fullchain.pem"
SSL_KEY="/etc/xray/privkey.pem"
CSR="/tmp/$DOMAIN.csr"

mkdir -p /etc/xray

echo "🔐 生成私钥与 CSR..."
openssl genrsa -out "$SSL_KEY" 2048
chmod 600 "$SSL_KEY"

openssl req -new -key "$SSL_KEY" -out "$CSR" -subj "/CN=$DOMAIN"

CSR_CONTENT=$(cat "$CSR")

echo "🔧 正在向 Cloudflare 请求 Origin CA 证书..."

BODY=$(jq -n --arg csr "$CSR_CONTENT" --arg hn "$DOMAIN" \
  '{hostnames: [$hn], requested_validity: 5475, request_type: "origin-rsa", csr: $csr}')

URL="https://api.cloudflare.com/client/v4/certificates"

RESP=$(curl -s -X POST "$URL" \
  -H "X-Auth-Email: $CF_EMAIL" \
  -H "X-Auth-Key: $CF_GLOBAL_KEY" \
  -H "Content-Type: application/json" \
  --data "$BODY")

if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
  echo "❌ Cloudflare Origin CA 申请失败，返回信息如下："
  echo "$RESP" | jq .
  exit 1
fi

echo "$RESP" | jq -r '.result.certificate' > "$SSL_CERT"
chmod 644 "$SSL_CERT"

echo "✅ Cloudflare Origin CA 证书申请成功！"
echo "   证书: $SSL_CERT"
echo "   私钥: $SSL_KEY"

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
              "certificateFile": "$SSL_CERT",
              "keyFile": "$SSL_KEY"
            }
          ]
        },
        "xhttpSettings": {
          "path": "$PATH_ID"
          "mode": "packet-up"
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
ENCODED_PATH=${PATH_ID#*/}
echo "节点信息如下："
echo "vless://$UUID@ip.sb:443?type=xhttp&host=${DOMAIN}&security=tls&path=%2F${ENCODED_PATH}&mode=packet-up&sni=$DOMAIN&alpn=h2%2Chttp%2F1.1&fp=Chrome#VLESS-XHTTP-TLS"
echo ""
echo "📜 证书路径: $SSL_CERT"
echo "🔑 私钥路径: $SSL_KEY"
echo "⚙️  Xray配置: /etc/xray/config.json"
echo ""
echo "💡 在 Cloudflare 面板中确保："
echo "   - 代理状态为橙色云 ☁️"
echo "   - SSL 模式设为 Full (strict)"
echo "---------------------------------------"
