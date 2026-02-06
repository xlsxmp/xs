#!/usr/bin/env bash
# ======================================================
#   Sing-box + VLESS + WS + TLS + Cloudflare Argo (Token)
# ======================================================

UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
SINGBOX_DIR=/etc/sing-box
SINGBOX_BIN=/usr/local/bin/sing-box
SINGBOX_CONF=${SINGBOX_DIR}/config.json
CLOUDFLARED_BIN=/usr/local/bin/cloudflared
ARGO_SERVICE=/etc/systemd/system/argo.service
SINGBOX_SERVICE=/etc/systemd/system/sing-box.service
CDN=IP.SB
PORT=3270
# 随机生成 WS 路径
WS_PATH="/$(head -c 16 /dev/urandom | md5sum | cut -c1-12)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

install_base() {
  apt update -y && apt install -y curl wget unzip jq
}

install_singbox() {
  mkdir -p ${SINGBOX_DIR}
  cd /tmp
  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  wget -qO sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-amd64.tar.gz
  tar -xf sing-box.tar.gz
  mv sing-box-${VER#v}-linux-amd64/sing-box ${SINGBOX_BIN}
  chmod +x ${SINGBOX_BIN}

  if [ ! -f "${SINGBOX_BIN}" ]; then
    echo -e "${RED}❌ Sing-box 安装失败，请检查下载链接或网络${NC}"
    exit 1
  fi
}

generate_singbox_config() {
  cat > ${SINGBOX_CONF} <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

  cat > ${SINGBOX_SERVICE} <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
}

install_cloudflared() {
  wget -qO ${CLOUDFLARED_BIN} https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x ${CLOUDFLARED_BIN}

  if [ ! -f "${CLOUDFLARED_BIN}" ]; then
    echo -e "${RED}❌ Cloudflared 下载失败，请检查网络或 GitHub 是否可访问${NC}"
    exit 1
  fi
}

setup_argo_token() {
  echo -e "${YELLOW}🔹 请输入你的 Cloudflare Argo Token：${NC}"
  read -rp "Argo Token: " ARGO_TOKEN
  echo -e "${YELLOW}🔹 请输入 Argo 隧道绑定域名 (例如 argo.example.com)：${NC}"
  read -rp "Argo 域名: " DOMAIN

  cat > ${ARGO_SERVICE} <<EOF
[Unit]
Description=Cloudflare Argo Tunnel (Token Mode)
After=network.target

[Service]
ExecStart=${CLOUDFLARED_BIN} tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable argo
  systemctl restart argo

  output_info ${DOMAIN}
}

output_info() {
  local DOMAIN=$1
  local INFO_FILE="/etc/sing-box/node_info.txt"
  clear
  echo "==============================================="
  echo "✅ Sing-box + Argo 隧道 (Token模式) 已部署完成"
  echo "-----------------------------------------------"
  echo "VLESS 节点："
  echo
  echo -e "${GREEN}vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox${NC}"
  echo "-----------------------------------------------"
  echo "UUID: ${UUID}"
  echo "回源端口: ${PORT}"
  echo "Argo 域名: ${DOMAIN}"
  echo "配置文件: ${SINGBOX_CONF}"
  echo "-----------------------------------------------"
  echo "系统服务: sing-box, argo"
  echo "==============================================="

  # 写入文本文件
  cat > ${INFO_FILE} <<EOF
VLESS 节点信息
-----------------------------------------------
vless://${UUID}@${CDN}:8443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox
UUID: ${UUID}
回源端口: ${PORT}
Argo 域名: ${DOMAIN}
配置文件: ${SINGBOX_CONF}
系统服务: sing-box, argo
EOF
  echo -e "${GREEN}节点信息已写入 ${INFO_FILE}${NC}"
}

main() {
  install_base
  install_singbox
  generate_singbox_config
  install_cloudflared
  setup_argo_token
}

main
