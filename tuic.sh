#!/bin/bash

# sing-box TUIC v5 协议一键安装脚本（服务器端）
# 适用于 Ubuntu/Debian 系统（推荐干净系统）
# 支持 x86_64 / aarch64 架构
# 使用自签名证书（客户端需开启 allow_insecure）
# 自动生成 UUID + 密码、开启 BBR、开放 UDP 端口、配置 UFW
# 作者：Grok 提供（2026 年版本）

set -e

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行此脚本（sudo bash install.sh）"
    exit 1
fi

# 检查系统
if ! command -v apt >/dev/null 2>&1; then
    echo "错误：本脚本仅支持 Debian/Ubuntu 系统"
    exit 1
fi

echo "正在更新系统并安装依赖..."
apt update -y && apt upgrade -y
apt install -y curl wget openssl ufw tar

# 启用 UFW（保留 SSH）
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null

# 用户输入
read -p "请输入监听端口（默认 443）： " PORT
PORT=${PORT:-443}

read -p "请输入伪装 SNI 域名（默认 www.bing.com，推荐使用常见域名避免封锁）： " SNI
SNI=${SNI:-www.bing.com}

# 生成 UUID 和密码
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(openssl rand -base64 16)

# 获取服务器公网 IP（优先 IPv4）
SERVER_IP=$(curl -s -4 https://api.ipify.org) || SERVER_IP=$(curl -s -4 icanhazip.com)
if [[ -z "$SERVER_IP" ]]; then
    echo "警告：无法自动获取公网 IP，请手动替换连接字符串中的 IP"
    SERVER_IP="YOUR_SERVER_IP"
fi

echo ""
echo "========== 配置信息 =========="
echo "端口：$PORT (UDP)"
echo "UUID：$UUID"
echo "密码：$PASSWORD"
echo "SNI：$SNI"
echo "服务器 IP：$SERVER_IP"
echo "==============================="
echo ""

# 创建目录
mkdir -p /etc/sing-box

# 生成自签名证书（有效期约 100 年）
echo "正在生成自签名证书..."
openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/server.key >/dev/null 2>&1
openssl req -new -x509 -key /etc/sing-box/server.key -out /etc/sing-box/server.crt -days 36500 -subj "/CN=$SNI" >/dev/null 2>&1

# 检测架构并下载最新 sing-box
echo "正在检测架构并下载最新 sing-box..."
ARCH=$(uname -m)
case $ARCH in
    x86_64)   SB_ARCH="amd64" ;;
    aarch64)  SB_ARCH="arm64" ;;
    *)        echo "错误：不支持的架构 $ARCH" ; exit 1 ;;
esac

VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name": "\K[^"]+' | sed 's/v//')
if [[ -z "$VERSION" ]]; then
    echo "错误：无法获取最新版本，请检查网络"
    exit 1
fi

wget -q https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz -O sing-box.tar.gz
tar -xzf sing-box.tar.gz
mv sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf sing-box*

# 写入配置文件
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": true,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/server.crt",
        "key_path": "/etc/sing-box/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

# 创建 systemd 服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box TUIC Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable --now sing-box >/dev/null

# 开放端口
ufw allow $PORT/udp >/dev/null9
ufw reload >/dev/null

# 启用 BBR
echo "正在启用 TCP BBR 拥塞控制..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null
modprobe tcp_bbr || true

echo ""
echo "========== 安装完成 =========="
echo "sing-box TUIC 服务已启动并开机自启"
echo "客户端连接字符串（适用于 NekoBox、sing-box、Hiddify 等客户端）："
echo ""
echo "tuic://$UUID:$PASSWORD@$SERVER_IP:$PORT?alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1&sni=$SNI"
echo ""
echo "注意事项："
echo "1. 由于使用自签名证书，客户端必须开启「允许不安全连接」（allow_insecure=1）"
echo "2. 如有域名，建议使用 acme 获取真实证书并替换自签名证书以提高安全性"
echo "3. 查看日志：journalctl -u sing-box -f"
echo "4. 更新 sing-box：重新运行本脚本或手动替换二进制文件"
echo "5. 卸载：systemctl stop sing-box && rm -rf /usr/local/bin/sing-box /etc/sing-box /etc/systemd/system/sing-box.service"
