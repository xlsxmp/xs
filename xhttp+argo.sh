 #!/bin/bash
set -e

# ==============================
# 1. 输入信息
# ==============================
printf "请输入你的 CDN 域名（必须已解析到本机并开启CF橙云）: "
read -r CDN_DOMAIN

printf "请输入你的 Argo 域名（Zero Trust Public Hostname）: "
read -r ARGO_DOMAIN

printf "请输入你的 Cloudflare Tunnel Token: "
read -r ARGO_TOKEN

if [ -z "$CDN_DOMAIN" ] || [ -z "$ARGO_DOMAIN" ] || [ -z "$ARGO_TOKEN" ]; then
    echo "输入不能为空"
    exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
XHTTP_PATH="/$(head -c 8 /dev/urandom | md5sum | head -c 8)-xhttp"
ARGO_PATH="/$(head -c 8 /dev/urandom | md5sum | head -c 8)-argo"

echo "UUID: $UUID"
echo "XHTTP 路径: $XHTTP_PATH"
echo "Argo 路径: $ARGO_PATH"
sleep 2

# ==============================
# 2. 安装依赖
# ==============================
apt update
apt install -y curl wget unzip ca-certificates

# ==============================
# 3. 安装 Xray-core
# ==============================
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f4)
wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"

mkdir -p /usr/local/bin /usr/local/etc/xray
unzip -q /tmp/xray.zip -d /tmp/xray_ext
mv /tmp/xray_ext/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
rm -rf /tmp/xray.zip /tmp/xray_ext

# ==============================
# 4. 写入 Xray 配置
# ==============================
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [
    {
      "port": 80,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto",
          "host": "$CDN_DOMAIN"
        }
      }
    },
    {
      "port": 8081,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$ARGO_PATH" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ==============================
# 5. Xray systemd 服务
# ==============================
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ==============================
# 6. 安装 cloudflared（Argo）
# ==============================
wget -q -O /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x /usr/local/bin/cloudflared

mkdir -p /root/.cloudflared
echo "$ARGO_TOKEN" > /root/.cloudflared/token
chmod 600 /root/.cloudflared/token

# ==============================
# 7. cloudflared systemd 服务
# ==============================
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflared Argo Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate  --loglevel error --edge-ip-version 4 run --token-file /root/.cloudflared/token
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

# ==============================
# 8. 输出节点信息
# ==============================
INFO_FILE="/root/xray_nodes.txt"

cat > "$INFO_FILE" <<EOF
===========================================
🎉 Debian 12 旗舰版 Xray + Argo 部署完成！
===========================================

UUID: $UUID

-------------------------------------------
【节点 1：VLESS + XHTTP + Cloudflare CDN】
用途：常规 CDN 加速，CF 负责 TLS
-------------------------------------------
vless://$UUID@$CDN_DOMAIN:443?encryption=none&security=tls&type=xhttp&path=$XHTTP_PATH&mode=auto&sni=$CDN_DOMAIN#VLESS-XHTTP-CF

-------------------------------------------
【节点 2：VLESS + WS + Argo Tunnel】
用途：内网穿透，支持优选 IP
-------------------------------------------
直连：
vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&path=$ARGO_PATH&sni=$ARGO_DOMAIN#VLESS-Argo-直连

优选 IP（示例）：
vless://$UUID@104.16.20.30:443?encryption=none&security=tls&type=ws&path=$ARGO_PATH&host=$ARGO_DOMAIN&sni=$ARGO_DOMAIN#VLESS-Argo-优选IP

-------------------------------------------
查看节点信息：
cat /root/xray_nodes.txt
===========================================
EOF

cat "$INFO_FILE"
