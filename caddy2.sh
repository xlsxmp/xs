#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =====================================================
# Debian 12 专用：Caddy + Xray (VLESS WS+TLS) 自动部署增强脚本
# Features:
#  - Root check, history protection, error trapping
#  - HTTP or DNS (Cloudflare) ACME challenge
#  - Auto install Caddy & Xray, configure, enable systemd
#  - Firewall (ufw/iptables) friendliness
#  - Random WS path + UUID generation
#  - Output VLESS link and save to /root/vless.txt
# =====================================================

PROGNAME="$(basename "$0")"
LOGFILE="/var/log/${PROGNAME%.*}.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
confirm() { read -rp "$1 [y/N]: " _yn && [[ "${_yn,,}" == "y" || "${_yn,,}" == "yes" ]]; }

# ---------- safety ----------
if [ "$(id -u)" -ne 0 ]; then
  die "请以 root 权限运行此脚本"
fi

# Temporarily disable shell history to avoid leaking secrets
set +o history

trap 'set -o history; echo "脚本异常退出，已恢复 shell 历史";' EXIT

# ---------- defaults & CLI ----------
NONINTERACTIVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) NONINTERACTIVE=1; shift;;
    --domain) DOMAIN="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --dns) DNS_PROVIDER="$2"; shift 2;; # "cloudflare" or empty
    *) shift;;
  esac
done

# interactive prompts
if [ -z "${DOMAIN:-}" ]; then
  read -rp "请输入你的域名 (example.com): " DOMAIN
fi
if [ -z "${EMAIL:-}" ]; then
  read -rp "请输入你的邮箱 (用于证书通知, 可留空): " EMAIL
fi

# choose ACME method
if [ -z "${DNS_PROVIDER:-}" ]; then
  echo
  echo "请选择 TLS 验证方式："
  echo "  1) HTTP 验证 (默认，需 80/443 可访问并指向本机)"
  echo "  2) DNS 验证 (Cloudflare) - 需先导出 CLOUDFLARE_API_TOKEN 环境变量"
  read -rp "选择 (1/2, 默认1): " _ac
  if [ "$_ac" = "2" ]; then
    DNS_PROVIDER="cloudflare"
  else
    DNS_PROVIDER=""
  fi
fi

# generate UUID and WS path
UUID="$(cat /proc/sys/kernel/random/uuid)"
WSPATH="/$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"

# ports and paths
XRAY_LOCAL_PORT=10000
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
CADDYFILE="/etc/caddy/Caddyfile"
WWW_ROOT="/var/www/${DOMAIN}"

info "域名: $DOMAIN"
info "邮箱: ${EMAIL:-(空)}"
info "ACME 验证: ${DNS_PROVIDER:-http}"
info "UUID: $UUID"
info "WS 路径: $WSPATH"

if [ "$NONINTERACTIVE" -eq 0 ]; then
  if ! confirm "继续并在本机上安装/覆盖 Caddy 与 Xray 配置？"; then
    die "已取消"
  fi
fi

# ---------- pre-check: ports ----------
if ss -ltnp 2>/dev/null | grep -qE ':(80|443)\s'; then
  warn "检测到 80 或 443 端口被占用，请确认不会影响现有服务。"
  if [ "$NONINTERACTIVE" -eq 0 ]; then
    confirm "继续覆盖配置并尝试使用 Caddy？" || die "停止"
  fi
fi

# ---------- install deps ----------
info "更新 apt 源并安装基础依赖..."
apt update -y
apt install -y curl wget socat ca-certificates lsb-release apt-transport-https gnupg

# ---------- install Caddy ----------
info "安装 Caddy (官方 Cloudsmith 源)..."
if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list
  apt update
  apt install -y caddy
else
  info "检测到 caddy 已安装，跳过安装"
fi

# ---------- install Xray ----------
info "安装 Xray (官方安装脚本)..."
if ! command -v xray >/dev/null 2>&1 && [ ! -f /usr/local/bin/xray ]; then
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install || die "Xray 安装失败"
else
  info "检测到 xray 已安装，跳过安装"
fi

# ---------- firewall handling ----------
info "检查防火墙 (ufw / iptables) 并放行 80,443..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80,443/tcp || true
  ufw reload || true
  info "ufw 放行 80/443"
else
  # try iptables fallback (append if not exists)
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    info "iptables 放行 80/443"
  else
    warn "未检测到 ufw 或 iptables，若 VPS 上有防火墙请手动放行 80,443"
  fi
fi

# ---------- prepare pseudo site ----------
info "创建伪装站点：$WWW_ROOT"
mkdir -p "$WWW_ROOT"
cat > "$WWW_ROOT/index.html" <<HTML
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Welcome</title></head>
  <body>
    <h1>Welcome to ${DOMAIN}</h1>
    <p>Deployed by ${PROGNAME}.</p>
  </body>
</html>
HTML
chown -R www-data:www-data "$WWW_ROOT" || true

# ---------- write Xray config ----------
info "写入 Xray 配置到 $XRAY_CONF_FILE"
mkdir -p "$XRAY_CONF_DIR"
cat > "$XRAY_CONF_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray_access.log",
    "error": "/var/log/xray_error.log"
  },
  "inbounds": [
    {
      "port": $XRAY_LOCAL_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0,
            "email": "user@${DOMAIN}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WSPATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} },
    { "protocol": "blackhole", "tag": "blocked", "settings": {} }
  ]
}
EOF

# create log dir
mkdir -p /var/log
touch /var/log/xray_access.log /var/log/xray_error.log
chown -R nobody:nogroup /var/log/xray_*.log || true

# ---------- write Caddyfile ----------
info "写入 Caddyfile 到 $CADDYFILE"
if [ -n "$DNS_PROVIDER" ] && [ "$DNS_PROVIDER" = "cloudflare" ]; then
  # DNS 验证（Cloudflare）要求先设置 CLOUDFLARE_API_TOKEN 环境变量
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    warn "你选择了 Cloudflare DNS 验证，但未在运行前导出 CLOUDFLARE_API_TOKEN 环境变量。"
    if [ "$NONINTERACTIVE" -eq 1 ]; then
      die "请先导出 CLOUDFLARE_API_TOKEN 后重试（非交互模式）"
    fi
    if ! confirm "现在继续并使用 HTTP 验证改为自动申请证书？(若否请先 export CLOUDFLARE_API_TOKEN)"; then
      DNS_PROVIDER=""
    fi
  fi
fi

if [ -n "$DNS_PROVIDER" ] && [ "$DNS_PROVIDER" = "cloudflare" ]; then
  # Caddyfile: 使用 DNS 验证插件（要求 caddy 支持 dns.providers.cloudflare）
  cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    encode gzip
    root * ${WWW_ROOT}
    file_server

    @ws {
        path ${WSPATH}
    }
    reverse_proxy @ws 127.0.0.1:${XRAY_LOCAL_PORT}

    tls {
      dns cloudflare
      ${ EMAIL:+email ${EMAIL} }
    }
}
EOF
else
  # HTTP 验证（默认）
  cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    encode gzip
    root * ${WWW_ROOT}
    file_server

    @ws {
        path ${WSPATH}
    }
    reverse_proxy @ws 127.0.0.1:${XRAY_LOCAL_PORT}

    tls ${EMAIL:-internal}
}
EOF
fi

# ---------- restart services ----------
info "重载并启动服务..."
systemctl daemon-reload || true

# xray systemd service should exist from install script; ensure enabled
if systemctl list-unit-files | grep -q -F xray.service; then
  systemctl restart xray || warn "xray 重启失败，请检查 /var/log/xray_error.log"
  systemctl enable xray || true
else
  warn "未发现 xray.service，请确认 Xray 是否正确安装。"
fi

systemctl restart caddy || die "Caddy 重启失败，请检查日志"
systemctl enable caddy || true

# small wait for cert issuance (Caddy handles it)
info "等待 Caddy 申请证书与启动（最多 30 秒）..."
sleep 6
# quick status check
if systemctl is-active --quiet caddy; then
  info "Caddy 正在运行"
else
  warn "Caddy 未成功运行，请查看 systemctl status caddy"
fi

# ---------- output node info ----------
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WSPATH}#${DOMAIN}"
info "部署完成 — 节点信息如下："
echo
echo "VLESS 链接："
echo "$VLESS_LINK"
echo
echo "已将节点写入 /root/vless.txt"
echo "$VLESS_LINK" > /root/vless.txt

# restore history immediately
set -o history
trap - EXIT

info "完成。建议检查："
echo " - 证书状态：sudo caddy list-certificates"
echo " - Caddy 日志：sudo journalctl -u caddy --no-pager -n 200"
echo " - Xray 日志：sudo tail -n 200 /var/log/xray_error.log"
echo
info "如果你使用 Cloudflare DNS 验证，请确保已导出 CLOUDFLARE_API_TOKEN:"
echo "  export CLOUDFLARE_API_TOKEN=\"<你的 API Token>\""
echo
info "若需要，我可以将脚本做成非交互模式的版本，或加入更多 DNS 提供商（需要你确认 API 环境变量）。"
