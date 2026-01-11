#!/bin/bash
# ============================================================
#  VLESS + XHTTP + TLS + Cloudflare CDN 一键安装脚本（专业版）
#  使用 Cloudflare Origin CA Token（最小权限）
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
apt install -y curl wget unzip socat openssl jq dnsutils

# 📄 输入信息
echo "请输入你的域名 (必须已解析到本机 IP):"
read -r DOMAIN
[ -z "$DOMAIN" ] && echo "❌ 域名不能为空" && exit 1

echo "请输入 Cloudflare Origin CA Token（最小权限）:"
read -r CF_TOKEN
[ -z "$CF_TOKEN" ] && echo "❌ Token 不能为空" && exit 1

# 🌐 检查域名解析
SERVER_IP=$(curl -s ipv4.ip.sb)
DOMAIN_IP=$(dig +short "$DOMAIN")

if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
    echo "❌ 域名未解析到本机 IP"
    echo "本机 IP: $SERVER_IP"
    echo "域名 IP: $DOMAIN_IP"
    exit 1
fi

# 🔒 检查 443 端口
if ss -tulnp | grep -q ":443"; then
    echo "❌ 443 端口已被占用"
    exit 1
fi

# 🔐 生成私钥与 CSR
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
  -H "Authorization: Bearer '"$CF_TOKEN"'" \
  -H "Content-Type: application/json" \
  --data "$BODY")

if [ "$(echo "$RESP" | jq -r '.success')" != "true" ]; then
  echo "❌ Cloudflare Origin CA 申请失败："
  echo "$RESP" | jq .
  exit 1
fi

echo "$RESP" | jq -r '.result.certificate' > "$SSL_CERT"
chmod 644 "$SSL_CERT"

echo "✅ Origin CA 证书申请成功"

# ⚙️ 安装 Xray-core（官方目录结构）
mkdir -p /usr/local/bin /usr/local/share/xray

wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -O /tmp/xray.zip
unzip -o /tmp/xray.zip -d /tmp/xray
install -m 755 /tmp/xray/xray /usr/local/bin/xray
install -m 644 /tmp/xray/geo* /usr/local/share/xray/
rm -rf /tmp/xray /tmp/xray.zip

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
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "$SSL_CERT",
              "keyFile": "$SSL_KEY"
            }
          ]
        },
        "xhttpSettings": {
          "path": "$PATH_ID",
          "mode": "auto"
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

# 👤 创建 xray 用户
useradd -r -s /usr/sbin/nologin xray || true
chown -R xray:xray /etc/xray /usr/local/share/xray

# 🧩 写入 systemd 服务
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=xray
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

# 📦 输出结果并写入文件
clear
ENCODED_PATH=${PATH_ID#*/}

# 输出 VLESS 链接到控制台
echo "======================================="
echo "   🎉 VLESS + XHTTP + TLS 部署完成"
echo "======================================="
echo "vless://$UUID@$DOMAIN:443?type=xhttp&host=$DOMAIN&security=tls&path=%2F${ENCODED_PATH}&mode=auto&sni=$DOMAIN&alpn=http%2F1.1&fp=chrome#VLESS-XHTTP-TLS"
echo ""
echo "📜 证书路径: $SSL_CERT"
echo "🔑 私钥路径: $SSL_KEY"
echo "⚙️ 配置文件: /etc/xray/config.json"
echo "======================================="

# 将节点信息写入文本文件
NODE_INFO_FILE="/etc/xray/node_info.txt"
cat > "$NODE_INFO_FILE" <<EOF
VLESS 配置:
=======================
vless://$UUID@$DOMAIN:443?type=xhttp&host=$DOMAIN&security=tls&path=%2F${ENCODED_PATH}&mode=auto&sni=$DOMAIN&alpn=http%2F1.1&fp=chrome#VLESS-XHTTP-TLS

证书路径: $SSL_CERT
私钥路径: $SSL_KEY
配置文件: /etc/xray/config.json
=======================
EOF

echo "✅ 节点信息已保存到 $NODE_INFO_FILE"
