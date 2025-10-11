#!/usr/bin/env bash
# ======================================================
#   Sing-box + VLESS + WS + TLS + Cloudflare Argo 一体化脚本
# ======================================================

set -euo pipefail

# ---------- 基础变量 ----------
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
SINGBOX_DIR=/etc/sing-box
SINGBOX_BIN=/usr/local/bin/sing-box
SINGBOX_CONF=${SINGBOX_DIR}/config.json
CLOUDFLARED_BIN=/usr/local/bin/cloudflared
ARGO_SERVICE=/etc/systemd/system/argo.service
SINGBOX_SERVICE=/etc/systemd/system/sing-box.service
CDN=IP.SB
PORT=3270
WS_PATH="/svwtca-$(date +%m%d%H%M)"
BACKUP_DIR=/root
TS=$(date +%F_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_singbox_argo_${TS}.tar.gz"

# ---------- 颜色定义 ----------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

# ---------- 安装依赖 ----------
install_base() {
  echo -e "${YELLOW}🔧 安装依赖中...${RESET}"
  apt update -y && apt install -y curl wget unzip jq >/dev/null 2>&1
}

# ---------- 安装 sing-box ----------
install_singbox() {
  echo -e "${YELLOW}⬇️  安装 Sing-box...${RESET}"
  mkdir -p ${SINGBOX_DIR}
  cd /tmp
  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  wget -qO sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-amd64.tar.gz
  tar -xf sing-box.tar.gz
  mv sing-box-${VER#v}-linux-amd64/sing-box ${SINGBOX_BIN}
  chmod +x ${SINGBOX_BIN}
}

# ---------- 生成配置 ----------
generate_singbox_config() {
  echo -e "${YELLOW}⚙️  生成 Sing-box 配置...${RESET}"
  cat > ${SINGBOX_CONF} <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${PORT},
      "users": [{ "uuid": "${UUID}" }],
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

# ---------- 安装 cloudflared ----------
install_cloudflared() {
  echo -e "${YELLOW}☁️  安装 Cloudflare Argo...${RESET}"
  wget -qO ${CLOUDFLARED_BIN} https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x ${CLOUDFLARED_BIN}
}

# ---------- 配置 Argo Token 模式 ----------
setup_argo_token() {
  echo -e "${YELLOW}🔹 请输入你的 Cloudflare Argo Token：${RESET}"
  read -rp "Argo Token: " ARGO_TOKEN
  echo -e "${YELLOW}🔹 请输入 Argo 隧道绑定域名 (例如 argo.example.com)：${RESET}"
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

# ---------- 输出节点信息 ----------
output_info() {
  local DOMAIN=$1
  clear
  echo -e "${GREEN}==============================================="
  echo "✅ Sing-box + Argo 已部署完成"
  echo "-----------------------------------------------"
  echo "VLESS 节点："
  echo
  echo "vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox"
  echo "-----------------------------------------------"
  echo "UUID: ${UUID}"
  echo "回源端口: ${PORT}"
  echo "Argo 域名: ${DOMAIN}"
  echo "配置文件: ${SINGBOX_CONF}"
  echo "-----------------------------------------------"
  echo "系统服务: sing-box, argo"
  echo "===============================================${RESET}"
}

# ---------- 查看节点信息 ----------
show_node_info() {
  if [[ ! -f ${SINGBOX_CONF} ]]; then
    echo -e "${RED}未检测到 Sing-box 配置，请先安装！${RESET}"
    return
  fi
  local UUID=$(jq -r '.inbounds[0].users[0].uuid' ${SINGBOX_CONF})
  local WS_PATH=$(jq -r '.inbounds[0].transport.path' ${SINGBOX_CONF})
  local DOMAIN=$(grep -oP '(?<=sni=)[^&]*' <<< "$(grep -ho 'sni=[^& ]*' /etc/systemd/system/argo.service || echo '')" || echo "")
  DOMAIN=${DOMAIN:-"your-domain.com"}
  echo -e "${BLUE}-----------------------------------------------"
  echo "UUID: ${UUID}"
  echo "路径: ${WS_PATH}"
  echo "Argo 域名: ${DOMAIN}"
  echo "节点信息:"
  echo "vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox"
  echo "-----------------------------------------------${RESET}"
}

# ---------- 查看服务状态 ----------
check_status() {
  echo -e "${YELLOW}📊 Sing-box 状态：${RESET}"
  systemctl status sing-box --no-pager | grep -E "Active|Main PID" || echo "未安装"
  echo
  echo -e "${YELLOW}📡 Argo 隧道 状态：${RESET}"
  systemctl status argo --no-pager | grep -E "Active|Main PID" || echo "未安装"
}

# ---------- 卸载 ----------
uninstall_singbox_argo() {
  echo -e "${RED}========== Sing-box + Argo 一键卸载 ==========${RESET}"
  read -rp "确认继续并创建备份到 ${BACKUP_FILE} ? (yes/NO): " CONF
  if [[ "${CONF}" != "yes" ]]; then
    echo "已取消。"
    return
  fi

  echo "1) 创建备份..."
  tar -czf "${BACKUP_FILE}" \
    /etc/sing-box /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service \
    /root/.cloudflared* 2>/dev/null || true
  echo "备份已写入：${BACKUP_FILE}"

  echo "2) 停止服务..."
  systemctl stop sing-box 2>/dev/null || true
  systemctl stop argo 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  systemctl disable argo 2>/dev/null || true

  echo "3) 删除文件..."
  rm -rf /etc/sing-box /root/.cloudflared /usr/local/bin/sing-box /usr/local/bin/cloudflared
  rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
  systemctl daemon-reload || true

  echo "4) 清理完成。备份已保存到：${BACKUP_FILE}"
  echo -e "${GREEN}✅ 卸载完成！${RESET}"
}

# ---------- 主菜单 ----------
main_menu() {
  while true; do
    clear
    echo -e "${GREEN}========== Sing-box + Argo 管理菜单 ==========${RESET}"
    echo "1. 安装 Sing-box + Argo"
    echo "2. 查看节点信息"
    echo "3. 查看运行状态"
    echo "4. 一键卸载"
    echo "5. 退出"
    echo "=============================================="
    read -rp "请选择 [1-5]: " choice

    case $choice in
      1)
        install_base
        install_singbox
        generate_singbox_config
        install_cloudflared
        setup_argo_token
        ;;
      2) show_node_info ;;
      3) check_status ;;
      4) uninstall_singbox_argo ;;
      5) echo "已退出。"; exit 0 ;;
      *) echo "无效选项，请重新选择。"; sleep 1 ;;
    esac
    echo
    read -rp "按 Enter 返回菜单..." _
  done
}

main_menu
