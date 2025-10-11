#!/usr/bin/env bash
# ======================================================
#   Sing-box + VLESS + WS + TLS + Cloudflare Argo 一体化脚本
#   增强：安装后把节点信息写入 /etc/sing-box/node_info.json
# ======================================================

set -euo pipefail

# ---------- 基础变量 ----------
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
SINGBOX_DIR=/etc/sing-box
SINGBOX_BIN=/usr/local/bin/sing-box
SINGBOX_CONF=${SINGBOX_DIR}/config.json
NODE_INFO_FILE=${SINGBOX_DIR}/node_info.json
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

# ---------- 权限检查 ----------
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行本脚本${RESET}"
    exit 1
  fi
}

# ---------- 安装依赖 ----------
install_base() {
  echo -e "${YELLOW}🔧 安装依赖: curl wget jq ...${RESET}"
  apt update -y
  apt install -y curl wget unzip jq ca-certificates lsb-release >/dev/null 2>&1 || true
}

# ---------- 安装 sing-box ----------
install_singbox() {
  echo -e "${YELLOW}⬇️  安装 Sing-box...${RESET}"
  mkdir -p "${SINGBOX_DIR}"
  local ARCH
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|amd64) FILE_SUFFIX="linux-amd64" ;;
    aarch64|arm64) FILE_SUFFIX="linux-arm64" ;;
    *) FILE_SUFFIX="linux-amd64" ;; # 兜底
  esac

  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  if [ -z "${VER}" ] || [ "${VER}" = "null" ]; then
    echo -e "${RED}无法获取 sing-box 最新版本，请检查网络${RESET}"
    return 1
  fi
  DL_URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-${FILE_SUFFIX}.tar.gz"
  wget -qO /tmp/singbox.tar.gz "${DL_URL}"
  tar -xf /tmp/singbox.tar.gz -C /tmp
  install -m 0755 /tmp/sing-box-${VER#v}-${FILE_SUFFIX}/sing-box "${SINGBOX_BIN}"
  chmod +x "${SINGBOX_BIN}"
}

# ---------- 生成配置并启用服务 ----------
generate_singbox_config() {
  echo -e "${YELLOW}⚙️  生成 Sing-box 配置并启用服务...${RESET}"
  mkdir -p "${SINGBOX_DIR}"

  cat > "${SINGBOX_CONF}" <<EOF
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

  cat > "${SINGBOX_SERVICE}" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now sing-box || true
  sleep 1
}

# ---------- 安装 cloudflared ----------
install_cloudflared() {
  echo -e "${YELLOW}☁️  安装 cloudflared ...${RESET}"
  local ARCH
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64|amd64) CF_ASSET="cloudflared-linux-amd64" ;;
    aarch64|arm64) CF_ASSET="cloudflared-linux-arm64" ;;
    *) CF_ASSET="cloudflared-linux-amd64" ;;
  esac
  wget -qO "${CLOUDFLARED_BIN}" "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_ASSET}"
  chmod +x "${CLOUDFLARED_BIN}"
}

# ---------- 配置 Argo Token 模式（并写入节点信息文件） ----------
setup_argo_token() {
  echo -e "${YELLOW}🔹 请输入 Cloudflare Argo Token（token 模式）:${RESET}"
  read -rp "Argo Token: " ARGO_TOKEN
  echo -e "${YELLOW}🔹 请输入 Argo 隧道绑定域名 (例如 argo.example.com)。若留空可稍后手动填写:${RESET}"
  read -rp "Argo 域名: " DOMAIN
  DOMAIN=${DOMAIN:-"<未设置>"}

  # 写入 systemd 服务
  cat > "${ARGO_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel (Token Mode)
After=network.target

[Service]
ExecStart=${CLOUDFLARED_BIN} tunnel --edge-ip-version auto run --token ${ARGO_TOKEN}
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now argo || true
  sleep 1

  # 生成并保存节点信息到文件（JSON）
  mkdir -p "${SINGBOX_DIR}"
  cat > "${NODE_INFO_FILE}" <<EOF
{
  "uuid": "${UUID}",
  "ws_path": "${WS_PATH}",
  "port": 443,
  "domain": "${DOMAIN}",
  "vless_url": "vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox",
  "installed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
  chmod 600 "${NODE_INFO_FILE}"
  echo -e "${GREEN}节点信息已写入：${NODE_INFO_FILE}${RESET}"
}

# ---------- 输出节点信息（安装完成时） ----------
output_info() {
  local DOMAIN=$1
  clear
  echo -e "${GREEN}==============================================="
  echo "✅ Sing-box + Argo 已部署完成"
  echo "-----------------------------------------------"
  if [ -f "${NODE_INFO_FILE}" ]; then
    jq -r '.vless_url' "${NODE_INFO_FILE}" 2>/dev/null || echo "vless://...（无法读取）"
  else
    echo "vless://${UUID}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#VLESS-Argo-Singbox"
  fi
  echo "-----------------------------------------------"
  echo "UUID: ${UUID}"
  echo "回源端口: ${PORT}"
  echo "Argo 域名: ${DOMAIN}"
  echo "配置文件: ${SINGBOX_CONF}"
  echo "节点信息文件: ${NODE_INFO_FILE}"
  echo "-----------------------------------------------"
  echo "系统服务: sing-box, argo"
  echo "===============================================${RESET}"
}

# ---------- 查看节点信息（从文件读取优先） ----------
show_node_info() {
  if [ -f "${NODE_INFO_FILE}" ]; then
    echo -e "${BLUE}从 ${NODE_INFO_FILE} 读取节点信息：${RESET}"
    jq -r '. as $x | "-----------------------------------------------\nUUID: \($x.uuid)\n路径: \($x.ws_path)\nArgo 域名: \($x.domain)\n节点信息:\n\($x.vless_url)\n-----------------------------------------------"' "${NODE_INFO_FILE}"
    # 如果 domain 未设置，提醒用户
    domain_val=$(jq -r '.domain' "${NODE_INFO_FILE}")
    if [[ "${domain_val}" == "<未设置>" || -z "${domain_val}" || "${domain_val}" == "null" ]]; then
      echo -e "${YELLOW}⚠️ Argo 域名尚未设置，节点 URL 中的 domain 为占位符。若需要，请使用菜单 1 重新安装并提供域名，或手动编辑 ${NODE_INFO_FILE}${RESET}"
    fi
  else
    # 兜底：按旧逻辑展示（若未安装会提示）
    if [[ ! -f ${SINGBOX_CONF} ]]; then
      echo -e "${RED}未检测到 Sing-box 配置，请先安装。${RESET}"
      return
    fi
    UUID_NOW=$(jq -r '.inbounds[0].users[0].uuid' "${SINGBOX_CONF}" 2>/dev/null || echo "${UUID}")
    WS_NOW=$(jq -r '.inbounds[0].transport.path' "${SINGBOX_CONF}" 2>/dev/null || echo "${WS_PATH}")
    DOMAIN_NOW="<未设置>"
    echo "-----------------------------------------------"
    echo "UUID: ${UUID_NOW}"
    echo "路径: ${WS_NOW}"
    echo "Argo 域名: ${DOMAIN_NOW}"
    echo "节点信息:"
    echo "vless://${UUID_NOW}@${CDN}:443?encryption=none&security=tls&sni=${DOMAIN_NOW}&type=ws&host=${DOMAIN_NOW}&path=${WS_NOW}#VLESS-Argo-Singbox"
    echo "-----------------------------------------------"
    echo -e "${YELLOW}⚠️ 建议安装后使用菜单 2 查看节点信息，以便读取保存的 node_info.json${RESET}"
  fi
}

# ---------- 查看服务状态 ----------
check_status() {
  echo -e "${YELLOW}📊 Sing-box 状态：${RESET}"
  if systemctl is-enabled --quiet sing-box 2>/dev/null || systemctl is-active --quiet sing-box 2>/dev/null; then
    systemctl status sing-box --no-pager | grep -E "Active|Main PID" || echo "sing-box 状态未知"
  else
    echo "sing-box 未安装或未启用"
  fi
  echo
  echo -e "${YELLOW}📡 Argo 隧道 状态：${RESET}"
  if systemctl is-enabled --quiet argo 2>/dev/null || systemctl is-active --quiet argo 2>/dev/null; then
    systemctl status argo --no-pager | grep -E "Active|Main PID" || echo "argo 状态未知"
  else
    echo "argo 未安装或未启用"
  fi
}

# ---------- 卸载（含备份） ----------
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
  rm -f "${NODE_INFO_FILE}"
  systemctl daemon-reload || true

  echo "4) 清理完成。备份已保存到：${BACKUP_FILE}"
  echo -e "${GREEN}✅ 卸载完成！${RESET}"
}

# ---------- 检测已存在安装，提示覆盖/卸载/取消 ----------
check_existing() {
  local exist=0
  if systemctl list-units --full -all | grep -q 'sing-box.service'; then
    echo -e "${YELLOW}⚠️ 检测到已安装 Sing-box 服务${RESET}"
    exist=1
  fi
  if systemctl list-units --full -all | grep -q 'argo.service'; then
    echo -e "${YELLOW}⚠️ 检测到已安装 Argo 隧道服务${RESET}"
    exist=1
  fi

  if [[ ${exist} -eq 1 ]]; then
    echo
    echo -e "${RED}检测到已有部署，可能会覆盖当前配置！${RESET}"
    echo "请选择操作："
    echo "1. 继续安装并覆盖旧配置"
    echo "2. 卸载旧版本后全新安装（会备份）"
    echo "3. 取消安装"
    read -rp "请输入选项 [1-3]: " act
    case "${act}" in
      1) echo "继续安装并覆盖旧配置..." ;;
      2) uninstall_singbox_argo; echo -e "${GREEN}已清理旧版本，准备安装...${RESET}" ;;
      3) echo "已取消。"; return 1 ;;
      *) echo "无效选项，已取消。"; return 1 ;;
    esac
  fi
  return 0
}

# ---------- 主菜单 ----------
main_menu() {
  check_root
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
        if ! check_existing; then
          echo "安装已取消。"
          sleep 1
        else
          install_base
          install_singbox
          generate_singbox_config
          install_cloudflared
          setup_argo_token
        fi
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
