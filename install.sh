#!/bin/bash

set -e
set -x

export DEBIAN_FRONTEND=noninteractive

echo "=== VPS 初始化开始 ==="

# 更新系统
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confold"
#BBR设置
echo "=== 开启 BBR ==="

if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  echo "BBR 已开启"
else
  echo "BBR 已存在，跳过"
fi
# 安装基础工具
apt-get install -y curl wget unzip

# 安装 Xray（安全方式）
echo "=== 安装 Xray ==="
curl -L -o install-release.sh https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh
bash install-release.sh

# 生成 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 Reality 密钥（更稳解析）
KEY_PAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | awk -F': ' '/PrivateKey/ {print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | awk -F': ' '/PublicKey/ {print $2}')

if [ -z "$PRIVATE_KEY" ]; then
  echo "ERROR: PRIVATE_KEY 解析失败"
  exit 1
fi

# 获取 IP（带 fallback）
IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me)

# 参数（以后你可以一键改）
PORT=8443
DEST_DOMAIN="www.bing.com"
SHORT_ID="6ba85179e30d4fc2"

# 开端口（某些 VPS 必须）
ufw allow ${PORT}/tcp 2>/dev/null || true

# 确保目录存在
mkdir -p /usr/local/etc/xray

# 写配置文件
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "tcp",
        "security": "reality",

        "realitySettings": {
          "show": false,
          "dest": "$DEST_DOMAIN:443",
          "xver": 0,

          "serverNames": [
            "$DEST_DOMAIN"
          ],

          "privateKey": "$PRIVATE_KEY",

          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 启动 Xray
systemctl enable xray
systemctl restart xray

echo "=== Xray 启动完成 ==="

# 生成 Clash YAML（完整配置）
cat > /root/clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info

dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

proxies:
  - name: Reality-$IP-$PORT
    type: vless
    server: $IP
    port: $PORT
    uuid: $UUID

    network: tcp
    tls: true
    udp: true

    flow: xtls-rprx-vision
    servername: $DEST_DOMAIN
    client-fingerprint: chrome

    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Reality-$IP-$PORT

rules:
  - MATCH,Proxy
EOF

echo
echo "===== 部署完成 ====="
echo "IP: $IP"
echo "PORT: $PORT"
echo "UUID: $UUID"
echo "PublicKey: $PUBLIC_KEY"
echo
echo "配置文件:"
echo "/root/clash.yaml"
echo
echo "下载命令:"
echo "scp root@$IP:/root/clash.yaml ."
echo