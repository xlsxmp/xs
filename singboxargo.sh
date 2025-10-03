#!/bin/bash

# 定义颜色
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
HOSTNAME=$(hostname)

# UUID 默认或传参
UUID=${1:-'7cc49cc4-ad21-4007-9443-5d3a09477833'}
export UUID
echo "Using UUID: $UUID"

# Argo 相关变量
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}

WORKDIR="/home/${USERNAME}/.vmess"
[ -d "$WORKDIR" ] || (mkdir -p "$WORKDIR" && chmod 777 "$WORKDIR")

# 输入 vmess 端口
read_vmess_port() {
    while true; do
        reading "请输入vmess端口: " vmess_port
        if [[ "$vmess_port" =~ ^[0-9]+$ ]] && [ "$vmess_port" -ge 1 ] && [ "$vmess_port" -le 65535 ]; then
            green "你的vmess端口为: $vmess_port"
            break
        else
            yellow "输入错误，请重新输入TCP端口"
        fi
    done
}

# 安装流程
install_singbox() {
echo -e "${yellow}本脚本安装vmess协议${purple}(vmess-ws)${re}"
reading "\n确定继续安装吗？【y/n】: " choice
  case "$choice" in
    [Yy])
        cd $WORKDIR
        read_vmess_port
        argo_configure
        generate_config
        download_singbox && wait
        run_sb && sleep 3
        get_links
      ;;
    [Nn]) exit 0 ;;
    *) red "无效的选择，请输入y或n" && menu ;;
  esac
}

# 卸载
uninstall_singbox() {
  reading "\n确定要卸载吗？【y/n】: " choice
    case "$choice" in
       [Yy])
          pkill -f web
          pkill -f bot
          rm -rf $WORKDIR
          ;;
        [Nn]) exit 0 ;;
        *) red "无效的选择，请输入y或n" && menu ;;
    esac
}

# 清理所有任务
kill_all_tasks() {
reading "\n清理所有进程将退出ssh连接，确定继续清理吗？【y/n】: " choice
  case "$choice" in
    [Yy]) killall -9 -u $(whoami) ;;
       *) menu ;;
  esac
}

# Argo 配置
argo_configure() {
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
      reading "是否需要使用固定argo隧道？【y/n】: " argo_choice
      [[ -z $argo_choice ]] && return
      if [[ "$argo_choice" == "y" || "$argo_choice" == "Y" ]]; then
          while [[ -z $ARGO_DOMAIN ]]; do
            reading "请输入argo固定隧道域名: " ARGO_DOMAIN
            [[ -z $ARGO_DOMAIN ]] && red "不能为空"
          done
          while [[ -z $ARGO_AUTH ]]; do
            reading "请输入argo固定隧道密钥（Json或Token）: " ARGO_AUTH
            [[ -z $ARGO_AUTH ]] && red "不能为空"
          done
          echo -e "${red}注意：${purple}使用token，需要在cloudflare后台设置隧道端口和面板开放端口一致${re}"
      else
          green "ARGO隧道变量未设置，将使用临时隧道"
          return
      fi
  fi

  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    echo $ARGO_AUTH > tunnel.json
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$vmess_port
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  fi
}

# 下载官方 sing-box 和 cloudflared
download_singbox() {
  ARCH=$(uname -m)
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  # sing-box
  VER="1.10.0"
  case "$ARCH" in
    x86_64) SB_FILE="sing-box-${VER}-linux-amd64.tar.gz" ;;
    aarch64|arm64) SB_FILE="sing-box-${VER}-linux-arm64.tar.gz" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac

  if [ ! -e web ]; then
    wget -q "https://github.com/SagerNet/sing-box/releases/download/v${VER}/${SB_FILE}" -O sb.tar.gz
    tar -xzf sb.tar.gz
    mv sing-box*/sing-box web
    chmod +x web
    rm -rf sing-box* sb.tar.gz
    green "sing-box 下载完成"
  fi

  # cloudflared (argo)
  if [ ! -e bot ]; then
    case "$ARCH" in
      x86_64) CDF="cloudflared-linux-amd64" ;;
      aarch64|arm64) CDF="cloudflared-linux-arm64" ;;
    esac
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/${CDF}" -O bot
    chmod +x bot
    green "cloudflared 下载完成"
  fi
}

# 生成 sing-box 配置
generate_config() {
cat > config.json << EOF
{
  "log": { "disabled": true, "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8", "strategy": "ipv4_only", "detour": "direct" }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "tag": "vmess-ws-in",
      "type": "vmess",
      "listen": "::",
      "listen_port": $vmess_port,
      "users": [ { "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "/vmess" }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" },
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "server": "162.159.195.142",
      "server_port": 4198,
      "local_address": [ "172.16.0.2/32", "2606:4700:110:83c7:b31f:5858:b3a8:c6b1/128" ],
      "private_key": "mPZo+V9qlrMGCZ7+E6z2NI6NOV34PD++TpAR09PtCWI=",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": [26,21,228]
    }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": ["geosite-openai"], "outbound": "wireguard-out" },
      { "rule_set": ["geosite-netflix"], "outbound": "wireguard-out" },
      { "rule_set": ["geosite-category-ads-all"], "outbound": "block" }
    ],
    "rule_set": [
      { "tag": "geosite-netflix", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs", "download_detour": "direct" },
      { "tag": "geosite-openai", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs", "download_detour": "direct" },
      { "tag": "geosite-category-ads-all", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs", "download_detour": "direct" }
    ],
    "final": "direct"
  }
}
EOF
}

# 运行 sing-box 和 argo
run_sb() {
  cd "$WORKDIR"
  nohup ./web run -c config.json >/dev/null 2>&1 &
  sleep 2
  pgrep -x "web" >/dev/null && green "sing-box 已运行" || red "sing-box 启动失败"

  if [ -e bot ]; then
    if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
      args="tunnel run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
      args="tunnel --config tunnel.yml run"
    else
      args="tunnel --url http://localhost:$vmess_port"
    fi
    nohup ./bot $args >/dev/null 2>&1 &
    sleep 2
    pgrep -x "bot" >/dev/null && green "Argo 隧道已运行" || red "Argo 启动失败"
  fi
}

# 输出节点信息
get_links(){
  get_argodomain() {
    if [[ -n $ARGO_AUTH ]]; then echo "$ARGO_DOMAIN"; else grep -oE 'https://[[:alnum:]+\.-]+\.trycloudflare\.com' boot.log | sed 's@https://@@'; fi
  }
  argodomain=$(get_argodomain)
  echo -e "\e[1;32mArgoDomain:\e[1;35m${argodomain}\e[0m\n"

  IP=$(curl -s ipv4.ip.sb || curl -s --max-time 1 ipv6.ip.sb)
  ISP=$(curl -s https://speed.cloudflare.com/meta | awk -F\" '{print $26"-"$18}' | sed -e 's/ /_/g')

  cat > list.txt <<EOF
vmess://$(echo "{ \"v\": \"2\", \"ps\": \"$ISP\", \"add\": \"$IP\", \"port\": \"$vmess_port\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"\", \"path\": \"/vmess?ed=2048\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"$ISP\", \"add\": \"www.visa.com\", \"port\": \"443\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/vmess?ed=2048\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)

EOF
  cat list.txt
  purple "list.txt saved successfully"
}

# 主菜单
menu() {
   clear
   purple "=== Debian12 | vmess一键安装脚本 ==="
   green "1. 安装sing-box"
   red   "2. 卸载sing-box"
   yellow"3. 查看节点信息"
   red   "4. 清理所有进程"
   purple"0. 退出脚本"
   reading "请输入选择(0-4): " choice
    case "${choice}" in
        1) install_singbox ;;
        2) uninstall_singbox ;;
        3) cat $WORKDIR/list.txt ;;
        4) kill_all_tasks ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 4" ;;
    esac
}
menu
