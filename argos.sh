#!/usr/bin/env bash
# =========================================================
# ArgoSbx 精简增强版（仅适配 Debian 12，中文固定）
# 保留功能：Argo + Sing-box + Nginx + VLESS
# 删除：其他系统判断 / 多语言 / 统计 / reality/vmess/trojan
# =========================================================

set -e

VERSION="LitePlus-2025.10.06"
WORK_DIR="/etc/sba"
TEMP_DIR="/tmp/sba"
NGINX_CONF="/etc/nginx/conf.d/sba.conf"
SINGBOX_BIN="${WORK_DIR}/sing-box"
ARGO_BIN="${WORK_DIR}/cloudflared"
UUID_FILE="${WORK_DIR}/uuid.txt"
INFO_FILE="${WORK_DIR}/vless_info.txt"

# ========================= 基础函数 =========================
color_green(){ echo -e "\e[92m$1\e[0m"; }
color_red(){ echo -e "\e[91m$1\e[0m"; }
color_yellow(){ echo -e "\e[93m$1\e[0m"; }

info(){ color_green "[信息] $1"; }
warn(){ color_yellow "[警告] $1"; }
error(){ color_red "[错误] $1"; exit 1; }

mkdir -p $WORK_DIR $TEMP_DIR

# ========================= 检查环境 =========================
check_root(){
    [[ $EUID -ne 0 ]] && error "请使用 root 用户执行此脚本！"
}
check_system(){
    grep -qi "debian" /etc/os-release || error "此版本仅适配 Debian 12！"
}
check_arch(){
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) error "不支持的架构: $ARCH" ;;
    esac
}

# ========================= 安装依赖 =========================
install_dependencies(){
    info "更新系统并安装依赖..."
    apt update -y
    apt install -y wget curl tar nginx jq qrencode openssl
}

# ========================= 下载核心组件 =========================
download_files(){
    cd $WORK_DIR
    info "下载 Sing-box..."
    wget -qO sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH.tar.gz
    tar -xf sing-box.tar.gz
    mv sing-box*/sing-box $SINGBOX_BIN
    chmod +x $SINGBOX_BIN
    rm -rf sing-box*

    info "下载 Cloudflared..."
    wget -qO $ARGO_BIN https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
    chmod +x $ARGO_BIN
}

# ========================= 用户输入参数 =========================
set_variables(){
    info "请选择 Argo 模式："
    echo "1. 使用 Token"
    echo "2. 使用 JSON"
    echo "3. 临时隧道 (无需认证)"
    read -rp "请选择 [1-3]: " mode
    case $mode in
        1) read -rp "请输入你的 Argo Token: " ARGO_TOKEN ;;
        2) read -rp "请输入你的 Argo JSON 内容（整段）: " ARGO_JSON ;;
        3) info "使用临时隧道，无需认证。" ;;
        *) error "无效选项！" ;;
    esac

    read -rp "请输入 VLESS UUID（留空自动生成）: " UUID
    [[ -z $UUID ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "$UUID" > $UUID_FILE

    read -rp "请输入 WS 路径（默认 /chat）: " WS_PATH
    [[ -z $WS_PATH ]] && WS_PATH="/chat"

    read -rp "请输入绑定域名（Argo 隧道使用）: " DOMAIN
    [[ -z $DOMAIN ]] && DOMAIN="example.com"
}

# ========================= 生成配置文件 =========================
generate_singbox_config(){
cat > $WORK_DIR/config.json <<EOF
{
  "log": {"level": "error"},
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": 8443,
    "users": [{"uuid": "$UUID"}],
    "transport": {"type": "ws", "path": "$WS_PATH"}
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
}

generate_nginx_config(){
cat > $NGINX_CONF <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/certs/sba.crt;
    ssl_certificate_key /etc/ssl/private/sba.key;

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
systemctl restart nginx
}

generate_cert(){
    info "生成自签证书..."
    mkdir -p /etc/ssl/private /etc/ssl/certs
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/ssl/private/sba.key \
        -out /etc/ssl/certs/sba.crt -days 3650 -subj "/CN=$DOMAIN"
}

# ========================= Argo 隧道服务 =========================
generate_argo_service(){
    cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target

[Service]
ExecStart=$ARGO_BIN tunnel --edge-ip-version auto run --url http://localhost:443
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable argo
systemctl restart argo
}

# ========================= Sing-box 服务 =========================
generate_singbox_service(){
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$SINGBOX_BIN run -c $WORK_DIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
}

# ========================= 输出信息 =========================
show_info(){
VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&type=ws&security=tls&host=${DOMAIN}&path=${WS_PATH}#Argo-VLESS"

clear
cat <<EOF
===========================================
✅ 安装完成！

VLESS 节点信息：
-------------------------
地址：$DOMAIN
端口：443
UUID：$UUID
传输协议：ws
路径：$WS_PATH
TLS：开启
完整链接：
$VLESS_URL
-------------------------
配置文件路径：$WORK_DIR/config.json
节点信息已保存到：$INFO_FILE
===========================================
EOF
echo "$VLESS_URL" > $INFO_FILE
qrencode -t ANSIUTF8 "$VLESS_URL"
}

# ========================= 主执行逻辑 =========================
main(){
    check_root
    check_system
    check_arch
    install_dependencies
    download_files
    set_variables
    generate_cert
    generate_singbox_config
    generate_nginx_config
    generate_singbox_service
    generate_argo_service
    show_info
}

main
