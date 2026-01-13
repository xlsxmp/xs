#!/usr/bin/env bash
# ============================================================
#  VLESS + XHTTP + REALITY 一键交互式安装脚本（增强成品版）
#  - 自动生成 vless 链接并写入文件
#  - 自动开启 BBR
#  适用系统：Debian 11/12, Ubuntu 20.04+
#  Xray-core v25+
# ============================================================

set -euo pipefail

# ----------------------------
# 基础检查
# ----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "❌ 请使用 root 用户运行"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  apt update && apt install -y curl
fi

# ----------------------------
# 变量初始化
# ----------------------------
XRAY_DIR="/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
CONF_FILE="${XRAY_DIR}/config.json"
OUTPUT_FILE="/root/vless_reality_xhttp.txt"

UUID="$(cat /proc/sys/kernel/random/uuid)"

# ----------------------------
# 交互式输入
# ----------------------------
echo "======================================"
echo " VLESS + XHTTP + REALITY 安装向导"
echo "======================================"

read -rp "监听端口 [443]: " PORT
PORT=${PORT:-443}

read -rp "REALITY 伪装站点（如 www.microsoft.com）: " DEST
if [[ -z "$DEST" ]]; then
  echo "❌ 必须填写伪装站点"
  exit 1
fi

read -rp "REALITY ShortID（8~16位 hex，可留空自动生成）: " SHORT_ID
if [[ -z "$SHORT_ID" ]]; then
  SHORT_ID="$(openssl rand -hex 8)"
fi

# ----------------------------
# 安装 Xray-core
# ----------------------------
echo "▶ 安装 Xray-core..."
bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

mkdir -p "$XRAY_DIR"

# ----------------------------
# 生成 REALITY 密钥对
# ----------------------------
echo "▶ 生成 REALITY 密钥对..."
KEYS="$($XRAY_BIN x25519)"
PRIVATE_KEY="$(echo "$KEYS" | awk '/Private key/ {print $3}')"
PUBLIC_KEY="$(echo "$KEYS" | awk '/Public key/ {print $3}')"

# ----------------------------
# 写入 Xray 配置
# ----------------------------
cat > "$CONF_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": [
            "${DEST}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        },
        "xhttpSettings": {
          "mode": "packet-up"
        },
        "tlsSettings": {
          "alpn": [
            "h2"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

# ----------------------------
# systemd 管理
# ----------------------------
cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ----------------------------
# 开启 BBR
# ----------------------------
echo "▶ 启用 BBR 拥塞控制..."

cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system >/dev/null

# ----------------------------
# 获取服务器 IP
# ----------------------------
SERVER_IP="$(curl -s https://api.ipify.org || echo "<你的服务器IP>")"

# ----------------------------
# 生成 VLESS 链接
# ----------------------------
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&type=xhttp&flow=xtls-rprx-vision&sni=${DEST}&alpn=h2&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#VLESS-XHTTP-REALITY"

# ----------------------------
# 写入输出文件
# ----------------------------
cat > "$OUTPUT_FILE" <<EOF
==============================
 VLESS + XHTTP + REALITY
==============================

服务器地址: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
传输协议: xhttp
安全: reality
Flow: xtls-rprx-vision
SNI: ${DEST}
PublicKey: ${PUBLIC_KEY}
ShortID: ${SHORT_ID}
ALPN: h2

------------------------------
VLESS 链接：
${VLESS_LINK}
------------------------------

BBR 状态：
$(sysctl net.ipv4.tcp_congestion_control)

EOF

# ----------------------------
# 输出结果
# ----------------------------
echo
echo "======================================"
echo " 🎉 安装完成"
echo "======================================"
echo "配置文件: ${CONF_FILE}"
echo "分享文件: ${OUTPUT_FILE}"
echo
echo "VLESS 链接："
echo "${VLESS_LINK}"
echo "======================================"
