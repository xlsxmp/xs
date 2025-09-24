#!/bin/bash
# Auth: happylife
# Desc: Xray VLESS+WS+TLS + Nginx + Cloudflare CDN 自动部署 (交互式版本)
# Plat: Debian 12 / Ubuntu 20.04+

echo "=== Xray VLESS+WS+TLS + Cloudflare CDN 自动部署 ==="

# 交互式输入域名
read -p "请输入你的域名: " domainName
if [ -z "$domainName" ]; then
    echo "域名不能为空！"
    exit 1
fi

# 随机端口 & UUID
xrayPort=$(shuf -i 20000-49000 -n 1)
fallbacksPort=$(shuf -i 50000-65000 -n 1)
uuid=$(uuidgen)

echo "域名: $domainName"
echo "UUID: $uuid"
echo "Xray 端口: $xrayPort"
echo "回落端口: $fallbacksPort"

sleep 2

# 设置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 安装依赖
apt update
apt install -y curl pwgen openssl netcat cron socat nginx
systemctl enable nginx
systemctl start nginx

# 安装 Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
systemctl enable xray

# 安装 acme.sh 申请证书
ssl_dir="/usr/local/etc/xray/ssl"
mkdir -p $ssl_dir
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$domainName" --keylength ec-256 --alpn
~/.acme.sh/acme.sh --installcert -d "$domainName" \
  --fullchainpath $ssl_dir/xray.crt \
  --keypath $ssl_dir/xray.key --ecc

# Nginx 配置
cat > /etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 80;
    server_name $domainName;
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF
systemctl restart nginx

# Xray 配置
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $xrayPort,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "level": 0,
            "email": "user@$domainName"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          { "dest": $fallbacksPort }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$ssl_dir/xray.crt",
              "keyFile": "$ssl_dir/xray.key"
            }
          ]
        },
        "wsSettings": {
          "path": "/ray"
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

systemctl restart xray
systemctl status -l xray

# 输出节点信息，并保存到 /root/node.txt
node="vless://$uuid@$domainName:443?encryption=none&security=tls&type=ws&host=$domainName&path=/ray#xray_ws_tls"
echo
echo "=== 部署完成 ==="
echo "VLESS 节点信息："
echo "$node"
echo "$node" > /root/node.txt
echo "节点信息已保存到 /root/node.txt"
