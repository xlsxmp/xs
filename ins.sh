#!/bin/bash

# ==============================
# VLESS+WS+TLS 一键安装脚本 (Standalone)
# 适配 Debian 12 / Ubuntu 20+
# By ChatGPT 修改版
# ==============================

set -e

DOMAIN=""
UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_PATH="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"

# ========== 函数 ==========

install_base() {
    apt update -y
    apt install -y curl wget unzip socat lsof cron
}

install_xray() {
    echo -e "\n[+] 安装 Xray-core ..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

install_cert() {
    echo -e "\n[+] 申请证书 (standalone 模式)"

    # 确保 80 端口空闲
    lsof -i:80 -t | xargs -r kill -9

    apt install -y certbot
    certbot certonly --standalone -n -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" --force-renewal

    mkdir -p $XRAY_PATH
    ln -sf /etc/letsencrypt/live/$DOMAIN/fullchain.pem $XRAY_PATH/fullchain.pem
    ln -sf /etc/letsencrypt/live/$DOMAIN/privkey.pem $XRAY_PATH/privkey.pem
}

config_xray() {
    echo -e "\n[+] 写入 Xray 配置 ..."
    cat > $XRAY_PATH/config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/$UUID"
        },
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$XRAY_PATH/fullchain.pem",
              "keyFile": "$XRAY_PATH/privkey.pem"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
}

enable_bbr() {
    echo -e "\n[+] 启用 BBR 加速 ..."
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p
    echo -e "[√] BBR 已启用，重启 VPS 生效"
}

show_menu() {
    clear
    echo "============================="
    echo " VLESS+WS+TLS 一键脚本"
    echo "============================="
    echo "1. 安装依赖"
    echo "2. 安装 Xray"
    echo "3. 申请证书 (standalone)"
    echo "4. 配置 Xray"
    echo "5. 启用 BBR"
    echo "6. 启动 Xray"
    echo "7. 显示节点信息"
    echo "0. 退出"
    echo "============================="
}

start_xray() {
    systemctl enable xray
    systemctl restart xray
    systemctl status xray --no-pager -l
}

show_info() {
    echo -e "\n[+] 节点信息："
    echo "协议: VLESS"
    echo "地址: $DOMAIN"
    echo "端口: 443"
    echo "UUID: $UUID"
    echo "加密: none"
    echo "传输: ws"
    echo "路径: /$UUID"
    echo "TLS: enabled"
    echo -e "\nVLESS 链接："
    echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=/$UUID#VLESS-WS-TLS"
}

# ========== 主逻辑 ==========

if [ -z "$1" ]; then
    while true; do
        show_menu
        read -p "请选择功能: " num
        case "$num" in
            1) install_base ;;
            2) install_xray ;;
            3) read -p "请输入域名: " DOMAIN; install_cert ;;
            4) config_xray ;;
            5) enable_bbr ;;
            6) start_xray ;;
            7) show_info ;;
            0) exit ;;
            *) echo "无效选项" ;;
        esac
        read -p "按回车键继续..." foo
    done
else
    echo "用法: bash $0"
fi
