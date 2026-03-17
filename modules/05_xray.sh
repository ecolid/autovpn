# =================================================================
# 模块: 05_xray.sh — Xray 安装 (Reality + WS-TLS)
# =================================================================

install_reality() {
    log_info ">>> 配置 VLESS-Reality (高性能/免域名)..."
    echo -e "${YELLOW}提示: Reality 模式不需要域名，适合追求纯粹速度和稳定性的用户。${PLAIN}"

    if [[ "$MODE" == "silent" ]]; then
        XRAY_PORT="${XRAY_PORT:-443}"
        FAKE_DOMAIN="${FAKE_DOMAIN:-www.cloudflare.com}"
        UUID="${UUID:-$(uuidgen)}"
    else
        echo -e "\n${BLUE}[配置 1/3] 用户 ID (UUID)${PLAIN}"
        echo -e "说明: 相当于你的连接密码。建议直接回车使用默认生成的随机 ID。"
        read -p "请输入 UUID [默认: ${EXISTING_UUID:-$(uuidgen)}]: " UUID
        UUID="${UUID:-${EXISTING_UUID:-$(uuidgen)}}"

        echo -e "\n${BLUE}[配置 2/3] 监听端口 (Port)${PLAIN}"
        echo -e "说明: 建议使用 443 端口以获得最佳伪装效果。"
        echo -e "${RED}注意：如果你的 443 端口已被 Nginx/宝塔或其他程序占用，请更换其他端口（如 10000+）。${PLAIN}"
        read -p "请输入端口 [默认: ${EXISTING_PORT:-443}]: " XRAY_PORT
        XRAY_PORT="${XRAY_PORT:-${EXISTING_PORT:-443}}"

        echo -e "\n${BLUE}[配置 3/3] 伪装域名 (SNI)${PLAIN}"
        echo -e "说明: 你的 VPS 将伪装成访问此域名的流量。国内用户建议用 www.cloudflare.com 或 www.lovelinux.com。"
        read -p "请输入伪装域名 [默认: ${EXISTING_SNI:-www.cloudflare.com}]: " FAKE_DOMAIN
        FAKE_DOMAIN="${FAKE_DOMAIN:-${EXISTING_SNI:-www.cloudflare.com}}"
    fi

    log_info "正在应用配置并启动服务..."

    # 下载 Xray
    if [ ! -f "/usr/local/bin/xray" ]; then
        log_info "正在下载 Xray 核心..."
        curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o /tmp/xray.zip
        unzip -o /tmp/xray.zip -d /usr/local/bin/ xray > /dev/null
    fi

    # 生成密钥对
    KEYS=$(/usr/local/bin/xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)

    # 写入 Xray 配置
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "port": $XRAY_PORT, "protocol": "vless", "tag": "proxy",
      "settings": { "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "$FAKE_DOMAIN:443", "xver": 0,
          "serverNames": ["$FAKE_DOMAIN"], "privateKey": "$PRIVATE_KEY", "shortIds": ["$SHORT_ID"]
        }
      }
    },
    { "port": 10085, "listen": "127.0.0.1", "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "routing": { "rules": [{ "inboundTag": ["api"], "outboundTag": "api", "type": "field" }] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

    # Systemd service
    cat > /etc/systemd/system/xray.service <<EOF
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
    log_info "✅ Xray 核心配置已更新"

    # 更新 Guardian
    setup_guardian_bot
    log_info "✅ Guardian 守护进程已更新"

    open_ports $XRAY_PORT
    save_env

    # 输出链接
    IP=$(curl -s https://ipv4.icanhazip.com)
    LINK="vless://${UUID}@${IP}:${XRAY_PORT}?encryption=none&security=reality&sni=${FAKE_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#AutoVPN_Reality"

    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "=========================================================="

    send_tg_msg "✅ *AutoVPN Reality 部署成功!*\n\n📍 *IP:* ${IP}\n🔑 *UUID:* ${UUID}\n🔗 *链接:* \`${LINK}\`"
}

install_ws_tls() {
    local XRAY_LISTEN_PORT=10000
    XRAY_PORT=443
    log_info ">>> 配置 VLESS-WS-TLS (CDN/强伪装)..."
    echo -e "${YELLOW}提示: 此模式需要你已将域名托管到 Cloudflare。适合在极端网络坏境下使用。${PLAIN}"

    if [[ "$MODE" == "silent" ]]; then
        DOMAIN="${DOMAIN:-$EXISTING_DOMAIN}"
        UUID="${UUID:-$EXISTING_UUID}"
        CF_TOKEN="${CF_TOKEN}"
        [[ -z "$DOMAIN" ]] && { log_err "静默模式安装 WS-TLS 必须提供 --domain 参数"; exit 1; }
        [[ -z "$CF_TOKEN" ]] && { log_err "静默模式安装 WS-TLS 必须提供 Cloudflare Token"; exit 1; }
        WS_PATH="${WS_PATH:-${EXISTING_PATH:-/lovelinux}}"
    else
        echo -e "\n${BLUE}[配置 1/4] 你的域名 (Domain)${PLAIN}"
        echo -e "说明: 必须是已托管在 Cloudflare 的域名 (如: node1.example.com)。"
        echo -e "注意: 请确保你在 CF 中已将该域名解析到本服务器 IP，且开启或关闭云朵(Proxy)均可。"
        read -p "请输入域名 [当前: ${EXISTING_DOMAIN:-example.com}]: " DOMAIN
        DOMAIN="${DOMAIN:-${EXISTING_DOMAIN}}"
        if [ -z "$DOMAIN" ]; then log_err "错误: 域名不能为空"; exit 1; fi

        echo -e "\n${BLUE}[配置 2/4] Cloudflare API Token${PLAIN}"
        echo -e "说明: 用于自动管理该域名的解析记录。权限至少需要 '区域-DNS-编辑'。"
        echo -e "获取: 请访问 https://dash.cloudflare.com/profile/api-tokens 创建。"
        read -p "请输入 API Token [当前: ${CF_TOKEN:-(未填)}]: " INPUT_TOKEN
        CF_TOKEN="${INPUT_TOKEN:-${CF_TOKEN}}"
        if [ -z "$CF_TOKEN" ]; then log_err "错误: Token 不能为空"; exit 1; fi

        echo -e "\n${BLUE}[配置 3/4] 用户 ID (UUID)${PLAIN}"
        echo -e "说明: 相当于你的连接密码。建议直接回车使用系统生成的推荐 ID。"
        read -p "请输入 UUID [默认: ${EXISTING_UUID:-$(uuidgen)}]: " UUID
        UUID="${UUID:-${EXISTING_UUID:-$(uuidgen)}}"

        WS_PATH="${WS_PATH:-${EXISTING_PATH:-/lovelinux}}"
    fi
    log_info "正在执行自动化部署任务 (同步 DNS、申请证书、配置 Nginx)..."

    # 优先更新核心配置
    log_info "更新 Xray 核心配置..."
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "port": $XRAY_LISTEN_PORT, "listen": "127.0.0.1", "protocol": "vless", "tag": "proxy",
      "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    },
    { "port": 10085, "listen": "127.0.0.1", "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "routing": { "rules": [{ "inboundTag": ["api"], "outboundTag": "api", "type": "field" }] },
  "outbounds": [
    { "tag": "warp", "protocol": "socks", "settings": { "servers": [{"address": "127.0.0.1", "port": 40000}] } },
    { "tag": "direct", "protocol": "freedom" }
  ]
}
EOF

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray -config /usr/local/etc/xray/config.json
Restart=on-failure
User=root
EOF
    systemctl daemon-reload && systemctl enable xray && systemctl restart xray
    log_info "✅ Xray 核心配置已更新"

    # 更新 Guardian
    setup_guardian_bot
    log_info "✅ Guardian 守护进程已更新"

    if [[ "$MODE" == "silent" ]]; then
        decoy_choice="Y"
    else
        echo -e "\n${BLUE}[配置 4/4] 网站伪装页面${PLAIN}"
        echo -e "说明：AutoVPN 默认提供一个 2048 小游戏的伪装页面，访问你的域名会显示正常游戏。"
        read -p "是否部署此伪装页面？ [Y/n]: " decoy_choice
        decoy_choice="${decoy_choice:-Y}"
    fi

    # 环境清理
    systemctl stop nginx || true
    rm -f /etc/nginx/sites-enabled/default

    # DNS 解析
    IP=$(curl -s https://ipv4.icanhazip.com)
    log_info "正在同步 Cloudflare DNS: $DOMAIN -> $IP"

    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
         -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
        log_err "⚠️ 无法获取 Zone ID，跳过 DNS 同步（核心配置已更新）"
    else
        RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=A" \
             -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')

        if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
            curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
                 -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
                 --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":true}" > /dev/null
        else
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                 -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
                 --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":true}" > /dev/null
        fi
    fi

    # WARP
    manage_warp "install"

    # SSL 证书
    log_info "检查 SSL 证书..."
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then curl https://get.acme.sh | sh; fi
    export CF_Token="$CF_TOKEN"
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN --dnssleep 10 --force || true
    mkdir -p /etc/ssl/$DOMAIN
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/ssl/$DOMAIN/privkey.pem --fullchain-file /etc/ssl/$DOMAIN/fullchain.pem --reloadcmd "systemctl reload nginx" || true

    # Nginx 伪装
    log_info "配置 Nginx 伪装页..."
    mkdir -p /var/www/html
    if [[ "$decoy_choice" =~ ^[Yy]$ ]]; then
        curl -L -o /var/www/html/index.html "https://raw.githubusercontent.com/cx88/2048/master/index.html"
    else
        echo "AutoVPN Working Perfectly" > /var/www/html/index.html
    fi
    cat > /etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/ssl/$DOMAIN/privkey.pem;
    location / { root /var/www/html; index index.html; }
    location $WS_PATH {
        proxy_redirect off; proxy_pass http://127.0.0.1:$XRAY_LISTEN_PORT;
        proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade"; proxy_set_header Host \$host;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
    nginx -t && systemctl restart nginx
    save_env

    # 输出链接
    LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=$(echo $WS_PATH | sed 's/\//%2F/g')#AutoVPN_WS_CDN"
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "=========================================================="

    send_tg_msg "✅ *AutoVPN WS-TLS 部署成功!*\n\n📍 *域名:* ${DOMAIN}\n🔑 *UUID:* ${UUID}\n🔗 *链接:* \`${LINK}\`"
}
