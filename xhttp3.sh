#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# VLESS + XHTTP + TLS 一键安装器（增强版）
# 支持: amd64 / arm64
# 证书: Let's Encrypt (certbot) / Cloudflare DNS (acme.sh)
# 注意: 当前脚本仅针对 Debian/Ubuntu 系列做了包管理实现

VERSION="2025-10-31-v1"

echog() { echo -e "\n\033[1;32m$*\033[0m\n"; }
echow() { echo -e "\n\033[1;33m$*\033[0m\n"; }
echof() { echo -e "\n\033[1;31m$*\033[0m\n"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echof "请使用 root 权限运行此脚本。"
    exit 1
  fi
}

usage() {
  cat <<USAGE

Usage: $0 [--yes] [--domain DOMAIN] [--cert-method 1|2] [--cf-token TOKEN] [--cf-zone ZONE_ID]

Options:
  --yes                 非交互模式，使用默认或命令行提供的值
  --domain DOMAIN       要配置的域名（必须已解析到本VPS）
  --cert-method 1|2     证书方式: 1=Let's Encrypt (certbot) ; 2=Cloudflare (acme.sh)  (default 1)
  --cf-token TOKEN      Cloudflare API Token（仅 cert-method=2 时需要）
  --cf-zone ZONE_ID     Cloudflare Zone ID（可选）
  -h, --help            显示本帮助信息

USAGE
  exit 1
}

# ---- parse args ----
NONINTERACTIVE=0
DOMAIN=""
CERT_CHOICE="1"
CF_API_TOKEN=""
CF_ZONE_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) NONINTERACTIVE=1; shift ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --cert-method) CERT_CHOICE="$2"; shift 2 ;;
    --cf-token) CF_API_TOKEN="$2"; shift 2 ;;
    --cf-zone) CF_ZONE_ID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echow "未知参数: $1"; usage ;;
  esac
done

require_root

echog "=== VLESS + XHTTP 一键安装器（增强版） $VERSION ==="

# ---- distro check (only Debian/Ubuntu supported) ----
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="${ID_LIKE:-${ID:-unknown}}"
else
  DISTRO="unknown"
fi

case "$DISTRO" in
  *debian*|*ubuntu*|debian|ubuntu) PM="apt-get" ;;
  *)
    echof "当前只实现了 Debian/Ubuntu 的包管理逻辑。你当前系统: ${DISTRO}. 如需在其它发行版使用，请手动适配脚本的安装部分。"
    exit 1
    ;;
esac

# ---- helper ----
req_pkg() {
  pkg="$1"
  # optionally allow override package name
  name="${2:-$1}"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echow "安装依赖：$name"
    apt-get update -y
    apt-get install -y "$name"
  fi
}

cleanup() {
  if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

confirm_or_exit() {
  local prompt="$1"
  local default="${2:-n}"
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    if [[ ! "$default" =~ ^[Yy]$ ]]; then
      echof "非交互模式：未确认，退出。"
      exit 1
    fi
    return 0
  fi
  read -rp "$prompt" ans
  ans=${ans:-$default}
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echof "已取消"
    exit 1
  fi
}

# ---- interactive prompts if needed ----
if [ -z "$DOMAIN" ]; then
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    echof "非交互模式但未提供 --domain 参数，退出。"
    exit 1
  fi
  read -rp "请输入你的域名（必须已解析到本VPS）: " DOMAIN
  DOMAIN="${DOMAIN## }"
fi

if [ -z "$DOMAIN" ]; then
  echof "域名不能为空。退出。"
  exit 1
fi

if [ -z "$CERT_CHOICE" ]; then
  CERT_CHOICE="1"
fi

if [ "$CERT_CHOICE" != "1" ] && [ "$CERT_CHOICE" != "2" ]; then
  echof "证书方式必须为 1 或 2。"
  exit 1
fi

if [ "$CERT_CHOICE" = "2" ] && [ -z "$CF_API_TOKEN" ] && [ "$NONINTERACTIVE" -eq 0 ]; then
  echow "使用 Cloudflare DNS 模式，请准备 API Token（至少 Zone:DNS edit）"
  read -rp "请输入 Cloudflare API Token: " CF_API_TOKEN
  read -rp "请输入 Cloudflare Zone ID（可留空）: " CF_ZONE_ID
fi

if [ "$CERT_CHOICE" = "2" ] && [ -z "$CF_API_TOKEN" ]; then
  echof "Cloudflare API Token 不能为空（cert-method=2）。退出。"
  exit 1
fi

# ---- configuration variables ----
UUID=$(cat /proc/sys/kernel/random/uuid)
# 生成 URL-safe 的伪装路径，保证以字母开头，长度 24
generate_path() {
  local p
  p="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c24 || true)"
  # 保证首字符为字母
  if [[ ! "${p:0:1}" =~ [a-zA-Z] ]]; then
    p="p${p:1}"
  fi
  echo "/$p"
}
PATH_ID="$(generate_path)"

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

confirm_or_exit "确认开始安装？(y/N): " "n"

# ---- install base deps ----
echog "安装/检测基础依赖..."
apt-get update -y
apt-get install -y unzip curl jq socat ca-certificates lsb-release gnupg apt-transport-https python3 python3-requests || true
# optional useful tools
apt-get install -y dnsutils ss lsof || true

if [ "$CERT_CHOICE" = "1" ]; then
  apt-get install -y certbot || true
fi

# ---- helper: check public IP resolution ----
get_public_ip() {
  # prefer ipv4 from external services, fallback to hostname -I
  ip=""
  for svc in "https://ifconfig.me" "https://ipinfo.io/ip" "https://icanhazip.com"; do
    ip="$(curl -fsm3 "$svc" || true)"
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  # fallback
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "$ip"
}

SERVER_IP="$(get_public_ip || true)"
RESOLVED_IP=""
if command -v dig >/dev/null 2>&1; then
  RESOLVED_IP=$(dig +short A "$DOMAIN" | head -n1 || true)
elif command -v host >/dev/null 2>&1; then
  RESOLVED_IP=$(host -t A "$DOMAIN" | awk '/has address/ {print $NF; exit}' || true)
fi

if [ -n "$RESOLVED_IP" ]; then
  if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echow "提示：域名 $DOMAIN 解析到 $RESOLVED_IP（检测到公网 IP: ${SERVER_IP:-未检测到}）。"
    if [ "$NONINTERACTIVE" -eq 1 ]; then
      echof "非交互模式且域名未解析到本机，退出。"
      exit 1
    fi
    read -rp "域名未解析到本机。仍然继续安装？(y/N): " CONT
    CONT=${CONT:-n}
    if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
      echof "退出。请先把域名解析到本VPS后重试。"
      exit 1
    fi
  fi
else
  echow "无法检测到域名的 A 记录（没有安装 dig/host 或 DNS 未解析）。"
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    echof "非交互模式且无法确认域名解析，退出。"
    exit 1
  fi
  read -rp "仍然继续安装（可能导致证书申请失败）？(y/N): " CONT
  CONT=${CONT:-n}
  if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
    echof "退出。请确保域名已解析后重试。"
    exit 1
  fi
fi

# ---- utility: check port occupancy and stop common services ----
check_port() {
  local p="$1"
  if ss -ltnp "sport = :${p}" >/dev/null 2>&1; then
    echow "端口 ${p} 可能已被占用，列出占用进程："
    ss -ltnp "sport = :${p}" || true
    if [ "$NONINTERACTIVE" -eq 1 ]; then
      echof "非交互模式且端口 ${p} 被占用，退出。"
      exit 1
    fi
    read -rp "是否尝试停止常见 web 服务（nginx/apache/httpd）并继续？(y/N): " ans
    ans=${ans:-n}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      systemctl stop nginx apache2 httpd || true
      sleep 1
      if ss -ltnp "sport = :${p}" >/dev/null 2>&1; then
        echof "端口 ${p} 仍被占用，无法继续申请 standalone 证书。"
        exit 1
      fi
    else
      echof "请在继续前释放端口 ${p}。退出。"
      exit 1
    fi
  fi
}

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

# ---- prepare dirs, backup existing config ----
mkdir -p "$XRAY_DIR" /var/log/xray "$CERT_DIR"
if id -u xray >/dev/null 2>&1; then
  :
else
  useradd -r -s /usr/sbin/nologin -M xray || true
fi
chown -R xray:xray "$XRAY_DIR" /var/log/xray || true

if [ -f "$XRAY_CONF" ]; then
  ts=$(date +%s)
  echow "检测到已存在的 Xray 配置，备份为 ${XRAY_CONF}.bak.${ts}"
  cp -a "$XRAY_CONF" "${XRAY_CONF}.bak.${ts}" || true
fi

# ---- download and install Xray with retries ----
echog "下载并安装 Xray Core (${XRAY_ASSET})..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
download_xray() {
  local url="$1" out="$2"
  local try=0
  while [ $try -lt 4 ]; do
    ((try++))
    echog "下载 Xray (尝试 $try): $url"
    if curl -fSL -o "$out" "$url"; then
      return 0
    fi
    sleep $((try * 2))
  done
  return 1
}
XRAY_RELEASE_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
if ! download_xray "$XRAY_RELEASE_URL" "xray.zip"; then
  echof "Xray 下载失败，请检查网络或手动下载安装包。"
  exit 1
fi
unzip -o xray.zip >/dev/null 2>&1 || { echof "解压 xray.zip 失败"; exit 1; }
if [ -f xray ] && [ -x xray ]; then
  install -m 755 xray "$XRAY_BIN" || { echof "安装 xray 到 ${XRAY_BIN} 失败"; exit 1; }
elif [ -f xray ]; then
  chmod +x xray
  install -m 755 xray "$XRAY_BIN" || { echof "安装 xray 到 ${XRAY_BIN} 失败"; exit 1; }
else
  echof "xray 二进制未在压缩包内找到。"
  exit 1
fi

# ---- systemd unit (enhanced security) ----
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
PrivateDevices=true
ProtectProc=invisible
MemoryDenyWriteExecute=true
ReadOnlyPaths=/usr /boot /etc
ReadWritePaths=/usr/local/bin /usr/local/etc/xray /var/log/xray /etc/ssl
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray

# ---- certificate issuance ----
echog "证书申请步骤"

if [ "$CERT_CHOICE" = "1" ]; then
  echog "申请 Let's Encrypt 证书 (standalone 模式)..."
  check_port 80
  check_port 443
  systemctl stop xray || true
  if ! certbot certonly --standalone -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --force-renewal; then
    echof "certbot 未能成功生成证书。请检查 certbot 日志。"
    exit 1
  fi
  if [ ! -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]; then
    echof "certbot 未能在预期位置产出证书。"
    exit 1
  fi
  cp -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem "${CERT_DIR}/fullchain.pem"
  cp -f /etc/letsencrypt/live/${DOMAIN}/privkey.pem "${CERT_DIR}/privkey.pem"
  if systemctl list-timers | grep -q certbot; then
    systemctl enable --now certbot.timer || true
  fi
else
  echog "使用 acme.sh + Cloudflare DNS 申请证书..."
  # 安装 acme.sh
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl -fsSL https://get.acme.sh | sh -s -- --install -m "admin@${DOMAIN}" || true
  fi
  export PATH="/root/.acme.sh:$PATH"
  export CF_Token="${CF_API_TOKEN}"
  [ -n "${CF_ZONE_ID:-}" ] && export CF_Zone_ID="${CF_ZONE_ID}"
  # 简单验证 CF token 可用性（调用 zones endpoint 仅当 zone 提供时）
  if ! /root/.acme.sh/acme.sh --issue --dns dns_cf -d "${DOMAIN}" --force; then
    echof "acme.sh 使用 Cloudflare DNS 申请证书失败，请检查 CF API Token 与 Zone 权限。"
    unset CF_Token
    unset CF_API_TOKEN
    exit 1
  fi
  /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
    --cert-file "${CERT_DIR}/fullchain.pem" \
    --key-file  "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl restart xray || true"
  /root/.acme.sh/acme.sh --install-cronjob || true
  # 清理敏感变量
  unset CF_Token
  unset CF_API_TOKEN
fi

# 权限收紧
chown xray:xray "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" || true
chmod 640 "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" || true
chmod 700 "$CERT_DIR" || true

# ---- generate xray config ----
echog "写入 Xray 配置..."
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
sleep 2
if ! systemctl is-active --quiet xray; then
  echof "Xray 启动失败，请查看日志：journalctl -u xray -n 200 --no-pager"
  exit 1
fi

# ---- generate client URIs and info file ----
# URL-encode PATH_ID
ENC_PATH="$(python3 - <<PY
import urllib.parse,sys
p=sys.argv[1]
print(urllib.parse.quote(p, safe=''))
PY
"${PATH_ID}" 2>/dev/null || echo "${PATH_ID}")"

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
echo "查看日志: journalctl -u xray -n 200 --no-pager"
echo "若需要再次运行脚本以变更配置，请先备份当前配置和证书。"
