#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ===========================
# VLESS + XHTTP + TLS 一键安装器 (优化版)
# 支持: amd64 / arm64
# 证书: Let's Encrypt (certbot) / Cloudflare DNS (acme.sh)
# 自动续期、权限强化、域名解析检测、清理
# ===========================

echog() { echo -e "\n\033[1;32m$*\033[0m\n"; }
echow() { echo -e "\n\033[1;33m$*\033[0m\n"; }
echof() { echo -e "\n\033[1;31m$*\033[0m\n"; }

if [ "$(id -u)" -ne 0 ]; then
  echof "请使用 root 权限运行此脚本。"
  exit 1
fi

# ---- helper ----
req_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echof "缺少命令：$1，正在安装依赖..."; apt-get update -y && apt-get install -y "$2"; }
}

cleanup() {
  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

# ---- basic info ----
echog "=== VLESS + XHTTP 一键安装器 (优化版) ==="

read -rp "请输入你的域名（必须已解析到本VPS）: " DOMAIN
DOMAIN="${DOMAIN## }"
if [ -z "$DOMAIN" ]; then
  echof "域名不能为空。退出。"
  exit 1
fi

# 检查域名是否解析到此服务器（尽量做一次提示）
SERVER_IP="$(hostname -I | awk '{print $1}' || true)"
RESOLVED_IP=""
if command -v dig >/dev/null 2>&1; then
  RESOLVED_IP=$(dig +short A "$DOMAIN" | head -n1 || true)
elif command -v host >/dev/null 2>&1; then
  RESOLVED_IP=$(host -t A "$DOMAIN" | awk '/has address/ {print $NF; exit}' || true)
fi

if [ -n "$RESOLVED_IP" ]; then
  if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echow "提示：域名 $DOMAIN 解析到 $RESOLVED_IP（本机 IP: ${SERVER_IP:-未检测到}）。"
    read -rp "域名未解析到本机。仍然继续安装？(y/N): " CONT
    CONT=${CONT:-n}
    if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
      echof "退出。请先把域名解析到本VPS后重试。"
      exit 1
    fi
  fi
else
  echow "无法检测到域名的 A 记录（没有安装 dig/host 或 DNS 未解析）。"
  read -rp "仍然继续安装（可能导致证书申请失败）？(y/N): " CONT
  CONT=${CONT:-n}
  if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
    echof "退出。请确保域名已解析后重试。"
    exit 1
  fi
fi

echo "证书获取方式:"
echo "  1) Let's Encrypt (standalone - certbot)"
echo "  2) Cloudflare (acme.sh + DNS API)"
read -rp "请选择证书方式 (1 或 2) [1]: " CERT_CHOICE
CERT_CHOICE=${CERT_CHOICE:-1}

CF_API_TOKEN=""
CF_ZONE_ID=""
if [ "$CERT_CHOICE" = "2" ]; then
  echow "使用 Cloudflare DNS 模式，请准备 API Token（至少 Zone:DNS edit）"
  read -rp "请输入 Cloudflare API Token: " CF_API_TOKEN
  read -rp "请输入 Cloudflare Zone ID（可留空）: " CF_ZONE_ID
  if [ -z "$CF_API_TOKEN" ]; then
    echof "Cloudflare API Token 不能为空。退出。"
    exit 1
  fi
fi

# 随机 UUID 跟 PATH
UUID=$(cat /proc/sys/kernel/random/uuid)
PATH_ID="/$(head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-24)"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
CERT_DIR="/etc/ssl/${DOMAIN}"
INFO_FILE="/root/${DOMAIN}_xhttp_info.txt"

echog "配置摘要："
echo "  域名: ${DOMAIN}"
echo "  UUID: ${UUID}"
echo "  伪装路径: ${PATH_ID}"
echo "  证书方式: $([ "$CERT_CHOICE" = "2" ] && echo 'Cloudflare DNS' || echo 'Let’s Encrypt standalone')"
read -rp "确认开始安装？(y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echog "已取消"; exit 0; }

# ---- install dependencies ----
echog "安装/检测基础依赖..."
apt-get update -y
apt-get install -y unzip curl jq socat ca-certificates lsb-release gnupg apt-transport-https || true
# ensure python3 present for URL-encoding
if ! command -v python3 >/dev/null 2>&1; then
  apt-get install -y python3
fi
# dig/host are useful but optional
apt-get install -y dnsutils || true

if [ "$CERT_CHOICE" = "1" ]; then
  apt-get install -y certbot
fi

# ---- detect arch and pick Xray asset ----
echog "检测系统架构..."
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) XRAY_ASSET="Xray-linux-arm64.zip" ;;
  *)
    echow "未识别架构：$ARCH，尝试使用 amd64 版本。"
    XRAY_ASSET="Xray-linux-64.zip"
    ;;
esac

echog "下载并安装 Xray Core (${XRAY_ASSET})..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
XRAY_RELEASE_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
echow "从 $XRAY_RELEASE_URL 下载（可能稍慢）..."
curl -fsSL -o xray.zip "$XRAY_RELEASE_URL"
unzip -o xray.zip >/dev/null 2>&1 || true
if [ ! -f xray ]; then
  echof "Xray 二进制未找到，下载或解压失败。请检查网络或手动下载。"
  exit 1
fi
install -m 755 xray "$XRAY_BIN"

mkdir -p "$XRAY_DIR" /var/log/xray
if ! id -u xray >/dev/null 2>&1; then useradd -r -s /usr/sbin/nologin -M xray || true; fi
chown -R xray:xray "$XRAY_DIR" /var/log/xray

cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=xray
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray

mkdir -p "$CERT_DIR"

# ---- certificate issuance ----
if [ "$CERT_CHOICE" = "1" ]; then
  echog "申请 Let's Encrypt 证书 (standalone 模式)..."
  # stop xray (占用 443) 再申请
  systemctl stop xray || true
  certbot certonly --standalone -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --force-renewal
  if [ ! -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]; then
    echof "certbot 未能成功生成证书。请检查日志。"
    exit 1
  fi
  cp -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem "${CERT_DIR}/fullchain.pem"
  cp -f /etc/letsencrypt/live/${DOMAIN}/privkey.pem "${CERT_DIR}/privkey.pem"
  # enable certbot timer for renewals
  if systemctl list-timers | grep -q certbot; then
    systemctl enable --now certbot.timer || true
  fi
else
  echog "使用 acme.sh + Cloudflare DNS 申请证书..."
  # install acme.sh if necessary
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl -fsSL https://get.acme.sh | sh -s -- --install -m admin@"${DOMAIN}" || true
  fi
  export PATH="/root/.acme.sh:$PATH"
  export CF_Token="${CF_API_TOKEN}"
  [ -n "${CF_ZONE_ID:-}" ] && export CF_Zone_ID="${CF_ZONE_ID}"
  # issue cert
  /root/.acme.sh/acme.sh --issue --dns dns_cf -d "${DOMAIN}" --force
  if [ ! -f "/root/.acme.sh/${DOMAIN}/${DOMAIN}.cer" ] && [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
    echow "acme.sh 未在常规位置产出证书，尝试 --install-cert..."
  fi
  /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
    --cert-file "${CERT_DIR}/fullchain.pem" \
    --key-file  "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl restart xray || true"
  # ensure cronjob exists
  /root/.acme.sh/acme.sh --install-cronjob || true
fi

# 权限收紧
chown xray:xray "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" || true
chmod 640 "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" || true
chmod 700 "$CERT_DIR" || true

# ---- generate xray config ----
echog "写入 Xray 配置..."
mkdir -p "$XRAY_DIR"
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "email": "user@${DOMAIN}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/privkey.pem"
            }
          ],
          "alpn": ["http/1.1"],
          "minVersion": "1.2"
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "${PATH_ID}"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

chown xray:xray "$XRAY_CONF"
chmod 600 "$XRAY_CONF"

# ---- start xray and check ----
echog "启动并检查 Xray 服务..."
systemctl restart xray || true
sleep 1
if ! systemctl is-active --quiet xray; then
  echof "Xray 启动失败，请查看日志：journalctl -u xray -n 100 --no-pager"
  exit 1
fi

# check xray binary works
if command -v /usr/local/bin/xray >/dev/null 2>&1; then
  /usr/local/bin/xray -version >/dev/null 2>&1 || echow "注意：xray -version 检查未通过（可能是权限或运行环境问题）"
fi

# ---- generate client URIs and info file ----
# ensure python3 for URL encoding
ENC_PATH=$(python3 - <<PY
import urllib.parse, sys
print(urllib.parse.quote("${PATH_ID}", safe=''))
PY
)

VLESS_URI="vless://${UUID}@${DOMAIN}:443?type=xhttp&security=tls&path=${ENC_PATH}&sni=${DOMAIN}#${DOMAIN}-xhttp"

cat > "$INFO_FILE" <<INFO
域名: ${DOMAIN}
UUID: ${UUID}
伪装路径: ${PATH_ID}
证书方式: $([ "$CERT_CHOICE" = "2" ] && echo 'Cloudflare DNS' || echo 'Let’s Encrypt standalone')

VLESS URI:
${VLESS_URI}

Clash 示例:
- name: "${DOMAIN}-xhttp"
  type: vless
  server: ${DOMAIN}
  port: 443
  uuid: ${UUID}
  udp: false
  tls: true
  network: xhttp
  path: "${PATH_ID}"
  sni: "${DOMAIN}"

日志: journalctl -u xray -n 200 --no-pager

INFO

echog "✅ 安装完成！"
echo "配置文件已保存: $INFO_FILE"
echo "查看日志: journalctl -u xray -n 100 --no-pager"
