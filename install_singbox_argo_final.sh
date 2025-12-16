#!/usr/bin/env bash
# ======================================================
#  Sing-box + VLESS + WS + TLS + Cloudflare Argo (Token)
#  Final Optimized Production Script
#  OS: Debian / Ubuntu / RHEL
# ======================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------ 基础变量 ------------------
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"

SINGBOX_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF="${SINGBOX_DIR}/config.json"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
ARGO_SERVICE="/etc/systemd/system/argo.service"

INFO_FILE="/etc/sing-box/node_info.txt"

# Cloudflare CDN 占位地址（勿改为真实 IP）
CDN="www.visa.com.sg"

PORT=3270
WS_PATH="/$(head -c 16 /dev/urandom | md5sum | cut -c1-8)"

# ------------------ 颜色 ------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ------------------ 架构检测 ------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    SB_ARCH="amd64"
    CF_ARCH="amd64"
    ;;
  aarch64)
    SB_ARCH="arm64"
    CF_ARCH="arm64"
    ;;
  *)
    echo -e "${RED}Unsupported architecture: ${ARCH}${NC}"
    exit 1
    ;;
esac

# ------------------ 权限检测 ------------------
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
  fi
}

# ------------------ 端口检测 ------------------
check_port() {
  if ss -lnt | grep -q ":${PORT} "; then
    echo -e "${RED}Port ${PORT} is already in use.${NC}"
    exit 1
  fi
}

# ------------------ 依赖安装 ------------------
install_base() {
  if command -v apt &>/dev/null; then
    apt update -y
    apt install -y curl wget unzip jq
  elif command -v yum &>/dev/null; then
    yum install -y curl wget unzip jq
  else
    echo -e "${RED}Unsupported package manager.${NC}"
    exit 1
  fi
}

# ------------------ 安装 sing-box ------------------
install_singbox() {
  echo -e "${YELLOW}Installing sing-box...${NC}"
  mkdir -p "${SINGBOX_DIR}"
  cd /tmp

  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  [ -z "$VER" ] || [ "$VER" = "null" ] && {
    echo -e "${RED}Failed to fetch sing-box version.${NC}"
    exit 1
  }

  wget -qO sing-box.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-${SB_ARCH}.tar.gz"

  tar -xf sing-box.tar.gz
  mv sing-box*linux*/sing-box "${SINGBOX_BIN}"
  chmod +x "${SINGBOX_BIN}"
  rm -rf sing-box*
}

# ------------------ sing-box 配置 ------------------
generate_singbox_config() {
  echo -e "${YELLOW}Configuring sing-box...${NC}"

  cat > "${SINGBOX_CONF}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "tls": {
        "enabled": false
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  cat > "${SINGBOX_SERVICE}" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=always
RestartSec=2
LimitNOFILE=1048576
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
}

# ------------------ 安装 cloudflared ------------------
install_cloudflared() {
  echo -e "${YELLOW}Installing cloudflared...${NC}"
  wget -qO "${CLOUDFLARED_BIN}" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  chmod +x "${CLOUDFLARED_BIN}"
}

# ------------------ Argo Token ------------------
setup_argo() {
  echo -e "${YELLOW}Enter Cloudflare Argo Token:${NC}"
  read -rp "Token: " ARGO_TOKEN
  [ -z "$ARGO_TOKEN" ] && { echo "Token cannot be empty"; exit 1; }

  echo -e "${YELLOW}Enter bound domain (e.g. argo.example.com):${NC}"
  read -rp "Domain: " DOMAIN
  [ -z "$DOMAIN" ] && { echo "Domain cannot be empty"; exit 1; }

  cat > "${ARGO_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
ExecStart=${CLOUDFLARED_BIN} tunnel run --edge-ip-version auto --token ${ARGO_TOKEN}
Restart=always
RestartSec=5
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable argo
  systemctl restart argo

  output_info "${DOMAIN}"
}

# ------------------ 输出信息 ------------------
output_info() {
  local DOMAIN="$1"

  local LINK="vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#${DOMAIN}-ARGO"

  clear
  echo "================================================="
  echo -e " ${GREEN}Sing-box + Argo Deployment Completed${NC}"
  echo "================================================="
  echo
  echo "VLESS Link:"
  echo "${LINK}"
  echo
  echo "UUID       : ${UUID}"
  echo "WS Path    : ${WS_PATH}"
  echo "Local Port : ${PORT}"
  echo "Domain     : ${DOMAIN}"
  echo
  echo "Argo Public Hostname -> http://localhost:${PORT}"
  echo "================================================="

  cat > "${INFO_FILE}" <<EOF
${LINK}

UUID: ${UUID}
Path: ${WS_PATH}
Domain: ${DOMAIN}
Local Port: ${PORT}
EOF
}

# ------------------ 主流程 ------------------
main() {
  check_root
  check_port
  install_base
  install_singbox
  generate_singbox_config
  install_cloudflared
  setup_argo
}

main
