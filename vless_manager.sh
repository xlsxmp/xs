#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
CONFIG_FILE="/root/vless-config.txt"

pause() { read -rp "按回车返回菜单..." _; show_menu; }
print_line() { echo -e "${YELLOW}=================================${NC}"; }

# 检查 Xray 配置路径
get_xray_conf() {
    if [ -d "/usr/local/etc/xray" ]; then
        echo "/usr/local/etc/xray/config.json"
    else
        echo "/etc/xray/config.json"
    fi
}

# ================= 菜单 =================
show_menu() {
    clear
    print_line
    echo -e "${YELLOW}==== VLESS 节点管理菜单 ====${NC}"
    echo "1) 安装/重新安装节点"
    echo "2) 查看节点信息"
    echo "3) 查看 Xray / Nginx 状态"
    echo "4) 查看证书状态"
    echo "5) 安装 BBR 加速"
    echo "6) 删除节点并清理环境"
    echo "7) 退出"
    print_line
    read -rp "请选择 (1-7): " choice
    case "$choice" in
        1) install_node ;;
        2) show_node_info ;;
        3) show_services_status ;;
        4) show_cert_status ;;
        5) install_bbr ;;
        6) uninstall_all ;;
        7) exit 0 ;;
        *) echo -e "${RED}输入无效${NC}"; sleep 1; show_menu ;;
    esac
}

# ================= 功能 =================
install_node() {
    echo -e "${YELLOW}=== 开始安装 VLESS 节点 ===${NC}"
    
    read -rp "请输入域名（例如 vps.example.com）: " DOMAIN
    [ -z "$DOMAIN" ] && echo -e "${RED}域名不能为空${NC}" && return
    
    read -rp "请输入 WebSocket 路径（默认 /ws）: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

    read -rp "请输入 UUID（回车自动生成）: " UUID
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid) && echo -e "${GREEN}已生成 UUID: $UUID${NC}"

    echo "证书方式:"
    echo " 1) Cloudflare Origin CA (15年有效)"
    echo " 2) Let’s Encrypt (90天自动续签)"
    read -rp "请选择 (1/2, 默认1): " CHOICE
    CHOICE=${CHOICE:-1}

    # 安装依赖
    echo -e "${YELLOW}更新系统并安装依赖...${NC}"
    apt update -y
    apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip python3-certbot-nginx ufw

    # 安装 Xray
    echo -e "${YELLOW}安装 Xray...${NC}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

    XRAY_CONF=$(get_xray_conf)
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
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    systemctl enable --now xray
    systemctl restart xray

    # ================= 证书 =================
    SSL_CERT=""
    SSL_KEY=""

    if [ "$CHOICE" = "1" ]; then
        echo -e "${YELLOW}使用 Cloudflare API 自动申请 Origin CA 证书...${NC}"
        SSL_CERT="/etc/ssl/$DOMAIN.crt"
        SSL_KEY="/etc/ssl/$DOMAIN.key"

        read -rp "请输入 Cloudflare API Token（推荐，留空则使用 Global API Key）: " CF_API_TOKEN
        if [ -z "$CF_API_TOKEN" ]; then
            read -rp "Cloudflare 邮箱: " CF_EMAIL
            read -rp "Cloudflare Global API Key: " CF_GLOBAL_KEY
            AUTH_HEADER=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY")
        else
            AUTH_HEADER=(-H "Authorization: Bearer $CF_API_TOKEN")
        fi

        response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
          -H "Content-Type: application/json" \
          "${AUTH_HEADER[@]}" \
          --data "{
            \"hostnames\": [\"$DOMAIN\"],
            \"requested_validity\": 5475,
            \"request_type\": \"origin-rsa\"
          }")

        success=$(echo "$response" | jq -r '.success')
        if [ "$success" != "true" ]; then
            echo -e "${RED}申请证书失败！返回信息：$response${NC}"
            exit 1
        fi

        echo "$response" | jq -r '.result.certificate' > "$SSL_CERT"
        echo "$response" | jq -r '.result.private_key' > "$SSL_KEY"
        chmod 644 "$SSL_CERT"
        chmod 600 "$SSL_KEY"

        echo -e "${GREEN}Cloudflare Origin CA 证书申请成功！${NC}"

    else
        echo -e "${YELLOW}使用 Let’s Encrypt 申请证书...${NC}"
        certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN"
        SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        systemctl enable --now certbot.timer
    fi

    # ================= Nginx =================
    WWW="/var/www/html/$DOMAIN"
    mkdir -p "$WWW"
    echo "<!doctype html><html><head><meta charset='utf-8'><title>Welcome</title></head><body><h1>Welcome to $DOMAIN</h1></body></html>" > "$WWW/index.html"

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

    location $WS_PATH {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
NGX

    ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # ================= 防火墙 =================
    ufw allow 80
    ufw allow 443

    # ================= 生成链接 =================
    HIDEPATH_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH', safe=''))")
    VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}#${DOMAIN}"

    cat > "$CONFIG_FILE" <<EOF
域名: $DOMAIN
UUID: $UUID
WebSocket 路径: $WS_PATH
证书: $SSL_CERT
私钥: $SSL_KEY

客户端链接:
$VLESS_URI
EOF

    echo -e "${GREEN}安装完成！配置信息已保存到 $CONFIG_FILE${NC}"
    pause
}

show_node_info() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}未找到配置文件${NC}"
    fi
    pause
}

show_services_status() {
    echo -e "${GREEN}=== Xray 状态 ===${NC}"
    systemctl status xray --no-pager || echo "Xray 未运行"
    echo -e "${GREEN}=== Nginx 状态 ===${NC}"
    systemctl status nginx --no-pager || echo "Nginx 未运行"
    pause
}

show_cert_status() {
    if [ -f "$CONFIG_FILE" ]; then
        SSL_CERT=$(grep '证书:' "$CONFIG_FILE" | awk '{print $2}')
        if [ -f "$SSL_CERT" ]; then
            end_date=$(openssl x509 -enddate -noout -in "$SSL_CERT" | cut -d= -f2)
            end_ts=$(date -d "$end_date" +%s)
            now_ts=$(date +%s)
            days=$(( (end_ts - now_ts) / 86400 ))
            echo -e "${GREEN}证书路径: $SSL_CERT${NC}"
            echo -e "${GREEN}证书有效期至: $end_date (剩余 $days 天)${NC}"
            if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
                echo -e "${YELLOW}Let’s Encrypt 自动续签已启用${NC}"
            else
                echo -e "${YELLOW}Cloudflare Origin CA (无需续签)${NC}"
            fi
        else
            echo -e "${RED}证书未找到或路径错误${NC}"
        fi
    else
        echo -e "${RED}未找到配置文件${NC}"
    fi
    pause
}

install_bbr() {
    echo "开启 BBR..."
    modprobe tcp_bbr || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR 已启用${NC}"
    pause
}

uninstall_all() {
    echo -e "${RED}!!! 警告: 即将删除所有 VLESS 节点配置、Xray、Nginx、证书 !!!${NC}"
    read -rp "确认删除? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        systemctl stop xray nginx || true
        systemctl disable xray nginx || true
        apt purge -y nginx certbot || true
        rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/* /var/www/html/* /etc/letsencrypt /etc/ssl/*.crt /etc/ssl/*.key
        rm -rf "$(get_xray_conf)" /usr/local/etc/xray /etc/xray
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}已清理完成${NC}"
    else
        echo "已取消"
    fi
    pause
}

# 启动菜单
show_menu
