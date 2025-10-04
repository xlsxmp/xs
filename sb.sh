#!/bin/bash

# ===============================
# sing-box + Vmess WS + Argo 安装脚本
# 自动 UUID，官方 sing-box，交互式
# 支持 Argo 隧道 & 开机自启
# ===============================

# 颜色定义
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

USERNAME=$(whoami)
WORKDIR="/home/${USERNAME}/.singbox"
[ -d "$WORKDIR" ] || mkdir -p "$WORKDIR"

# 自动生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
green "生成 UUID: $UUID"

# -------------------------
read_vmess_port() {
    while true; do
        reading "请输入 Vmess 端口 (1-65535): " vmess_port
        if [[ "$vmess_port" =~ ^[0-9]+$ ]] && [ "$vmess_port" -ge 1 ] && [ "$vmess_port" -le 65535 ]; then
            green "Vmess 端口设置为: $vmess_port"
            break
        else
            yellow "输入无效，请重新输入端口"
        fi
    done
}

# -------------------------
argo_configure() {
  reading "是否使用固定 Argo 隧道？【y/n】: " argo_choice
  if [[ "$argo_choice" != [Yy] ]]; then
      green "使用临时 Argo 隧道"
      ARGO_DOMAIN=""
      ARGO_AUTH=""
      return
  fi

  while [[ -z $ARGO_DOMAIN ]]; do
      reading "请输入 Argo 固定隧道域名: " ARGO_DOMAIN
  done
  while [[ -z $ARGO_AUTH ]]; do
      reading "请输入 Argo 隧道凭证 JSON 或 Token: " ARGO_AUTH
  done

  # 写凭证文件
  TUNNEL_DIR="$WORKDIR/argo"
  mkdir -p "$TUNNEL_DIR"
  echo "$ARGO_AUTH" > "$TUNNEL_DIR/tunnel.json"
  chmod 600 "$TUNNEL_DIR/tunnel.json"

  # 生成 tunnel.yml
  TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -o '"TunnelSecret":[^"]*' | cut -d':' -f2 | tr -d '"')
  cat > "$TUNNEL_DIR/tunnel.yml" << EOF
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_DIR/tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$vmess_port
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

  # 创建 cloudflared systemd 服务
  cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflared Tunnel
After=network.target

[Service]
ExecStart=$WORKDIR/bot tunnel --config $TUNNEL_DIR/tunnel.yml run
Restart=always
User=$USERNAME
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared
  green "Argo 隧道已配置并启动"
}

# -------------------------
download_singbox() {
  ARCH=$(uname -m)
  DOWNLOAD_DIR="$WORKDIR"
  mkdir -p "$DOWNLOAD_DIR"
  if [[ "$ARCH" =~ arm|aarch64 ]]; then
      URL_WEB="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-arm64"
      URL_BOT="https://github.com/SagerNet/sing-box/releases/latest/download/cloudflared-linux-arm64"
  else
      URL_WEB="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64"
      URL_BOT="https://github.com/SagerNet/sing-box/releases/latest/download/cloudflared-linux-amd64"
  fi

  wget -q -O "$DOWNLOAD_DIR/web" "$URL_WEB"
  wget -q -O "$DOWNLOAD_DIR/bot" "$URL_BOT"
  chmod +x "$DOWNLOAD_DIR/web" "$DOWNLOAD_DIR/bot"
  green "官方 sing-box 文件下载完成"
}

# -------------------------
generate_config() {
cat > "$WORKDIR/config.json" << EOF
{
  "log": {"disabled": true,"level": "info","timestamp": true},
  "inbounds": [
    {
      "tag": "vmess-ws-in",
      "type": "vmess",
      "listen": "::",
      "listen_port": $vmess_port,
      "users": [{"uuid": "$UUID"}],
      "transport": {"type":"ws","path":"/vmess","early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  ],
  "outbounds": [{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]
}
EOF
  green "Vmess 配置生成完成"
}

# -------------------------
create_singbox_service() {
  # systemd 服务
  cat >/etc/systemd/system/singbox.service <<EOF
[Unit]
Description=Sing-box Vmess WS
After=network.target

[Service]
ExecStart=$WORKDIR/web run -c $WORKDIR/config.json
Restart=always
User=$USERNAME
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now singbox
  green "sing-box systemd 服务已创建并启动"
}

# -------------------------
run_sb() {
  nohup "$WORKDIR/web" run -c "$WORKDIR/config.json" >/dev/null 2>&1 &
  sleep 2
  if [[ -n $ARGO_DOMAIN && -n $ARGO_AUTH ]]; then
      systemctl restart cloudflared
  fi
  create_singbox_service
}

# -------------------------
get_links() {
  if [[ -n $ARGO_DOMAIN ]]; then
      ARGO_URL="$ARGO_DOMAIN"
  else
      ARGO_URL=$(grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' "$WORKDIR/boot.log" | head -1 | sed 's@https://@@')
  fi

  IP=$(curl -s ipv4.ip.sb || echo "127.0.0.1")
  ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed 's/ /_/g')

  cat > "$WORKDIR/list.txt" << EOF
vmess://$(echo "{ \"v\": \"2\", \"ps\": \"$ISP\", \"add\": \"$IP\", \"port\": \"$vmess_port\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"\", \"path\": \"/vmess?ed=2048\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"$ISP Argo\", \"add\": \"$ARGO_URL\", \"port\": \"443\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_URL\", \"path\": \"/vmess?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_URL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
EOF

  cat "$WORKDIR/list.txt"
  green "节点信息生成完成 -> $WORKDIR/list.txt"
}

# -------------------------
install_singbox() {
    read_vmess_port
    argo_configure
    download_singbox
    generate_config
    run_sb
    get_links
    green "安装完成"
}

# -------------------------
uninstall_singbox() {
    reading "确定要卸载 sing-box 并删除所有配置吗？【y/n】: " choice
    [[ "$choice" != [Yy] ]] && return
    pkill -f web
    systemctl stop singbox cloudflared >/dev/null 2>&1
    systemctl disable singbox cloudflared >/dev/null 2>&1
    rm -rf "$WORKDIR"
    rm -f /etc/systemd/system/singbox.service /etc/systemd/system/cloudflared.service
    systemctl daemon-reload
    green "sing-box 与 Argo 隧道已卸载并清理完毕"
}

# -------------------------
kill_all_tasks() {
    reading "清理所有 sing-box 和 Argo 相关进程，将退出 SSH 连接？【y/n】: " choice
    [[ "$choice" != [Yy] ]] && return
    pkill -f web
    pkill -f bot
    green "已清理所有 sing-box 和 Argo 进程"
}

# -------------------------
menu() {
   clear
   purple "=== sing-box + Vmess WS + Argo 一键安装 ==="
   green "1. 安装 sing-box"
   red "2. 卸载 sing-box"
   green "3. 查看节点信息"
   yellow "4. 清理所有进程"
   red "0. 退出脚本"
   reading "请输入选择(0-4): " choice
   case "$choice" in
       1) install_singbox ;;
       2) uninstall_singbox ;;
       3) cat "$WORKDIR/list.txt" ;;
       4) kill_all_tasks ;;
       0) exit 0 ;;
       *) red "无效选项" ;;
   esac
}

menu
