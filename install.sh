#!/usr/bin/env bash
set -e

# =================================================================
# AutoVPN - 一键部署 VLESS + WS + TLS + WARP 代理
# =================================================================
# 用法：
#   交互式：bash install.sh
#   静默式：bash install.sh --domain example.com --cf-token xxx --uuid xxx
#   curl：  curl -sL https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh | bash
# =================================================================

VERSION="v2.0.0"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
log_err()  { echo -e "${RED}[ERROR]${PLAIN} $1"; }

# =================================================================
# 0. 检查环境
# =================================================================
if [[ $EUID -ne 0 ]]; then
    log_err "请使用 root 权限运行 (sudo -i)"
    exit 1
fi

# =================================================================
# 1. 参数解析（支持命令行传参或交互输入）
# =================================================================
XRAY_PORT=8443
WARP_PORT=40000
WS_PATH="/lovelinux"

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)   DOMAIN="$2";   shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --email)    EMAIL="$2";    shift 2 ;;
        --uuid)     UUID="$2";     shift 2 ;;
        --ws-path)  WS_PATH="$2";  shift 2 ;;
        --port)     XRAY_PORT="$2"; shift 2 ;;
        --nezha-server) NEZHA_SERVER="$2"; shift 2 ;;
        --nezha-secret) NEZHA_SECRET="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# 交互式输入（如果参数未提供）
if [ -z "$DOMAIN" ]; then
    read -rp "请输入域名 (例如 example.com): " DOMAIN
fi
if [ -z "$CF_TOKEN" ]; then
    read -rp "请输入 Cloudflare API Token: " CF_TOKEN
fi
if [ -z "$EMAIL" ]; then
    read -rp "请输入邮箱 (用于 SSL 证书): " EMAIL
fi
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    log_info "自动生成 UUID: $UUID"
fi

# 参数校验
if [ -z "$DOMAIN" ] || [ -z "$CF_TOKEN" ] || [ -z "$EMAIL" ]; then
    log_err "域名、CF Token、邮箱为必填项"
    exit 1
fi

echo ""
log_info "========== 部署参数 =========="
log_info "域名:     $DOMAIN"
log_info "UUID:     $UUID"
log_info "WS 路径:  $WS_PATH"
log_info "Xray 端口: $XRAY_PORT"
log_info "=============================="
echo ""

# =================================================================
# 2. 系统初始化
# =================================================================
log_info ">>> [1/7] 初始化系统环境..."
apt update -y
apt install -y curl unzip socat nginx jq uuid-runtime gnupg lsb-release

# 清理默认 nginx 配置
systemctl stop nginx 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/default

# =================================================================
# 3. DNS 解析
# =================================================================
log_info ">>> [2/7] 配置 DNS 解析..."
CURRENT_IP=$(curl -s https://ipv4.icanhazip.com)

ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
    log_err "无法获取域名 $DOMAIN 的 Zone ID，请检查 CF Token 权限"
    exit 1
fi

RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=A" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
    log_info "创建 DNS 记录: $DOMAIN -> $CURRENT_IP"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":true}" > /dev/null
else
    log_info "更新 DNS 记录: $DOMAIN -> $CURRENT_IP (CDN 已开启)"
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":true}" > /dev/null
fi

# =================================================================
# 4. WARP
# =================================================================
log_info ">>> [3/7] 部署 WARP 出口隧道..."
if ! command -v warp-cli &> /dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt update -y && apt install -y cloudflare-warp
fi

systemctl stop warp-svc 2>/dev/null || true
rm -rf /var/lib/cloudflare-warp/conf.json
systemctl start warp-svc
sleep 5

warp-cli --accept-tos registration new 2>/dev/null || true
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port $WARP_PORT
warp-cli --accept-tos connect

sleep 3
if warp-cli --accept-tos status | grep -q "Connected"; then
    log_info "WARP 连接成功 (Socks5: 127.0.0.1:$WARP_PORT)"
else
    log_warn "WARP 连接中，可能需要几秒钟..."
fi

# =================================================================
# 5. Xray
# =================================================================
log_info ">>> [4/7] 安装 Xray..."
curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o /tmp/xray.zip
unzip -o /tmp/xray.zip -d /usr/local/bin/ xray
rm -f /tmp/xray.zip
mkdir -p /usr/local/etc/xray /var/log/xray

tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "loglevel": "warning" },
  "inbounds": [{
    "port": $XRAY_PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
  }],
  "outbounds": [
    {
      "tag": "warp_out",
      "protocol": "socks",
      "settings": { "servers": [{ "address": "127.0.0.1", "port": $WARP_PORT }] }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "warp_out", "network": "tcp,udp" }
    ]
  }
}
EOF

tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray -config /usr/local/etc/xray/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable xray && systemctl restart xray

# =================================================================
# 6. SSL 证书
# =================================================================
log_info ">>> [5/7] 申请 SSL 证书..."
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    curl https://get.acme.sh | sh
fi

export CF_Token="$CF_TOKEN"
~/.acme.sh/acme.sh --register-account -m "$EMAIL" --server zerossl 2>/dev/null || true
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --dnssleep 30 --force

mkdir -p /etc/ssl/$DOMAIN
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/ssl/$DOMAIN/privkey.pem \
    --fullchain-file /etc/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx" || true

chown -R www-data:www-data /etc/ssl/$DOMAIN
chmod -R 755 /etc/ssl/$DOMAIN

# =================================================================
# 7. Nginx
# =================================================================
log_info ">>> [6/7] 配置 Nginx..."
tee /etc/nginx/sites-available/$DOMAIN.conf > /dev/null <<NGINX
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/ssl/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        root /var/www/html;
        index index.html;
    }

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX

mkdir -p /var/www/html
echo "<center><h1>Welcome</h1></center>" > /var/www/html/index.html

ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx && systemctl enable nginx

# =================================================================
# 8. 哪吒监控 Agent（可选）
# =================================================================
log_info ">>> [7/7] 安装哪吒监控 Agent..."

if [ -z "$NEZHA_SERVER" ]; then
    echo ""
    read -rp "是否安装哪吒监控 Agent？[y/N]: " INSTALL_NEZHA
    if [[ "$INSTALL_NEZHA" =~ ^[Yy]$ ]]; then
        read -rp "哪吒面板地址 (例如 nezha.example.com:8008): " NEZHA_SERVER
        read -rp "Agent Secret: " NEZHA_SECRET
    fi
fi

if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_SECRET" ]; then
    curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o /tmp/nezha-agent.sh
    chmod +x /tmp/nezha-agent.sh
    env NZ_SERVER="$NEZHA_SERVER" NZ_TLS=false NZ_CLIENT_SECRET="$NEZHA_SECRET" /tmp/nezha-agent.sh
    rm -f /tmp/nezha-agent.sh
    log_info "哪吒 Agent 安装完成"
else
    log_warn "跳过哪吒 Agent 安装"
fi

# =================================================================
# 9. 完成，输出连接信息
# =================================================================
CURRENT_IP=$(curl -s https://ipv4.icanhazip.com)
ENCODED_PATH=$(echo "$WS_PATH" | sed 's/\//%2F/g')
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${ENCODED_PATH}#${DOMAIN}_WARP"

echo ""
echo "=========================================================="
echo -e "${GREEN} AutoVPN $VERSION 部署成功${PLAIN}"
echo "=========================================================="
echo -e "域名       : ${GREEN}${DOMAIN}${PLAIN} (IP: $CURRENT_IP)"
echo -e "端口       : ${GREEN}443${PLAIN}"
echo -e "UUID       : ${GREEN}${UUID}${PLAIN}"
echo -e "路径       : ${GREEN}${WS_PATH}${PLAIN}"
echo -e "TLS        : ${GREEN}开启${PLAIN}"
echo -e "WARP       : $(warp-cli --accept-tos status 2>/dev/null | grep -q Connected && echo -e "${GREEN}已连接${PLAIN}" || echo -e "${YELLOW}连接中${PLAIN}")"
echo "=========================================================="
echo -e "${YELLOW}复制下方链接，在 v2rayN / Shadowrocket 中导入：${PLAIN}"
echo ""
echo "$VLESS_LINK"
echo ""
echo "=========================================================="
