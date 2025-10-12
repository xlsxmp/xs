#!/usr/bin/env bash
# ======================================================
#  VLESS + XHTTP + TLS + CDN + Nginx 一键安装脚本
#  作者：lang xi 适配版
# ======================================================

set -e

# ===== 用户输入 =====
read -p "请输入你的域名 (例如: your.domain.com): " DOMAIN
read -p "请输入 UUID (留空则自动生成): " UUID
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

# ===== 系统检测 =====
if ! command -v apt &>/dev/null; then
  echo "❌ 暂不支持此系统（仅支持基于APT的Linux）"
  exit 1
fi

# ===== 更新系统并安装依赖 =====
apt update -y
apt install -y curl nginx certbot socat jq unzip

# ===== 安装 Sing-box =====
if ! command -v sing-box &>/dev/null; then
  echo "⚙️ 正在安装 Sing-box ..."
  bash <(curl -fsSL https://sing-box.app/install.sh)
fi

mkdir -p /usr/local/etc/sing-box

# ===== 签发或导入证书 =====
echo "⚙️ 签发 Cloudflare Origin 证书 (推荐方式)"
read -p "是否已有 CF Origin 证书？[y/N]: " HAVE_CERT

if [[ "$HAVE_CERT" =~ ^[Yy]$ ]]; then
  read -p "请输入证书路径 (例如 /etc/ssl/cloudflare/origin.pem): " CERT_PATH
  read -p "请输入私钥路径 (例如 /etc/ssl/cloudflare/origin.key): " KEY_PATH
else
  echo "生成自签证书..."
  mkdir -p /etc/ssl/cloudflare
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/cloudflare/origin.key \
    -out /etc/ssl/cloudflare/origin.pem \
    -subj "/CN=${DOMAIN}"
  CERT_PATH="/etc/ssl/cloudflare/origin.pem"
  KEY_PATH="/etc/ssl/cloudflare/origin.key"
fi

# ===== 配置 Nginx =====
cat >/etc/nginx/conf.d/vless.conf <<EOF
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location /svwtca {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8080;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

nginx -t && systemctl reload nginx

# ===== 配置 Sing-box =====
cat >/usr/local/etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 8080,
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "xhttp",
        "path": "/svwtca"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# ===== 输出节点信息 =====
echo -e "\n✅ 安装完成！节点信息如下：\n"
echo "-----------------------------------------------"
echo "协议: VLESS + XHTTP + TLS + CDN + Nginx"
echo "域名: ${DOMAIN}"
echo "UUID: ${UUID}"
echo "路径: /svwtca"
echo "端口: 443"
echo "TLS: 开启 (Full/Strict)"
echo "-----------------------------------------------"
echo -e "\nClash 节点示例：\n"
echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=xhttp&path=%2Fsvwtca&sni=${DOMAIN}#VLESS-XHTTP-CDN"
echo "-----------------------------------------------"
