#!/bin/bash

# sing-box 多协议一键管理脚本（修复版）
# 支持：TUIC v5（自签名证书） + VLESS + Argo Tunnel（固定域名）
# 修复内容：
# 1. 修复 enable_bbr 中的拼写错误：default_qisc → default_qdisc
# 2. 增强 UFW 命令容错（避免已启用/已开放端口时导致脚本退出）
# 3. 菜单文字调整为更简洁（匹配您运行时的显示）
# 4. 其他小优化（重复运行更安全）
# 适用于 Ubuntu/Debian 系统（推荐干净系统）
# 支持 x86_64 / aarch64 架构

set -e

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行此脚本（sudo bash $0）"
    exit 1
fi

# 检查系统
if ! command -v apt >/dev/null 2>&1; then
    echo "错误：本脚本仅支持 Debian/Ubuntu 系统"
    exit 1
fi

# 安装/更新 sing-box（最新版）
install_singbox() {
    echo "正在安装/更新 sing-box..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)   SB_ARCH="amd64" ;;
        aarch64)  SB_ARCH="arm64" ;;
        *)        echo "错误：不支持的架构 $ARCH" ; exit 1 ;;
    esac

    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name": "\K[^"]+' | sed 's/v//')
    if [[ -z "$VERSION" ]]; then
        echo "错误：无法获取 sing-box 最新版本，网络问题或 GitHub 限流"
        echo "建议手动下载最新版放入 /usr/local/bin/sing-box"
        exit 1
    fi

    wget -q https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz -O sing-box.tar.gz
    tar -xzf sing-box.tar.gz
    mv sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-${VERSION}-linux-${SB_ARCH}
    echo "sing-box 更新完成（版本：${VERSION}）"
}

# 启用 BBR（修复拼写 + 避免重复添加导致问题）
enable_bbr() {
    echo "正在启用 TCP BBR 拥塞控制..."
    # 使用 sysctl.d 避免污染主配置文件，且更规范
    mkdir -p /etc/sysctl.d
    echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1
    modprobe tcp_bbr || true
    echo "BBR 已启用"
}

# 安装 TUIC
install_tuic() {
    echo "开始安装 TUIC 节点..."

    apt update -y && apt upgrade -y
    apt install -y curl wget openssl ufw tar

    install_singbox
    enable_bbr

    # UFW 配置（增强容错）
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true

    # 用户输入
    read -p "请输入监听端口（默认 443）： " PORT
    PORT=${PORT:-443}
    read -p "请输入伪装 SNI 域名（默认 www.bing.com）： " SNI
    SNI=${SNI:-www.bing.com}

    # 生成凭证
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(openssl rand -base64 16)

    # 获取公网 IP
    SERVER_IP=$(curl -s -4 https://api.ipify.org) || SERVER_IP=$(curl -s -4 icanhazip.com)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="YOUR_SERVER_IP"
        echo "警告：无法自动获取公网 IP，请手动替换连接字符串"
    fi

    # 创建目录与自签名证书
    mkdir -p /etc/sing-box
    openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/tuic.key >/dev/null 2>&1
    openssl req -new -x509 -key /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt -days 36500 -subj "/CN=$SNI" >/dev/null 2>&1

    # 配置
    cat > /etc/sing-box/config-tuic.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "tuic",
    "tag": "tuic-in",
    "listen": "::",
    "listen_port": $PORT,
    "users": [{"uuid": "$UUID", "password": "$PASSWORD"}],
    "congestion_control": "bbr",
    "auth_timeout": "3s",
    "zero_rtt_handshake": true,
    "heartbeat": "10s",
    "tls": {
      "enabled": true,
      "alpn": ["h3"],
      "certificate_path": "/etc/sing-box/tuic.crt",
      "key_path": "/etc/sing-box/tuic.key"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

    # systemd 服务
    cat > /etc/systemd/system/sing-box-tuic.service <<EOF
[Unit]
Description=sing-box TUIC Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config-tuic.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务与开放端口
    systemctl daemon-reload
    systemctl enable --now sing-box-tuic >/dev/null 2>&1 || true
    ufw allow $PORT/udp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true

    # 保存节点信息
    TUIC_URL="tuic://$UUID:$PASSWORD@$SERVER_IP:$PORT?alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1&sni=$SNI"
    echo "$TUIC_URL" > /etc/sing-box/tuic_info.txt

    echo ""
    echo "========== TUIC 安装完成 =========="
    echo "连接字符串（复制到客户端）："
    echo "$TUIC_URL"
    echo ""
    echo "注意：自签名证书需客户端开启 allow_insecure=1"
    echo "日志查看：journalctl -u sing-box-tuic -f"
    echo "===================================="
}

# 安装 VLESS + Argo
install_vless_argo() {
    echo "开始安装 VLESS + Argo 节点..."

    apt update -y && apt upgrade -y
    apt install -y curl wget openssl tar

    install_singbox
    enable_bbr

    # 用户输入
    read -p "请输入 Argo 固定域名（例如 xxx.yourdomain.com）： " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo "错误：域名不能为空"
        return 1
    fi
    read -p "请输入 Cloudflare Tunnel Token： " TOKEN
    if [[ -z "$TOKEN" ]]; then
        echo "错误：Token 不能为空"
        return 1
    fi
    read -p "本地监听端口（默认 8080）： " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-8080}

    # 生成 UUID 和 WS Path
    UUID=$(cat /proc/sys/kernel/random/uuid)
    WS_PATH="/$(openssl rand -hex 8)"

    # 安装 cloudflared（最新版）
    echo "正在安装 cloudflared..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)   CF_ARCH="amd64" ;;
        aarch64)  CF_ARCH="arm64" ;;
        *)        echo "错误：不支持的架构 $ARCH" ; exit 1 ;;
    esac
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH} -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    # sing-box 配置
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config-argo.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "127.0.0.1",
    "listen_port": $LOCAL_PORT,
    "users": [{"uuid": "$UUID"}],
    "tls": {"enabled": false},
    "transport": {
      "type": "ws",
      "path": "$WS_PATH"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

    # systemd 服务
    cat > /etc/systemd/system/sing-box-argo.service <<EOF
[Unit]
Description=sing-box VLESS Argo Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config-argo.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token $TOKEN
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 启动
    systemctl daemon-reload
    systemctl enable --now sing-box-argo cloudflared >/dev/null 2>&1

    # 连接字符串
    VLESS_URL="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F${WS_PATH#/}&fp=chrome&sni=$DOMAIN#VLESS-Argo"

    echo "$VLESS_URL" > /etc/sing-box/argo_info.txt

    echo ""
    echo "========== VLESS + Argo 安装完成 =========="
    echo "连接字符串（复制到客户端）："
    echo "$VLESS_URL"
    echo ""
    echo "注意："
    echo "1. 请确保 Cloudflare Zero Trust 已为该 Tunnel 配置公网域名指向 http://127.0.0.1:$LOCAL_PORT"
    echo "2. 日志查看：journalctl -u cloudflared -f 或 journalctl -u sing-box-argo -f"
    echo "========================================="
}

# 查看节点信息
view_nodes() {
    echo "========== TUIC 节点 =========="
    if [[ -f /etc/sing-box/tuic_info.txt ]]; then
        cat /etc/sing-box/tuic_info.txt
        echo "服务状态：$(systemctl is-active sing-box-tuic 2>/dev/null || echo "未运行")"
    else
        echo "未安装 TUIC 节点"
    fi

    echo ""
    echo "========== VLESS + Argo 节点 =========="
    if [[ -f /etc/sing-box/argo_info.txt ]]; then
        cat /etc/sing-box/argo_info.txt
        echo "sing-box 状态：$(systemctl is-active sing-box-argo 2>/dev/null || echo "未运行")"
        echo "cloudflared 状态：$(systemctl is-active cloudflared 2>/dev/null || echo "未运行")"
    else
        echo "未安装 Argo 节点"
    fi
    echo "====================================="
}

# 卸载全部
uninstall_all() {
    echo "正在卸载所有组件..."
    systemctl stop sing-box-tuic sing-box-argo cloudflared >/dev/null 2>&1 || true
    systemctl disable sing-box-tuic sing-box-argo cloudflared >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box-tuic.service \
          /etc/systemd/system/sing-box-argo.service \
          /etc/systemd/system/cloudflared.service
    rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/cloudflared \
           /etc/sysctl.d/99-bbr.conf
    systemctl daemon-reload
    echo "卸载完成（如需关闭防火墙：ufw disable）"
}

# 主菜单
while true; do
    clear
    echo ""
    echo "========== sing-box 节点管理菜单 =========="
    echo "1. 安装 TUIC 节点"
    echo "2. 安装 Argo 节点（VLESS+Argo）"
    echo "3. 查看节点信息"
    echo "4. 卸载全部"
    echo "5. 退出"
    echo "=========================================="
    read -p "请输入选择 [1-5]： " choice
    case $choice in
        1) install_tuic ;;
        2) install_vless_argo ;;
        3) view_nodes ;;
        4) uninstall_all ;;
        5) echo "退出脚本"; exit 0 ;;
        *) echo "无效选择，请重新输入" ; sleep 2 ;;
    esac
    echo ""
    read -p "按回车键继续..." 
done
