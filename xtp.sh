#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
CONFIG_FILE="/root/vless-config.txt"

pause() { read -rp "按回车返回菜单..." _; show_menu; }
print_line() { echo -e "${YELLOW}=================================${NC}"; }

# 自动判断 Xray 配置路径
get_xray_conf() {
    if [ -d "/usr/local/etc/xray" ]; then
        echo "/usr/local/etc/xray/config.json"
    else
        echo "/etc/xray/config.json"
    fi
}

# 显示主菜单
show_menu() {
    clear
    print_line
    echo -e "${YELLOW}==== VLESS 一键管理脚本 ====${NC}"
    echo "1) 安装/重新安装节点 (WS 或 XHTTP)"
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

# 安装主流程
install_node() {
    echo -e "${YELLOW}=== 开始安装 VLESS 节点 ===${NC}"

    read -rp "请输入域名（例如 vps.example.com）: " DOMAIN
    [ -z "$DOMAIN" ] && echo -e "${RED}域名不能为空${NC}" && return

    echo "请选择传输协议："
    echo " 1) VLESS + WS (WebSocket)"
    echo " 2) VLESS + XHTTP (更隐蔽，走 HTTP/2/HTTP/3 流)"
    read -rp "选择 (1/2, 默认1): " PROTO
    PROTO=${PROTO:-1}

    read -rp "请输入路径（例如 /ws 或 /xhttp，回车默认 /xhttp for XHTTP, /ws for WS）: " HIDEPATH
    if [ -z "$HIDEPATH" ]; then
        if [ "$PROTO" = "2" ]; then
            HIDEPATH="/xhttp"
        else
            HIDEPATH="/ws"
        fi
    fi
    [[ "${HIDEPATH:0:1}" != "/" ]] && HIDEPATH="/$HIDEPATH"

    read -rp "请输入 UUID（回车自动生成）: " UUID
    if [ -z "$UUID" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo -e "${GREEN}已生成 UUID: $UUID${NC}"
    fi

    echo "证书方式:"
    echo " 1) Cloudflare Origin CA (通过 API 自动申请，15 年)"
    echo " 2) Let’s Encrypt (certbot, 90 天，自动续签)"
    read -rp "请选择 (1/2, 默认1): " CHOICE
    CHOICE=${CHOICE:-1}

    echo -e "${YELLOW}更新系统并安装必要依赖...${NC}"
    apt update -y
    apt install -y curl wget unzip nginx jq ca-certificates socat python3 python3-pip python3-certbot-nginx ufw

    # 安装 Xray（官方安装脚本）
    echo -e "${YELLOW}安装 Xray...${NC}"
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || {
        echo -e "${RED}Xray 安装失败，请检查网络或手动安装${NC}"; pause; return
    }

    XRAY_CONF=$(get_xray_conf)
    mkdir -p "$(dirname "$XRAY_CONF")"

    # 写入 Xray 配置
    if [ "$PROTO" = "2" ]; then
        # XHTTP (network http)
        cat > "$XRAY_CONF" <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "level": 0 } ], "decryption": "none" },
      "streamSettings": {
        "network": "http",
        "httpSettings": {
          "path": "$HIDEPATH"
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    else
        # WebSocket
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
    fi

    systemctl enable --now xray
    systemctl restart xray

    # ======== 证书申请（Cloudflare Origin CA 自动或 Let's Encrypt） ========
    SSL_CERT=""
    SSL_KEY=""

    if [ "$CHOICE" = "1" ]; then
        echo -e "${YELLOW}使用 Cloudflare API 自动申请 Origin CA 证书...${NC}"
        SSL_CERT="/etc/ssl/$DOMAIN.crt"
        SSL_KEY="/etc/ssl/$DOMAIN.key"

        read -rp "请输入 Cloudflare API Token（推荐，留空则使用 Global API Key）: " CF_API_TOKEN
        if [ -z "$CF_API_TOKEN" ]; then
            read -rp "请输入 Cloudflare 注册邮箱 (X-Auth-Email): " CF_EMAIL
            read -rp "请输入 Cloudflare Global API Key (X-Auth-Key): " CF_GLOBAL_KEY
            # 组装 auth headers
            AUTH_HEADER=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY")
        else
            AUTH_HEADER=(-H "Authorization: Bearer $CF_API_TOKEN")
        fi

        # 调用 Cloudflare API 创建 Origin Certificate（注意：CF API 可能会随时间调整，若失败会回显错误）
        response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
          -H "Content-Type: application/json" \
          "${AUTH_HEADER[@]}" \
          --data "{
            \"hostnames\": [\"$DOMAIN\"],
            \"requested_validity\": 5475,
            \"request_type\": \"origin-rsa\"
          }")

        success=$(echo "$response" | jq -r '.success' 2>/dev/null || echo "false")
        if [ "$success" != "true" ]; then
            echo -e "${RED}Cloudflare 申请 Origin CA 证书失败！返回信息:${NC}"
            echo "$response" | sed -n '1,200p'
            echo -e "${YELLOW}请检查 API Token/Global Key 是否正确或手动在 Cloudflare 面板创建 Origin CA 并上传到服务器${NC}"
            pause
            return
        fi

        echo "$response" | jq -r '.result.certificate' > "$SSL_CERT"
        echo "$response" | jq -r '.result.private_key' > "$SSL_KEY"
        chmod 644 "$SSL_CERT"
        chmod 600 "$SSL_KEY"
        echo -e "${GREEN}Cloudflare Origin CA 证书申请成功，保存在：${SSL_CERT} & ${SSL_KEY}${NC}"

    else
        echo -e "${YELLOW}使用 Let’s Encrypt (certbot) 申请证书...${NC}"
        # 准备简单伪装站点以便 HTTP 验证
        WWW="/var/www/html/$DOMAIN"
        mkdir -p "$WWW"
        echo "<!doctype html><html><head><meta charset='utf-8'><title>Welcome</title></head><body><h1>Welcome to $DOMAIN</h1></body></html>" > "$WWW/index.html"

        # 临时 nginx 配置，覆盖或创建用于 ACME challenge
        NGX_CHK="/etc/nginx/sites-available/$DOMAIN-acme-check"
        cat > "$NGX_CHK" <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    root $WWW;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
NGX
        ln -sf "$NGX_CHK" /etc/nginx/sites-enabled/
        nginx -t && systemctl restart nginx

        # 请求证书
        certbot -n --nginx -d "$DOMAIN" --agree-tos --email "admin@$DOMAIN" || {
            echo -e "${RED}certbot 签发失败，请检查域名解析是否指向本 VPS，并且 80 端口可访问${NC}"; pause; return
        }

        SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        systemctl enable --now certbot.timer
        echo -e "${GREEN}Let’s Encrypt 证书申请成功并启用自动续签（certbot.timer）${NC}"
    fi

    # ======== Nginx 配置 (伪装站 + 反代到 Xray) ========
    WWW="/var/www/html/$DOMAIN"
    mkdir -p "$WWW"
    # 可自定义伪装页面
    cat > "$WWW/index.html" <<HTML
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome to $DOMAIN</h1><p>deployed by vless-installer</p></body>
</html>
HTML

    NGX_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [ "$PROTO" = "2" ]; then
        # XHTTP: 不需要 upgrade 头
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX
    else
        # WS: 需要 upgrade
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
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX
    fi

    ln -sf "$NGX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx

    # ======== 防火墙 放行 ========
    ufw allow 80 || true
    ufw allow 443 || true

    # ======== 生成客户端 URI =========
    HIDEPATH_ESCAPED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$HIDEPATH', safe=''))")
    if [ "$PROTO" = "2" ]; then
        VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=http&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}#${DOMAIN}-xhttp"
    else
        VLESS_URI="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${HIDEPATH_ESCAPED}#${DOMAIN}-ws"
    fi

    cat > "$CONFIG_FILE" <<EOF
域名: $DOMAIN
UUID: $UUID
传输协议: $( [ "$PROTO" = "2" ] && echo "VLESS+XHTTP" || echo "VLESS+WS" )
路径: $HIDEPATH
证书: $SSL_CERT
私钥: $SSL_KEY

客户端链接:
$VLESS_URI

备注:
- 若使用 Cloudflare，请将 DNS A 记录指向你的 VPS，并将代理 (橙云) 打开以隐藏源 IP。
- Cloudflare Origin CA 为长效证书 (15 年)，Let’s Encrypt 会自动续签（certbot.timer）。
EOF

    echo -e "${GREEN}安装完成！配置信息已保存到 ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}客户端链接:${NC}\n$VLESS_URI"
    pause
}

# 展示节点信息
show_node_info() {
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}未找到配置文件：${CONFIG_FILE}${NC}"
    fi
    pause
}

# 服务状态
show_services_status() {
    echo -e "${GREEN}=== Xray 状态 ===${NC}"
    systemctl status xray --no-pager || echo "Xray 未运行"
    echo -e "${GREEN}=== Nginx 状态 ===${NC}"
    systemctl status nginx --no-pager || echo "Nginx 未运行"
    echo -e "${GREEN}=== Certbot Timer 状态 ===${NC}"
    systemctl status certbot.timer --no-pager || echo "certbot.timer 未启用或不存在"
    pause
}

# 证书状态与剩余天数
show_cert_status() {
    if [ -f "$CONFIG_FILE" ]; then
        SSL_CERT=$(grep '^证书:' "$CONFIG_FILE" | awk -F': ' '{print $2}' || true)
        if [ -n "$SSL_CERT" ] && [ -f "$SSL_CERT" ]; then
            end_date=$(openssl x509 -enddate -noout -in "$SSL_CERT" | cut -d= -f2)
            end_ts=$(date -d "$end_date" +%s)
            now_ts=$(date +%s)
            days=$(( (end_ts - now_ts) / 86400 ))
            echo -e "${GREEN}证书路径: $SSL_CERT${NC}"
            echo -e "${GREEN}证书有效期至: $end_date (剩余 $days 天)${NC}"
            if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
                echo -e "${YELLOW}Let’s Encrypt 自动续签已启用 (certbot.timer)${NC}"
            else
                echo -e "${YELLOW}如果是 Cloudflare Origin CA 则通常无需续签（15 年）。若为 Let’s Encrypt 请检查 certbot.timer。${NC}"
            fi
        else
            echo -e "${RED}证书未找到或路径错误：$SSL_CERT${NC}"
        fi
    else
        echo -e "${RED}未找到配置文件${NC}"
    fi
    pause
}

# 启用 BBR
install_bbr() {
    echo "开启 BBR..."
    modprobe tcp_bbr || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    sysctl -w net.core.default_qdisc=fq
    sysctl -w net.ipv4.tcp_congestion_control=bbr
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p || true
    echo -e "${GREEN}BBR 已启用（如内核支持）${NC}"
    pause
}

# 卸载与清理
uninstall_all() {
    echo -e "${RED}!!! 警告: 即将删除所有 VLESS 配置、Xray、Nginx、证书 !!!${NC}"
    read -rp "确认删除? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        systemctl stop xray nginx || true
        systemctl disable xray nginx || true
        apt purge -y nginx certbot || true
        rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/* /var/www/html/* /etc/letsencrypt /etc/ssl/*.crt /etc/ssl/*.key
        rm -rf "$(get_xray_conf)" /usr/local/etc/xray /etc/xray || true
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}已清理完成${NC}"
    else
        echo "已取消"
    fi
    pause
}

# 启动菜单
show_menu
