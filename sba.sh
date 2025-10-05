#!/usr/bin/env bash
# ============================================================
# sba-lite.sh  |  Debian 12 专用精简版
# 功能：安装 Sing-box (VLESS+WS+TLS) + 固定 Cloudflare Argo 隧道
# 作者：精简自 xlsxmp/ArgoSbx
# 版本：1.0.0 (2025.10)
# ============================================================

set -e
WORK_DIR="/etc/sba"
TEMP_DIR="/tmp/sba"
mkdir -p $WORK_DIR $TEMP_DIR
trap "rm -rf $TEMP_DIR" EXIT

echo "========== SBA 精简安装脚本 (Debian12) =========="

# -------------------- 检查系统 --------------------
if [[ "$(lsb_release -is 2>/dev/null)" != "Debian" ]]; then
  echo "❌ 本脚本仅支持 Debian 系统！"
  exit 1
fi
if [[ "$(lsb_release -rs)" != "12" ]]; then
  echo "⚠️ 检测到非 Debian 12，可能不兼容。"
fi

# -------------------- 检查依赖 --------------------
apt update -y
apt install -y wget curl jq nginx openssl tar

# -------------------- 用户输入 --------------------
read -p "请输入 Argo 隧道授权 JSON 内容（完整一行）: " ARGO_JSON
read -p "请输入隧道域名（如 example.com）: " ARGO_DOMAIN
read -p "请输入本地 VLESS 端口 (默认 3001): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-3001}
read -p "请输入你的 UUID (可使用 https://www.uuidgenerator.net 生成): " UUID
read -p "请输入 WebSocket 路径 (默认 sba): " WS_PATH
WS_PATH=${WS_PATH:-sba}

# -------------------- 下载二进制 --------------------
cd $TEMP_DIR
echo "🔽 下载 Cloudflared 与 Sing-box ..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
wget -q https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz -O singbox.tar.gz
tar -xzf singbox.tar.gz
mv sing-box*/sing-box .
chmod +x cloudflared sing-box
mv cloudflared sing-box $WORK_DIR

# -------------------- 生成 Argo 配置 --------------------
mkdir -p $WORK_DIR/argo
echo "$ARGO_JSON" > $WORK_DIR/argo/tunnel.json
cat > $WORK_DIR/argo/tunnel.yml <<EOF
tunnel: $(jq -r .TunnelID $WORK_DIR/argo/tunnel.json)
credentials-file: $WORK_DIR/argo/tunnel.json
ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:443
  - service: http_status:404
EOF

# -------------------- 生成自签证书 --------------------
mkdir -p $WORK_DIR/cert
openssl ecparam -genkey -name prime256v1 -out $WORK_DIR/cert/sba.key >/dev/null 2>&1
openssl req -new -x509 -days 3650 -key $WORK_DIR/cert/sba.key -out $WORK_DIR/cert/sba.crt -subj "/CN=$ARGO_DOMAIN" >/dev/null 2>&1

# -------------------- NGINX 反向代理 --------------------
cat > /etc/nginx/sites-enabled/sba.conf <<EOF
server {
    listen 443 ssl;
    server_name $ARGO_DOMAIN;
    ssl_certificate $WORK_DIR/cert/sba.crt;
    ssl_certificate_key $WORK_DIR/cert/sba.key;

    location /$WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
nginx -t && systemctl restart nginx

# -------------------- Sing-box 配置 --------------------
mkdir -p $WORK_DIR/singbox
cat > $WORK_DIR/singbox/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $VLESS_PORT,
    "users": [{ "uuid": "$UUID" }],
    "tls": { "enabled": false },
    "transport": {
      "type": "ws",
      "path": "/$WS_PATH"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

# -------------------- Systemd 服务 --------------------
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$WORK_DIR/sing-box run -c $WORK_DIR/singbox/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
ExecStart=$WORK_DIR/cloudflared tunnel --config $WORK_DIR/argo/tunnel.yml run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box argo
systemctl restart sing-box argo

# -------------------- 输出节点信息 --------------------
sleep 2
IP=$(curl -s ipv4.ip.sb || echo "你的Argo域名")
VLESS_URL="vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$WS_PATH#SBA_VLESS"
CLASH_NODE="- { name: SBA_VLESS, type: vless, server: $ARGO_DOMAIN, port: 443, uuid: $UUID, network: ws, tls: true, sni: $ARGO_DOMAIN, ws-opts: { path: /$WS_PATH, headers: { Host: $ARGO_DOMAIN } } }"

echo ""
echo "✅ 安装完成！"
echo "--------------------------------------"
echo " Argo 域名:  $ARGO_DOMAIN"
echo " 本地端口:  $VLESS_PORT"
echo " UUID:      $UUID"
echo " WS 路径:   /$WS_PATH"
echo "--------------------------------------"
echo "🔗 VLESS 节点链接："
echo "$VLESS_URL"
echo "--------------------------------------"
echo "🧩 Clash 节点片段："
echo "$CLASH_NODE"
echo "--------------------------------------"
echo "如需查看日志： journalctl -u sing-box -e"
echo "如需卸载： systemctl disable --now sing-box argo && rm -rf /etc/sba /etc/systemd/system/{sing-box,argo}.service"
