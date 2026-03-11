#!/usr/bin/env bash
set -e

# =================================================================
# AutoVPN - 一键 VPS 代理配置脚本
# 功能：VLESS-Reality (TCP) & VLESS-WS-TLS (CDN)
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] $1${PLAIN}"; }

# 信号捕获 (Ctrl+C 退出提示)
cleanup() {
    echo -e "\n${YELLOW}检测到脚本被中断。配置未完成，你可以随时再次运行脚本继续安装。${PLAIN}"
    exit 0
}
trap cleanup SIGINT SIGTERM

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   log_err "请使用 root 权限运行此脚本 (sudo -i)"
   exit 1
fi

# =================================================================
# 0. 配置文件加载与检测
# =================================================================
CONFIG_PATH="/usr/local/etc/xray/config.json"
ENV_PATH="/usr/local/etc/autovpn/.env"

load_config() {
    # 1. 基础检测：扫描常见的代理核心和其配置文件
    CORES=()
    DISCOVERY_INFO=""
    
    # 扫描函数：尝试从路径提取端口和协议
    scan_ext_config() {
        local name=$1
        local path=$2
        if [ -f "$path" ]; then
            local p=$(jq -r '.inbounds[0].port' "$path" 2>/dev/null || grep -oP '"port":\s*\d+' "$path" | head -n1 | grep -oP '\d+' || echo "未知")
            local proto=$(jq -r '.inbounds[0].protocol' "$path" 2>/dev/null || grep -oP '"protocol":\s*"[^"]+"' "$path" | head -n1 | grep -oP '"[^"]+"$' | tr -d '"' || echo "未知")
            DISCOVERY_INFO+="\n    - ${name}: 路径=$path, 端口=$p, 协议=$proto"
        fi
    }

    [ -f "/usr/local/bin/xray" ] || [ -f "/etc/systemd/system/xray.service" ] && { CORES+=("Xray"); scan_ext_config "Xray" "/usr/local/etc/xray/config.json"; scan_ext_config "Xray" "/etc/xray/config.json"; }
    [ -f "/usr/local/bin/v2ray" ] || [ -f "/etc/systemd/system/v2ray.service" ] && { CORES+=("V2ray"); scan_ext_config "V2ray" "/usr/local/etc/v2ray/config.json"; scan_ext_config "V2ray" "/etc/v2ray/config.json"; }
    [ -f "/usr/local/bin/sing-box" ] || [ -f "/etc/systemd/system/sing-box.service" ] && { CORES+=("Sing-box"); scan_ext_config "Sing-box" "/etc/sing-box/config.json"; }
    
    if [ ${#CORES[@]} -gt 0 ]; then
        EXISTING_CORES_STR=$(IFS=,; echo "${CORES[*]}")
        EXISTING_XRAY_FOUND=true
    fi

    # 2. 检查是否由 AutoVPN 管理 (读取 .env 文件 OR 检查当前已定义的关键环境变量)
    if [ -f "$ENV_PATH" ]; then
        IS_MANAGED_BY_AUTOVPN=true
        source "$ENV_PATH"
    fi

    if [ ! -z "$DOMAIN" ] || [ ! -z "$UUID" ] || [ ! -z "$CF_TOKEN" ]; then
        IS_MANAGED_BY_AUTOVPN=true
    fi

    # 3. 处理未管理的情况
    if [ "$EXISTING_XRAY_FOUND" == "true" ] && [ "$IS_MANAGED_BY_AUTOVPN" != "true" ]; then
        echo -e "${YELLOW}检测到服务器已安装非脚本管理的代理核心: [ ${EXISTING_CORES_STR} ]${PLAIN}"
        if [ ! -z "$DISCOVERY_INFO" ]; then
            echo -e "${BLUE}探测到的详细信息:${PLAIN}${DISCOVERY_INFO}"
        fi
        echo -e "\n${YELLOW}注: AutoVPN 使用 Xray 核心。接管将停止并禁用上述服务，按本脚本规范重新配置。${PLAIN}"
        read -p "是否允许 AutoVPN 接管管理权并转换至 Xray 架构？ [y/N]: " takeover
        if [[ "$takeover" =~ ^[Yy]$ ]]; then
            log_info "正在停用旧服务并接管管理权..."
            systemctl stop xray v2ray sing-box 2>/dev/null || true
            systemctl disable xray v2ray sing-box 2>/dev/null || true
            mkdir -p /usr/local/etc/autovpn
            touch "$ENV_PATH"
            IS_MANAGED_BY_AUTOVPN=true
        else
            log_warn "已取消接管。脚本将退出以防冲突。"
            exit 0
        fi
    fi

    # 4. 如果已管理，解析现有配置
    if [ "$IS_MANAGED_BY_AUTOVPN" == "true" ] && [ -f "$CONFIG_PATH" ]; then
        # 尝试检测 Xray 配置类型
        if grep -q "reality" "$CONFIG_PATH"; then
            EXISTING_MODE="Reality"
            EXISTING_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_PATH" 2>/dev/null)
            EXISTING_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_PATH" 2>/dev/null)
            EXISTING_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_PATH" 2>/dev/null)
        elif grep -q "\"ws\"" "$CONFIG_PATH"; then
            EXISTING_MODE="WS-TLS"
            EXISTING_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_PATH" 2>/dev/null)
            EXISTING_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$CONFIG_PATH" 2>/dev/null)
            EXISTING_DOMAIN=$(ls /etc/nginx/sites-available/ | grep ".conf" | head -n 1 | sed 's/.conf//')
        fi
    fi
}

save_env() {
    mkdir -p /usr/local/etc/autovpn
    cat > "$ENV_PATH" <<EOF
CF_TOKEN="$CF_TOKEN"
DOMAIN="$DOMAIN"
UUID="$UUID"
EOF
}

# =================================================================
# 1. 环境初始化与优化
# =================================================================
optimize_system() {
    log_info ">>> 进入系统环境优化..."
    
    # 安装基础依赖
    apt update -y > /dev/null
    apt install -y curl unzip socat nginx git uuid-runtime gnupg lsb-release jq openssl > /dev/null

    # 1.1 BBR 加速检查
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_info "检查：系统已启用 BBR 加速，跳过。"
    else
        echo -e "\n${YELLOW}【重要】风险提示：开启 BBR 加速${PLAIN}"
        echo -e "说明：BBR 是 Google 开发的拥塞控制算法，能显著提升丢包环境下的吞吐量。"
        echo -e "风险：在极少数 OpenVZ 架构或内核过旧的服务器上，强制修改参数可能导致网络连接异常。"
        read -p "是否尝试开启 BBR 加速？ [Y/n]: " bbr_choice
        if [[ ! "$bbr_choice" =~ ^[Nn]$ ]]; then
            log_info "正在开启 BBR..."
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p > /dev/null || log_warn "BBR 提交失败，可能你的内核版本过低。"
            log_info "✅ BBR 优化步骤完成"
        fi
    fi

    # 1.2 Swap 虚拟内存检查
    local current_swap=$(swapon --show --noheadings | wc -l)
    if [ "$current_swap" -gt 0 ]; then
        log_info "检查：系统已存在 Swap，跳过。"
    else
        local mem_total=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$mem_total" -le 1024 ]; then
            echo -e "\n${YELLOW}【重要】风险提示：开启 Swap 虚拟内存${PLAIN}"
            echo -e "说明：检测到你的内存小于 1GB。开启 Swap 可以防止因内存溢出导致的进程（如 Xray）崩溃。"
            echo -e "影响：将占用 2GB 硬盘空间。风险：对于磁盘 IO 极差的服务器，频繁交换可能导致系统卡顿。"
            read -p "是否创建 2GB Swap？ [Y/n]: " swap_choice
            if [[ ! "$swap_choice" =~ ^[Nn]$ ]]; then
                log_info "正在创建 2GB Swap..."
                fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
                log_info "✅ Swap 创建成功"
            fi
        fi
    fi
}

# 模式对比导览
show_comparison() {
    echo -e "${BLUE}=================== 代理模式深度对比 ===================${PLAIN}"
    echo -e "${GREEN}1. VLESS-Reality (高性能免域名专线)${PLAIN}"
    echo -e "   - ${BLUE}适用场景：${PLAIN}追求极速体验，不想购买或维护域名。"
    echo -e "   - ${BLUE}工作原理：${PLAIN}完美的流控伪装，使 VPS 看起来像是在访问知名大厂网站。"
    echo -e "   - ${BLUE}优/缺点：${PLAIN}速度最快（原生 TCP），抗封锁强，但不支持 CDN 转发。"
    echo ""
    echo -e "${GREEN}2. VLESS-WS-TLS (CDN 级强力避风港)${PLAIN}"
    echo -e "   - ${BLUE}适用场景：${PLAIN}敏感时期，或 VPS 的 IP 已经被墙时使用。"
    echo -e "   - ${BLUE}工作原理：${PLAIN}将流量封包在标准 HTTPS 请求中，可通过 Cloudflare 节点转发。"
    echo -e "   - ${BLUE}优/缺点：${PLAIN}生存力极强，支持 CDN 救活 IP，但延迟比 Reality 稍高。"
    echo -e "${BLUE}========================================================${PLAIN}"
}

# =================================================================
# 2. VLESS-Reality 部署模块
# =================================================================
install_reality() {
    log_info ">>> 配置 VLESS-Reality (高性能/免域名)..."
    echo -e "${YELLOW}提示: Reality 模式不需要域名，适合追求纯粹速度和稳定性的用户。${PLAIN}"
    
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
    
    log_info "正在应用配置并启动服务..."
    
    # 获取密钥对
    if [ ! -f "/usr/local/bin/xray" ]; then
        log_info "正在下载 Xray 核心..."
        curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -o /tmp/xray.zip
        unzip -o /tmp/xray.zip -d /usr/local/bin/ xray > /dev/null
    fi
    
    KEYS=$(/usr/local/bin/xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 4)

    # 写入 Xray 配置
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$FAKE_DOMAIN:443",
        "xver": 0,
        "serverNames": ["$FAKE_DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # 配置 Systemd
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
    save_env
    
    # 结果输出
    IP=$(curl -s https://ipv4.icanhazip.com)
    LINK="vless://${UUID}@${IP}:${XRAY_PORT}?encryption=none&security=reality&sni=${FAKE_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#AutoVPN_Reality"
    
    echo -e "\n${GREEN}==========================================================${PLAIN}"
    echo -e "${GREEN}🎉 Reality 部署/更新成功！${PLAIN}"
    echo -e "UUID: ${BLUE}$UUID${PLAIN}"
    echo -e "\n分享链接 (直接复制导入):"
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "${GREEN}==========================================================${PLAIN}"
}

# =================================================================
# 3. VLESS-WS-TLS + CDN 部署模块
# =================================================================
install_ws_tls() {
    log_info ">>> 配置 VLESS-WS-TLS (CDN/强伪装)..."
    echo -e "${YELLOW}提示: 此模式需要你已将域名托管到 Cloudflare。适合在极端网络坏境下使用。${PLAIN}"
    
    echo -e "\n${BLUE}[配置 1/4] 你的域名${PLAIN}"
    echo -e "说明: 必须是已在 Cloudflare 解析并托管的域名 (例如: vps.example.com)。"
    read -p "请输入域名 [当前: ${EXISTING_DOMAIN:-example.com}]: " DOMAIN
    DOMAIN="${DOMAIN:-${EXISTING_DOMAIN}}"
    if [ -z "$DOMAIN" ]; then log_err "错误: 域名不能为空"; exit 1; fi

    echo -e "\n${BLUE}[配置 2/4] Cloudflare API Token${PLAIN}"
    echo -e "说明: 用于自动修改 DNS 记录和申请证书。需要 '区域.DNS:编辑' 权限。"
    read -p "请输入 API Token [当前: ${CF_TOKEN:-(未填)}]: " INPUT_TOKEN
    CF_TOKEN="${INPUT_TOKEN:-${CF_TOKEN}}"
    if [ -z "$CF_TOKEN" ]; then log_err "错误: Token 不能为空"; exit 1; fi
    
    echo -e "\n${BLUE}[配置 3/4] 用户 ID (UUID)${PLAIN}"
    echo -e "说明: 建议直接回车使用系统生成的推荐 ID。"
    read -p "请输入 UUID [默认: ${EXISTING_UUID:-$(uuidgen)}]: " UUID
    UUID="${UUID:-${EXISTING_UUID:-$(uuidgen)}}"
    
    WS_PATH="${WS_PATH:-${EXISTING_PATH:-/lovelinux}}"
    log_info "正在执行自动化部署任务 (同步 DNS、申请证书、配置 Nginx)..."
    
    # 4. 可选伪装页面
    echo -e "\n${BLUE}[配置 4/4] 网站伪装页面${PLAIN}"
    echo -e "说明：AutoVPN 默认提供一个 2048 小游戏的伪装页面，访问你的域名会显示正常游戏。"
    read -p "是否部署此伪装页面？ [Y/n]: " decoy_choice
    decoy_choice="${decoy_choice:-Y}"

    # 环境清理
    systemctl stop nginx || true
    systemctl stop nginx || true
    rm -f /etc/nginx/sites-enabled/default

    # 自动 DNS 解析
    IP=$(curl -s https://ipv4.icanhazip.com)
    log_info "正在同步 Cloudflare DNS: $DOMAIN -> $IP"
    
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
         -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" | jq -r '.result[0].id')
    
    if [ "$ZONE_ID" == "null" ] || [ -z "$ZONE_ID" ]; then
        log_err "无法获取 Zone ID，请检查域名和 Token。"
        exit 1
    fi
    
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

    # 部署 WARP
    manage_warp "install"

    # 申请证书
    log_info "申请 SSL 证书..."
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then curl https://get.acme.sh | sh; fi
    export CF_Token="$CF_TOKEN"
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN --dnssleep 10 --force
    mkdir -p /etc/ssl/$DOMAIN
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/ssl/$DOMAIN/privkey.pem --fullchain-file /etc/ssl/$DOMAIN/fullchain.pem --reloadcmd "systemctl reload nginx" || true

    # Xray 配置
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XRAY_LISTEN_PORT, "listen": "127.0.0.1", "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
  }],
  "outbounds": [
    { "tag": "warp", "protocol": "socks", "settings": { "servers": [{"address": "127.0.0.1", "port": $WARP_PORT}] } },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": { "rules": [{ "type": "field", "outboundTag": "warp", "network": "tcp,udp" }] }
}
EOF
    systemctl daemon-reload && systemctl enable xray && systemctl restart xray

    # Nginx + 2048 伪装
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

    # 结果
    LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=$(echo $WS_PATH | sed 's/\//%2F/g')#AutoVPN_WS_CDN"
    echo -e "\n${GREEN}==========================================================${PLAIN}"
    echo -e "${GREEN}🎉 VLESS-WS-TLS 部署/更新成功！${PLAIN}"
    echo -e "域名: ${BLUE}$DOMAIN${PLAIN}"
    echo -e "\n分享链接 (直接复制导入):"
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "${GREEN}==========================================================${PLAIN}"
}

# =================================================================
# 4. WARP 管理模块
# =================================================================
manage_warp() {
    local action="$1"
    
    if [ "$action" == "install" ]; then
        if ! command -v warp-cli &> /dev/null; then
            log_info "安装 Cloudflare WARP..."
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
            apt update -y && apt install -y cloudflare-warp
        fi
        systemctl enable warp-svc && systemctl restart warp-svc && sleep 3
        warp-cli --accept-tos registration new || true
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port 40000
        warp-cli --accept-tos connect
    elif [ "$action" == "refresh" ]; then
        log_info "正在刷新 WARP 节点 IP..."
        warp-cli --accept-tos disconnect
        sleep 2
        warp-cli --accept-tos connect
        log_info "✅ 已发起重连"
    elif [ "$action" == "reset" ]; then
        log_info "正在重置 WARP 注册信息..."
        warp-cli --accept-tos registration new
        log_info "✅ 注册信息已更新"
    fi
}

# =================================================================
# 主菜单
# =================================================================
load_config
clear
echo -e "${BLUE}##########################################################${PLAIN}"
echo ""

show_comparison
echo ""

if [ ! -z "$EXISTING_MODE" ]; then
    echo -e "当前安装状态:"
    echo -e "  - 模式: ${GREEN}$EXISTING_MODE${PLAIN}"
    echo -e "  - UUID: ${YELLOW}$EXISTING_UUID${PLAIN}"
    [ ! -z "$EXISTING_DOMAIN" ] && echo -e "  - 域名: ${YELLOW}$EXISTING_DOMAIN${PLAIN}"
    [ ! -z "$EXISTING_PORT" ] && echo -e "  - 端口: ${YELLOW}$EXISTING_PORT${PLAIN}"
    [ ! -z "$EXISTING_PATH" ] && echo -e "  - 路径: ${YELLOW}$EXISTING_PATH${PLAIN}"
    
    # 增加状态检查
    XRAY_STATUS=$(systemctl is-active xray || echo "inactive")
    NGINX_STATUS=$(systemctl is-active nginx || echo "inactive")
    WARP_STATUS=$(systemctl is-active warp-svc || echo "inactive")
    
    echo -n "  - 服务: "
    [ "$XRAY_STATUS" == "active" ] && echo -en "${GREEN}Xray(√)${PLAIN} " || echo -en "${RED}Xray(×)${PLAIN} "
    if [ "$EXISTING_MODE" == "WS-TLS" ]; then
        [ "$NGINX_STATUS" == "active" ] && echo -en "${GREEN}Nginx(√)${PLAIN} " || echo -en "${RED}Nginx(×)${PLAIN} "
    fi
    [ "$WARP_STATUS" == "active" ] && echo -en "${GREEN}WARP(√)${PLAIN}" || echo -en "${RED}WARP(×)${PLAIN}"
    echo ""

    if [ "$WARP_STATUS" == "active" ]; then
        WARP_IP=$(curl -s --socks5 127.0.0.1:40000 https://ipv4.icanhazip.com || echo "获取失败")
        echo -e "  - WARP 出口 IP: ${BLUE}$WARP_IP${PLAIN}"
    fi

    echo ""
    echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前模式 (可修改配置)"
    echo -e "  ${GREEN}2.${PLAIN} 切换到另一种模式"
    echo -e "  ${GREEN}3.${PLAIN} 刷新 WARP 出口 IP"
    echo -e "  ${GREEN}4.${PLAIN} 重置 WARP 注册信息"
    echo -e "  ${GREEN}5.${PLAIN} 卸载 AutoVPN (清理 Xray/Nginx)"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
else
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS-Reality (推荐：简单/免域名/高性能)"
    echo -e "  ${GREEN}2.${PLAIN} 安装 VLESS-WS-TLS (CDN/强伪装/需已有域名)"
    echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
fi

echo ""
read -p "请输入数字: " choice

if [ ! -z "$EXISTING_MODE" ]; then
    case $choice in
        1)
            optimize_system
            [ "$EXISTING_MODE" == "Reality" ] && install_reality || install_ws_tls
            ;;
        2)
            optimize_system
            [ "$EXISTING_MODE" == "Reality" ] && install_ws_tls || install_reality
            ;;
        3) manage_warp "refresh" ;;
        4) manage_warp "reset" ;;
        5)
            log_warn "正在清理卸载..."
            systemctl stop xray nginx warp-svc || true
            apt purge -y cloudflare-warp nginx xray || true
            rm -rf /usr/local/etc/xray /etc/nginx/sites-enabled/* /usr/local/etc/autovpn
            log_info "✅ 卸载完成"
            ;;
        0) exit 0 ;;
        *) log_err "输入无效"; exit 1 ;;
    esac
else
    case $choice in
        1) optimize_system; install_reality ;;
        2) optimize_system; install_ws_tls ;;
        0) exit 0 ;;
        *) log_err "输入无效"; exit 1 ;;
    esac
fi
