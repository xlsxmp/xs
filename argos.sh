#!/usr/bin/env bash
# =====================================================
# Sing-box + Argo 固定隧道 一键安装脚本（简化版）
# 适用系统：Debian 12+
# 协议：VLESS + WS + TLS
# 作者：xlsxmp 精简优化版本
# =====================================================

set -e

INSTALL_DIR="/etc/sing-box"
mkdir -p $INSTALL_DIR

echo "=========================================="
echo " Sing-box + Cloudflare Argo 一键部署脚本 "
echo "=========================================="
echo

# 1. 输入 Argo 授权内容
echo "请输入 Argo 授权内容（支持 Cloudflare Argo Token 或 JSON 授权文件内容）:"
read -rp "> " ARGO_AUTH

if echo "$ARGO_AUTH" | grep -q "TunnelSecret"; then
    echo "检测到为 JSON 授权模式"
    echo "$ARGO_AUTH" > "$INSTALL_DIR/argo.json"
    ARGO_MODE="json"
else
    echo "检测到为 Token 模式"
    echo "$ARGO_AUTH" > "$INSTALL_DIR/argo_token.txt"
    ARGO_MODE="token"
fi

# 2. 输入 UUID
UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
echo "请输入 Sing-box UUID（默认随机生成）:"
read -rp "> " UUID
UUID=${UUID:-$UUID_DEFAULT}

# 3. 输入域名（Argo 已绑定的域名）
echo "请输入已在 Cloudflare 绑定隧道的域名（如 sub.example.com）:"
read -rp "> " ARGO_DOMAIN

# 4. 安装 sing-box
echo "正在安装 Sing-box..."
wget -qO /usr/local/bin/sing-box https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64
chmod +x /usr/local/bin/sing-box

# 5. 安装 cloudflared
echo "正在安装 Cloudflared..."
wget -qO /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared

# 6. 生成 Sing-box 配置
cat > $INSTALL_DIR/config.json <<EOF
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": 8443,
    "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
    "tls": { "enabled": false },
    "transport": { "type": "ws", "path": "/" }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 7. 创建 cloudflared systemd 服务
cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
Type=simple
User=root
EOF

if [ "$ARGO_MODE" = "json" ]; then
cat >> /etc/systemd/system/argo.service <<EOF
ExecStart=/usr/local/bin/cloudflared tunnel --config $INSTALL_DIR/argo.json run
EOF
else
cat >> /etc/systemd/system/argo.service <<EOF
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $(cat $INSTALL_DIR/argo_token.txt)
EOF
fi

cat >> /etc/systemd/system/argo.service <<EOF
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 8. 创建 Sing-box systemd 服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $INSTALL_DIR/config.json
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 9. 启动并设置开机自启
systemctl daemon-reload
systemctl enable sing-box argo
systemctl restart sing-box argo

# 10. 输出节点信息
echo
echo "================= 安装完成 ================="
echo "✅ Sing-box + Argo 隧道部署成功"
echo "------------------------------------------"
echo "协议类型: VLESS + WS + TLS"
echo "UUID: $UUID"
echo "域名: $ARGO_DOMAIN"
echo "路径: /"
echo "------------------------------------------"
echo "Clash/客户端节点链接："
echo
echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=%2F#$ARGO_DOMAIN"
echo "------------------------------------------"
echo "服务状态查看："
echo "systemctl status sing-box"
echo "systemctl status argo"
echo "=========================================="
