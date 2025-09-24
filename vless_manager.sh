#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

CONFIG_FILE="/root/vless-config.txt"

# 菜单
show_menu() {
    echo -e "${YELLOW}==== VLESS 节点管理菜单 ====${NC}"
    echo "1) 安装/重新安装节点"
    echo "2) 查看节点信息"
    echo "3) 查看 Xray / Nginx 状态"
    echo "4) 查看证书状态"
    echo "5) 退出"
    read -p "请选择 (1-5): " choice
    case "$choice" in
        1) install_node ;;
        2) show_node_info ;;
        3) show_services_status ;;
        4) show_cert_status ;;
        5) exit 0 ;;
        *) echo -e "${RED}输入无效${NC}"; show_menu ;;
    esac
}

# 安装/重新安装节点
install_node() {
    echo -e "${YELLOW}=== 开始安装 VLESS 节点 ===${NC}"
    
    read -p "请输入域名（例如 vps.example.com）: " DOMAIN
    [ -z "$DOMAIN" ] && echo -e "${RED}域名不能为空${NC}" && return
    
    read -p "请输入 WebSocket 路径（默认 /ws）: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

    read -p "请输入 UUID（回车自动生成）: " UUID
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid) && echo -e "${GREEN}已生成 UUID: $UUID${NC}"

    echo "证书方式:"
    echo " 1) Cloudflare Origin CA"
    echo " 2) Let’s Encrypt (http 验证)"
    read -p "请选择 (1/2, 默认1): " CHOICE
    CHOICE=${CHOICE:-1}

    if [ "$CHOICE" = "1" ]; then
        read -p "请输入 Cloudflare API Token（回车跳过）: " CF_API_TOKEN
        if [ -z "${CF_API_TOKEN}" ]; then
            read -p "Cloudflare 邮箱（回车跳过）: " CF_EMAIL
            read -p "Cloudflare Global API Key（回车跳过）: " CF_GLOBAL_KEY
        fi
    fi

    echo -e "${YELLOW}更新系统并安装依赖...${NC}"
    apt update -y
    apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip python3-certbot-nginx

    echo -e "${YELLOW}安装 Xray...${NC}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

    HIDEPATH="$WS_PATH"
    XRAY_CONF="/usr/local/etc/xray/config.json"
    mkdir -p "$(dirname "$XRAY_CONF")"

    cat > "$XRAY_CONF" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "level": 0 } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$HIDEPATH" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    systemctl enable --now xray
    systemctl restart xray

    SSL_CERT=""
    SSL_KEY=""

    if [ "$CHOICE" = "1" ]; then
        echo -e "${YELLOW}申请 Cloudflare Origin CA 证书...${NC}"
        SSL_CERT="/etc/ssl/$DOMAIN.crt"
        SSL_KEY="/etc/ssl/$DOMAIN.key"
        # 此处省略自动 API 获取证书逻辑，可手动上传 Cloudflare Origin CA 证书
        echo "请将 Cloudflare Origin CA 证书保存到 $SSL_CERT"
        echo "私钥保存到 $SSL_KEY"
        chmod 600 "$SSL_KEY"
    else
        echo -e "${YELLOW}使用 Let’s Encrypt 申请证书...${NC}"
        certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN"
        SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    fi

    # Nginx 配置
    WWW="/var/www/html"
    mkdir -p "$WWW"
    cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome to $DOMAIN</h1></body></html>
HTML

    NGX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGX_CONF" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WWW; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WWW;
    index index.html;

    location $HIDEPATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
NGX

    ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/
    nginx -t
    systemctl restart nginx

    HIDEPATH_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$HIDEPATH', safe=''))")
    VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}#${DOMAIN}"

    cat > "$CONFIG_FILE" <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $HIDEPATH
证书: $SSL_CERT
私钥: $SSL_KEY

客户端链接:
$VLESS_URI
EOF

    echo -e "${GREEN}安装完成！配置信息已保存到 $CONFIG_FILE${NC}"
    read -p "按回车返回菜单..."
    show_menu
}

# 查看节点信息
show_node_info() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}未找到配置文件${NC}"
    fi
    read -p "按回车返回菜单..."
    show_menu
}

# 查看服务状态
show_services_status() {
    echo -e "${GREEN}=== Xray 状态 ===${NC}"
    systemctl status xray --no-pager || echo "Xray 未运行"
    echo -e "${GREEN}=== Nginx 状态 ===${NC}"
    systemctl status nginx --no-pager || echo "Nginx 未运行"
    read -p "按回车返回菜单..."
    show_menu
}

# 查看证书状态
show_cert_status() {
    if [ -f "$CONFIG_FILE" ]; then
        SSL_CERT=$(grep '证书:' "$CONFIG_FILE" | awk '{print $2}')
        if [ -f "$SSL_CERT" ]; then
            echo -e "${GREEN}证书路径: $SSL_CERT${NC}"
            echo -e "${GREEN}证书到期时间: $(openssl x509 -enddate -noout -in $SSL_CERT | cut -d= -f2)${NC}"
        else
            echo -e "${RED}证书未找到或路径错误${NC}"
        fi
    else
        echo -e "${RED}未找到配置文件${NC}"
    fi
    read -p "按回车返回菜单..."
    show_menu
}

# 启动菜单
show_menu
