#!/bin/bash
set -e

# ==============================
# 基础变量
# ==============================

read -p "请输入你的域名（必须已解析到本机并开启CF橙云）: " DOMAIN

PORT=80
UUID=$(cat /proc/sys/kernel/random/uuid)

echo "域名: $DOMAIN"
echo "生成 UUID: $UUID"
echo "使用端口: $PORT"

sleep 2

# ==============================
# 更新系统
# ==============================

apt update -y
apt install -y curl wget ufw

# ==============================
# 安装 Xray
# ==============================

echo "安装 Xray-core..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# ==============================
# 写入 Xray 配置
# ==============================

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
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
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/xhttp"
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

# ==============================
# 仅允许 Cloudflare IP 访问 80
# ==============================

echo "配置防火墙，仅允许 Cloudflare 访问..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh

# Cloudflare IPv4
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do
    ufw allow from $ip to any port 80 proto tcp
done

# Cloudflare IPv6
for ip in $(curl -s https://www.cloudflare.com/ips-v6); do
    ufw allow from $ip to any port 80 proto tcp
done

ufw --force enable

# ==============================
# 启动服务
# ==============================

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

# ==============================
# 输出客户端信息
# ==============================

echo
echo "======================================"
echo "部署完成（生产级防探测版本）"
echo "======================================"
echo
echo "节点信息："
echo "地址: $DOMAIN"
echo "端口: 443"
echo "UUID: $UUID"
echo "路径: /xhttp"
echo "传输: XHTTP"
echo "TLS: 开启（由 Cloudflare 提供）"
echo
echo "客户端链接："
echo
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=xhttp&path=%2Fxhttp&mode=auto&sni=$DOMAIN#VLESS-XHTTP-CF"
echo
echo "======================================"
echo
echo "重要说明："
echo "1. Cloudflare SSL 模式必须设置为 Full"
echo "2. 必须开启 HTTP/2"
echo "3. DNS 必须是橙云"
echo "4. 源站 80 端口已仅允许 CF 访问"
echo
echo "完成。"
