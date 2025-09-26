#!/usr/bin/env bash
# Xray VLESS+WS+TLS 一键安装管理脚本 (Debian 12)
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# 根目录检查
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 运行脚本${NC}" && exit 1
fi

# 默认路径
XRAY_CONF="/usr/local/etc/xray/config.json"
SSL_DIR="/etc/ssl/xray"
SSL_CERT="$SSL_DIR/fullchain.cer"
SSL_KEY="$SSL_DIR/private.key"
WWW="/var/www/html"

# 检查依赖
install_dependencies() {
    echo -e "${GREEN}安装系统依赖...${NC}"
    apt update -y
    apt install -y curl wget unzip tar nginx jq python3 python3-pip socat ca-certificates
    # acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh
        source ~/.bashrc
    fi
}

# 安装 Xray
install_xray() {
    echo -e "${GREEN}安装 Xray...${NC}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
    systemctl enable --now xray || true
    systemctl restart xray || true
}

# 写 Xray 配置
write_xray_config() {
    read -p "请输入 VLESS UUID（回车自动生成）: " UUID
    if [ -z "$UUID" ]; then UUID=$(cat /proc/sys/kernel/random/uuid); fi
    read -p "请输入 WebSocket 路径（默认 /ws）: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}
    [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

    mkdir -p "$(dirname "$XRAY_CONF")"
    cat > "$XRAY_CONF" <<EOF
{
  "log": {"access":"/var/log/xray/access.log","error":"/var/log/xray/error.log","loglevel":"warning"},
  "inbounds":[{"port":10000,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"$UUID","level":0}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$WS_PATH"}}}],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
    systemctl restart xray
    echo "$UUID" > /root/xray-uuid.txt
    echo "$WS_PATH" > /root/xray-wspath.txt
}

# 申请/续期 Let’s Encrypt 证书 (Webroot 模式)
le_cert() {
    mkdir -p "$WWW" "$SSL_DIR"
    read -p "请输入域名: " DOMAIN
    certbot certonly --webroot -w "$WWW" -d "$DOMAIN" --email "admin@$DOMAIN" --agree-tos --non-interactive
    ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_CERT"
    ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_KEY"
}

# Cloudflare Origin CA 证书
cf_cert() {
    mkdir -p "$SSL_DIR"
    read -p "请输入域名: " DOMAIN
    read -p "请输入 Cloudflare API Token（回车跳过）: " CF_API_TOKEN
    if [ -n "$CF_API_TOKEN" ]; then
        AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" -H "$AUTH_HEADER" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
    else
        read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
        read -p "请输入 Global API Key: " CF_KEY
        APEX=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$APEX&status=active" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
    fi
    BODY=$(jq -n --arg hn "$DOMAIN" '{ "hostnames": [$hn], "request_type":"origin-rsa", "requested_validity":5475 }')
    if [ -n "$CF_API_TOKEN" ]; then
        RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "$AUTH_HEADER" -H "Content-Type: application/json" --data "$BODY")
    else
        RESP=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/certificates" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" --data "$BODY")
    fi
    CERT=$(echo "$RESP" | jq -r '.result.certificate')
    KEY=$(echo "$RESP" | jq -r '.result.private_key')
    echo "$CERT" > "$SSL_CERT"
    echo "$KEY" > "$SSL_KEY"
    chmod 600 "$SSL_KEY"
    systemctl restart xray nginx
}

# Nginx 配置
nginx_conf() {
    read -p "请输入域名: " DOMAIN
    read -p "请输入 WebSocket 路径（默认 /ws）: " WS_PATH
    WS_PATH=${WS_PATH:-/ws}; [[ "${WS_PATH:0:1}" != "/" ]] && WS_PATH="/$WS_PATH"

    mkdir -p "$WWW"
    cat > "$WWW/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body style="font-family:Arial,Helvetica,sans-serif;padding:40px;">
<h1>Welcome to $DOMAIN</h1><p>This is a static page.</p></body></html>
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
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    server_tokens off;

    root $WWW;
    index index.html;

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
    }

    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
NGX

    ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/
    nginx -t
    systemctl restart nginx
}

# 查看证书状态
check_cert() {
    if [ ! -f "$SSL_CERT" ]; then echo -e "${RED}证书不存在${NC}"; return; fi
    end_time=$(openssl x509 -enddate -noout -in "$SSL_CERT" | cut -d= -f2)
    end_ts=$(date -d "$end_time" +%s)
    now_ts=$(date +%s)
    echo -e "${GREEN}证书到期时间：$end_time${NC}"
    if [ $now_ts -ge $end_ts ]; then
        echo -e "${RED}证书已过期！${NC}"
    fi
}

# BBR 加速
enable_bbr() {
    echo -e "${YELLOW}启用 TCP BBR 加速...${NC}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR 启用成功${NC}"
    else
        echo -e "${RED}BBR 启用失败${NC}"
    fi
}

# 节点信息
show_node_info() {
    UUID=$(cat /root/xray-uuid.txt 2>/dev/null)
    WS_PATH=$(cat /root/xray-wspath.txt 2>/dev/null)
    DOMAIN=$(grep server_name /etc/nginx/sites-enabled/* | head -1 | awk '{print $2}')
    HIDEPATH_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH', safe=''))")
    echo -e "${GREEN}=== 节点信息 ===${NC}"
    echo "域名: $DOMAIN"
    echo "UUID: $UUID"
    echo "WebSocket 路径: $WS_PATH"
    echo "VLESS URI: vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$HIDEPATH_ESCAPED#$DOMAIN"
}

# Xray / Nginx 状态
show_service_status() {
    systemctl status xray --no-pager
    systemctl status nginx --no-pager
}

# 删除节点
delete_all() {
    systemctl stop xray nginx
    systemctl disable xray nginx
    rm -rf "$XRAY_CONF" "$SSL_DIR" /etc/nginx/sites-available/* /etc/nginx/sites-enabled/* "$WWW"
    echo -e "${GREEN}已删除节点相关文件${NC}"
}

# 主菜单
while true; do
cat <<MENU
======== Xray 管理菜单 ========
1) 安装依赖
2) 安装 Xray
3) 写入 Xray 配置
4) Let’s Encrypt 证书
5) Cloudflare Origin CA 证书
6) Nginx 配置
7) 查看证书状态
8) 查看节点信息
9) 查看 Xray/Nginx 状态
10) 启用 BBR 加速
11) 删除节点
0) 退出
=============================
MENU
read -p "请选择 [0-11]: " CHOICE
case "$CHOICE" in
1) install_dependencies ;;
2) install_xray ;;
3) write_xray_config ;;
4) le_cert ;;
5) cf_cert ;;
6) nginx_conf ;;
7) check_cert ;;
8) show_node_info ;;
9) show_service_status ;;
10) enable_bbr ;;
11) delete_all ;;
0) exit 0 ;;
*) echo -e "${RED}无效选项${NC}" ;;
esac
done
