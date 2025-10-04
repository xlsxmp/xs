#!/bin/bash
# ========================================
# Sing-box + Cloudflared Argo Tunnel 一键安装脚本
# 支持 UUID 随机生成、WS+TLS、固定 Argo 隧道
# ========================================

# ===== 颜色 =====
red="\033[1;91m"
green="\033[1;32m"
yellow="\033[1;33m"
purple="\033[1;35m"
reset="\033[0m"
cecho() { echo -e "${1}$2${reset}"; }

# ===== 工作目录 =====
WORKDIR="$HOME/.singbox"
ARGO_DIR="$WORKDIR/argo"
mkdir -p "$ARGO_DIR"

# ===== UUID =====
UUID=$(uuidgen)
cecho $green "生成随机 UUID: $UUID"

# ===== 用户输入 Vmess WS 端口 =====
while true; do
    read -p "请输入 Vmess WS 端口 (1-65535, 443 推荐): " VMESS_PORT
    if [[ "$VMESS_PORT" =~ ^[0-9]+$ ]] && [ "$VMESS_PORT" -ge 1 ] && [ "$VMESS_PORT" -le 65535 ]; then
        break
    else
        cecho $yellow "输入错误，请输入 1-65535 的数字"
    fi
done

# ===== 用户输入 Argo 固定隧道 =====
read -p "请输入 Argo 固定隧道域名: " ARGO_DOMAIN
read -p "请输入 Argo Tunnel Token 或 JSON: " ARGO_AUTH

# ===== 下载官方 cloudflared =====
CLOUD_PATH="$WORKDIR/cloudflared"
if [ ! -f "$CLOUD_PATH" ]; then
    wget -O "$CLOUD_PATH" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUD_PATH"
    cecho $green "cloudflared 下载完成"
fi

# ===== 保存 ARGO_AUTH JSON =====
echo "$ARGO_AUTH" > "$ARGO_DIR/tunnel.json"

# ===== 生成 tunnel.yml =====
TUNNEL_SECRET=$(echo "$ARGO_AUTH" | grep -oP '(?<=TunnelSecret": ")[^"]+')
cat > "$ARGO_DIR/tunnel.yml" <<EOF
tunnel: $TUNNEL_SECRET
credentials-file: $ARGO_DIR/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$VMESS_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

cecho $green "tunnel.yml 已生成"

# ===== 下载官方 sing-box =====
ARCH=$(uname -m)
SB_PATH="$WORKDIR/sing-box"
if [ ! -f "$SB_PATH" ]; then
    if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
        wget -O "$SB_PATH" https://github.com/sagernet/sing-box/releases/latest/download/sing-box-linux-amd64
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        wget -O "$SB_PATH" https://github.com/sagernet/sing-box/releases/latest/download/sing-box-linux-arm64
    else
        cecho $red "不支持的架构: $ARCH"
        exit 1
    fi
    chmod +x "$SB_PATH"
    cecho $green "sing-box 下载完成"
fi

# ===== 生成 sing-box config.json =====
cat > "$WORKDIR/config.json" <<EOF
{
  "log": {"level":"info"},
  "dns": {"servers":["8.8.8.8"]},
  "inbounds": [{
    "tag": "vmess-ws-in",
    "type": "vmess",
    "listen": "::",
    "listen_port": $VMESS_PORT,
    "users": [{"uuid": "$UUID"}],
    "transport": {"type": "ws", "path": "/vmess"}
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
cecho $green "sing-box config.json 已生成"

# ===== 生成 Vmess 链接 =====
IP=$(curl -s ipv4.ip.sb || echo "127.0.0.1")
cat > "$WORKDIR/list.txt" <<EOF
vmess://$(echo "{ \"v\": \"2\", \"ps\": \"SingBox\", \"add\": \"$ARGO_DOMAIN\", \"port\": \"$VMESS_PORT\", \"id\": \"$UUID\", \"aid\": 0, \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/vmess\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN\"}" | base64 -w0)
EOF
cecho $green "Vmess 链接已生成在 $WORKDIR/list.txt"

# ===== systemd: cloudflared 服务 =====
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflared Argo Tunnel
After=network.target

[Service]
ExecStart=$CLOUD_PATH tunnel --config $ARGO_DIR/tunnel.yml run
Restart=on-failure
User=$(whoami)
WorkingDirectory=$WORKDIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared
cecho $green "cloudflared 服务已启动"

# ===== systemd: sing-box 服务 =====
cat > /etc/systemd/system/singbox.service <<EOF
[Unit]
Description=Sing-box WS+TLS
After=network.target cloudflared.service

[Service]
ExecStart=$SB_PATH run -c $WORKDIR/config.json
Restart=on-failure
User=$(whoami)
WorkingDirectory=$WORKDIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable singbox
systemctl start singbox
cecho $green "sing-box 服务已启动"

# ===== 完成提示 =====
cecho $green "部署完成！"
cecho $green "查看 sing-box 状态: systemctl status singbox"
cecho $green "查看 cloudflared 状态: systemctl status cloudflared"
cecho $green "Vmess 链接: $WORKDIR/list.txt"
