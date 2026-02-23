#!/bin/bash
set -e

# ==============================
# 基础变量
# ==============================

read -p "请输入你的域名（必须已解析到本机并开启CF橙云）: " DOMAIN

PORT=80
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/$(openssl rand -hex 4)"

echo "域名: $DOMAIN"
echo "UUID: $UUID"
echo "路径: $WS_PATH"
echo "端口: $PORT"

sleep 2

# ==============================
# Alpine 依赖
# ==============================

apk update
apk add curl wget bash openssl unzip iptables ip6tables ca-certificates
update-ca-certificates

# ==============================
# 安装 Xray（稳定版 latest/download）
# ==============================

echo "安装 Xray-core..."

ARCH=$(uname -m)

case "$ARCH" in
  x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) XRAY_ASSET="Xray-linux-arm64.zip" ;;
  armv7*|armv6l) XRAY_ASSET="Xray-linux-arm.zip" ;;
  i386|i686) XRAY_ASSET="Xray-linux-32.zip" ;;
  *) XRAY_ASSET="Xray-linux-64.zip" ;;
esac

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
echo "Downloading $XRAY_URL ..."

curl -L -o xray.zip "$XRAY_URL"
unzip xray.zip

if [ -f xray ] || [ -f Xray ]; then
    BIN_SRC="./xray"
    [ -f ./Xray ] && BIN_SRC="./Xray"
    install -m 0755 "$BIN_SRC" /usr/local/bin/xray
else
    echo "未找到 xray 二进制，解压目录内容："
    ls -la
    echo "安装失败。"
    exit 1
fi

mkdir -p /usr/local/etc/xray

# 创建 OpenRC 服务
cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="-config /usr/local/etc/xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"

depend() {
    need net
}
EOF

chmod +x /etc/init.d/xray
rc-update add xray default

# ==============================
# 写入 Xray 配置
# ==============================

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# ==============================
# 防火墙：仅允许 Cloudflare
# ==============================

echo "配置防火墙，仅允许 Cloudflare 访问..."

iptables -F
ip6tables -F

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

iptables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Cloudflare IPv4
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do
    iptables -A INPUT -p tcp -s $ip --dport 80 -j ACCEPT
done

# Cloudflare IPv6
for ip in $(curl -s https://www.cloudflare.com/ips-v6); do
    ip6tables -A INPUT -p tcp -s $ip --dport 80 -j ACCEPT
done

# 保存规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# ==============================
# 启动服务
# ==============================

rc-service xray restart

sleep 2

# ==============================
# 输出客户端信息
# ==============================

echo
echo "======================================"
echo "部署完成（生产级防探测版本）"
echo "======================================"
echo
echo "节点信息："
echo "地址: $DOMAIN"
echo "端口: 443"
echo "UUID: $UUID"
echo "路径: $WS_PATH"
echo "传输: XHTTP"
echo "TLS: 开启（由 Cloudflare 提供）"
echo
echo "客户端链接："
echo
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=xhttp&path=$WS_PATH&mode=auto&sni=$DOMAIN#VLESS-XHTTP-CF"
echo
echo "======================================"
echo
echo "重要说明："
echo "1. Cloudflare SSL 模式必须设置为 Full"
echo "2. 必须开启 HTTP/2"
echo "3. DNS 必须是橙云"
echo "4. 源站 80 端口已仅允许 CF 访问"
echo
echo "完成。"
