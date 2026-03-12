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
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
NC='\033[0m'

# 解析命令行参数 (v1.7.0)
while [[ $# -gt 0 ]]; do
    case $1 in
        --silent) MODE="silent"; shift ;;
        --uuid) UUID="$2"; shift 2 ;;
        --port) XRAY_PORT="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --mode) INSTALL_MODE="$2"; shift 2 ;; # 明确指定安装模式 (reality/ws)
        --update-bot)
            ENV_PATH="/usr/local/etc/autovpn/.env"
            if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
            AUTO_UPDATE_BOT=1; shift ;;
        *) shift ;;
    esac
done

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
            
            # 提取第一个发现的配置路径
            local first_path=$(echo -e "$DISCOVERY_INFO" | grep "路径=" | head -n 1 | awk -F'路径=' '{print $2}' | awk -F',' '{print $1}')
            if [ -f "$first_path" ]; then
                log_info "正在尝试从 $first_path 提取关键配置信息..."
                EXT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$first_path" 2>/dev/null || grep -oP '"id":\s*"[a-f0-9-]{36}"' "$first_path" | head -n1 | grep -oP '[a-f0-9-]{36}')
                EXT_PORT=$(jq -r '.inbounds[0].port' "$first_path" 2>/dev/null || grep -oP '"port":\s*\d+' "$first_path" | head -n1 | grep -oP '\d+')
                EXT_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$first_path" 2>/dev/null || grep -oP '"path":\s*"[^"]+"' "$first_path" | head -n1 | grep -oP '"[^"]+"$' | tr -d '"')
                
                # 持久化提取到的变量
                UUID="${EXT_UUID:-$UUID}"
                XRAY_PORT="${EXT_PORT:-$XRAY_PORT}"
                WS_PATH="${EXT_PATH:-$WS_PATH}"
                save_env
                log_info "✅ 配置提取成功：UUID=$UUID, Port=$XRAY_PORT"
            fi
            
            mkdir -p /usr/local/etc/autovpn
            touch "$ENV_PATH"
            IS_MANAGED_BY_AUTOVPN=true
        else
            log_warn "已取消接管。脚本将退出以防冲突。"
            exit 0
        fi
    fi

    # 4. 解析现有配置 (无论原生还是接管)
    if [ -f "$CONFIG_PATH" ]; then
        # 优先读取 Xray 配置文件中的实时数据
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
    
    [ -z "$EXISTING_PORT" ] && EXISTING_PORT="$XRAY_PORT"
}

# 辅助：防火墙端口开放
open_ports() {
    local port=$1
    log_info "正在尝试开放端口: $port..."
    if command -v ufw &> /dev/null; then
        ufw allow $port/tcp &> /dev/null
        ufw allow $port/udp &> /dev/null
    fi
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport $port -j ACCEPT &> /dev/null
        iptables -I INPUT -p udp --dport $port -j ACCEPT &> /dev/null
    fi
}

# 辅助：显示分享链接
show_link() {
    clear
    load_config
    if [ -z "$EXISTING_MODE" ]; then
        log_err "未检测到有效安装，无法生成链接。"
        read -p "按回车返回..."
        return
    fi
    
    IP=$(curl -s https://ipv4.icanhazip.com)
    echo -e "${GREEN}==================== 当前连接信息 ====================${PLAIN}"
    if [ "$EXISTING_MODE" == "Reality" ]; then
        # 尝试从配置中抓取 Public Key (如果存在)
        PUBLIC_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$CONFIG_PATH" 2>/dev/null || echo "需重装获取")
        SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_PATH" 2>/dev/null || echo "需重装获取")
        LINK="vless://${EXISTING_UUID}@${IP}:${EXISTING_PORT}?encryption=none&security=reality&sni=${EXISTING_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#AutoVPN_Reality"
    else
        LINK="vless://${EXISTING_UUID}@${EXISTING_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${EXISTING_DOMAIN}&sni=${EXISTING_DOMAIN}&path=$(echo $EXISTING_PATH | sed 's/\//%2F/g')#AutoVPN_WS_CDN"
    fi
    
    echo -e "模式: ${BLUE}$EXISTING_MODE${PLAIN}"
    echo -e "UUID: ${BLUE}$EXISTING_UUID${PLAIN}"
    echo -e "\n分享链接:"
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    read -p "按回车返回菜单..."
}

# 辅助：日志查看
show_logs() {
    while true; do
        clear
        echo -e "${BLUE}==================== 日志管理中心 ====================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看 Xray 运行日志 (最后 50 行)"
        echo -e "  ${GREEN}2.${PLAIN} 查看 Nginx 访问日志 (WS-TLS 模式)"
        echo -e "  ${GREEN}3.${PLAIN} 查看 Nginx 错误日志"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择: " log_choice
        case $log_choice in
            1) journalctl -u xray --no-pager -n 50 ;;
            2) [ -f /var/log/nginx/access.log ] && tail -n 50 /var/log/nginx/access.log || echo "日志文件不存在" ;;
            3) [ -f /var/log/nginx/error.log ] && tail -n 50 /var/log/nginx/error.log || echo "日志文件不存在" ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

# 辅助：服务管理
manage_services() {
    while true; do
        clear
        echo -e "${BLUE}==================== 服务控制中心 ====================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 重启所有服务 (Xray/Nginx)"
        echo -e "  ${GREEN}2.${PLAIN} 停止所有服务"
        echo -e "  ${GREEN}3.${PLAIN} 启动所有服务"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择: " svc_choice
        case $svc_choice in
            1) systemctl restart xray; systemctl restart nginx 2>/dev/null; log_info "已重启" ;;
            2) systemctl stop xray; systemctl stop nginx 2>/dev/null; log_info "已停止" ;;
            3) systemctl start xray; systemctl start nginx 2>/dev/null; log_info "已启动" ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

# 辅助：完全卸载
uninstall_all() {
    echo -e "${RED}警告：此操作将彻底删除 Xray, Nginx, acme.sh 以及所有配置和网站数据！${PLAIN}"
    read -p "确定要彻底卸载吗？ [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理系统..."
        systemctl stop xray nginx warp-svc 2>/dev/null || true
        systemctl disable xray nginx warp-svc 2>/dev/null || true
        apt purge -y xray nginx cloudflare-warp 2>/dev/null || true
        rm -rf /usr/local/etc/xray /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /var/www/html/*
        rm -rf /usr/local/etc/autovpn ~/.acme.sh
        rm -f /etc/systemd/system/xray.service /swapfile
        log_info "✅ 卸载完成，系统已恢复纯净。"
        exit 0
    fi
}

# 辅助：发送 TG 消息
send_tg_msg() {
    local message="$1"
    if [ ! -z "$TG_BOT_TOKEN" ] && [ ! -z "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=Markdown" > /dev/null
    fi
}

# 辅助：配置 TG 机器人
config_tg_bot() {
    echo -e "\n${BLUE}==================== Telegram 机器人配置 ====================${PLAIN}"
    echo -e "说明：开启后，脚本将在安装完成、故障预警或远程扩容时实时给你发通知。"
    read -p "是否配置 Telegram 机器人通知？ [y/N]: " setup_tg
    if [[ "$setup_tg" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}1. 获取 Bot Token:${PLAIN}"
        echo -e "   - 在 Telegram 中搜索 ${YELLOW}@BotFather${PLAIN} 并发送 /newbot。"
        echo -e "   - 按照提示创建机器人后，你会得到一串类似 '123456:ABC-DEF' 的字符。"
        read -p "请输入 Bot Token: " INPUT_TOKEN
        TG_BOT_TOKEN="${INPUT_TOKEN:-$TG_BOT_TOKEN}"

        echo -e "\n${CYAN}2. 获取 Chat ID:${PLAIN}"
        echo -e "   - 在 Telegram 中搜索 ${YELLOW}@userinfobot${PLAIN} 并发送 /start。"
        echo -e "   - 该机器人会回复你的数字 ID (如: 987654321)。"
        read -p "请输入 Chat ID: " INPUT_ID
        TG_CHAT_ID="${INPUT_ID:-$TG_CHAT_ID}"
        
        if [ ! -z "$TG_BOT_TOKEN" ] && [ ! -z "$TG_CHAT_ID" ]; then
            save_env
            log_info "正在发送测试消息..."
            send_tg_msg "🚀 *AutoVPN 机器人连接成功！*\n\n这是一条测试消息，说明你的订阅通知已生效。"
            log_info "✅ 配置成功！"
        else
            log_err "Token 或 Chat ID 不能为空，配置取消。"
        fi
    fi
}

save_env() {
    mkdir -p /usr/local/etc/autovpn
    cat > "$ENV_PATH" <<EOF
CF_TOKEN="$CF_TOKEN"
DOMAIN="$DOMAIN"
UUID="$UUID"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
CLUSTER_MODE="$CLUSTER_MODE"
CF_WORKER_URL="$CF_WORKER_URL"
CLUSTER_TOKEN="$CLUSTER_TOKEN"
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
EOF
}

# 辅助：一键部署 Cloudflare Worker
deploy_cf_worker() {
    echo -e "\n${CYAN}--- Cloudflare Worker 自动化部署 ---${NC}"
    echo -e "说明：此操作将自动在你的 CF 账户创建 D1 数据库并部署中继脚本。"
    
    if [[ -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "\n${CYAN}获取 Account ID:${PLAIN}"
        echo -e "   - 登录 Cloudflare 官网 (dash.cloudflare.com)。"
        echo -e "   - 在首页右侧栏最下方可以看到 'Account ID'。"
        read -p "请输入 Cloudflare Account ID: " CF_ACCOUNT_ID
    fi

    echo -e "\n${CYAN}获取 API Token:${PLAIN}"
    echo -e "   - 电脑端访问: https://dash.cloudflare.com/profile/api-tokens"
    echo -e "   - 点击 '创建令牌' -> 使用 '编辑 Cloudflare Workers' 模板。"
    echo -e "   - 在 '账户资源' 选 '所有账户'，'区域资源' 选 '所有区域'。"
    read -p "请输入 Cloudflare API Token: " CF_API_TOKEN
    
    if [[ -z "$CF_ACCOUNT_ID" || -z "$CF_API_TOKEN" ]]; then
        log_err "Account ID 或 Token 不能为空，取消自动化部署。"
        return 1
    fi

    # [v1.7.0] 创建 D1 数据库并初始化 Schema
    log_info "正在配置云端 D1 数据库 (v1.7.0)..."
    local d1_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name": "autovpn_db"}')
    local d1_id=$(echo "$d1_res" | jq -r '.result.uuid')
    if [[ "$d1_id" == "null" ]]; then
        d1_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" | jq -r '.result[] | select(.name=="autovpn_db") | .uuid')
    fi
    echo "$d1_id" > /usr/local/etc/autovpn/.d1_id

    log_info "正在初始化任务编排 SQL 表结构 (v1.7.0)..."
    local sql_init="
        CREATE TABLE IF NOT EXISTS nodes (
            id TEXT PRIMARY KEY, 
            cpu REAL, 
            mem_pct REAL, 
            v TEXT, 
            t INTEGER, 
            state TEXT DEFAULT 'online',
            health TEXT DEFAULT '{}',
            traffic_total TEXT DEFAULT '{}',
            quality TEXT DEFAULT '{}',
            ip TEXT,
            is_selected INTEGER DEFAULT 0, 
            alert_sent INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS traffic_snapshots (node_id TEXT, up INTEGER, down INTEGER, t INTEGER);
        CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, target_id TEXT, cmd TEXT, task_id INTEGER, result TEXT, status TEXT DEFAULT 'pending', completed_at INTEGER);
        CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, val TEXT);
        INSERT OR REPLACE INTO config (key, val) VALUES ('BOT_TOKEN', '$TG_BOT_TOKEN');
        INSERT OR REPLACE INTO config (key, val) VALUES ('CHAT_ID', '$TG_CHAT_ID');
        INSERT OR REPLACE INTO config (key, val) VALUES ('CF_TOKEN', '$CF_API_TOKEN');
    "
    local payload=$(jq -n --arg sql "$sql_init" '{"sql": $sql}')
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null

    # 部署 Worker (带 D1 绑定)
    log_info "正在上传并绑定 Worker 脚本..."
    local worker_js=$(cat /usr/local/etc/autovpn/cf_worker_relay.js | sed "s/your_private_token_here/${CLUSTER_TOKEN}/g")
    
    cat > /tmp/metadata.json <<EOF
{
  "main_module": "index.js",
  "bindings": [
    { "type": "d1", "name": "DB", "id": "$d1_id" }
  ]
}
EOF
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/autovpn-relay" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -F "metadata=@/tmp/metadata.json;type=application/json" \
        -F "index.js=$worker_js;type=application/javascript+module" > /dev/null

    # 配置 Webhook
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setWebhook" \
        -d "url=https://autovpn-relay.$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/subdomain" -H "Authorization: Bearer ${CF_API_TOKEN}" | jq -r '.result.subdomain').workers.dev/webhook" > /dev/null

    log_info "✅ D1 状态机监控中心已激活！"
    echo -e "Cluster Mode: ${CYAN}D1 StatusMachine (v1.8.2)${NC}"
    return 0
}

# 辅助：配置 Guardian Bot (Python 交互式机器人 & 集群增强)
setup_guardian_bot() {
    local mode=$1
    log_info "正在配置 AutoVPN Guardian 集群服务..."
    
    # 基础环境检查
    if ! command -v python3 &> /dev/null; then
        apt-get update &> /dev/null && apt-get install -y python3 python3-requests &> /dev/null
    fi

    # [v1.7.0] 集群信任建立与 SSH 密钥同步
    log_info "正在同步集群互信秘钥 (v1.7.0)..."
    mkdir -p /usr/local/etc/autovpn/
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    
    local d1_id=$(cat /usr/local/etc/autovpn/.d1_id 2>/dev/null)
    if [[ ! -z "$d1_id" ]]; then
        # 尝试从 D1 获取所有密钥 (v1.8.2: 增加 SSH_OWNER_PUB)
        local key_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
            -d "{\"sql\": \"SELECT key, val FROM config WHERE key IN ('SSH_PRV', 'SSH_PUB', 'SSH_OWNER_PUB')\"}")
        
        local prv_key=$(echo "$key_res" | jq -r '.result[0].results[] | select(.key=="SSH_PRV") | .val')
        local pub_key=$(echo "$key_res" | jq -r '.result[0].results[] | select(.key=="SSH_PUB") | .val')
        local owner_pub=$(echo "$key_res" | jq -r '.result[0].results[] | select(.key=="SSH_OWNER_PUB") | .val')
        
        # 1. 如果集群没有机器人秘钥，生成一对
        if [[ "$prv_key" == "null" || -z "$prv_key" ]]; then
            log_info "集群尚未初始化机器人密钥，正在重新生成..."
            ssh-keygen -t rsa -b 2048 -f /tmp/id_cluster -N "" -q
            prv_key=$(cat /tmp/id_cluster)
            pub_key=$(cat /tmp/id_cluster.pub)
            local sql_insert="INSERT OR REPLACE INTO config (key, val) VALUES ('SSH_PRV', '$prv_key'), ('SSH_PUB', '$pub_key')"
            local payload=$(jq -n --arg sql "$sql_insert" '{"sql": $sql}')
            curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
                -d "$payload" > /dev/null
            rm -f /tmp/id_cluster*
        fi

        # 2. [v1.8.2] 自动识别并保存“老板密钥” (Owner DNA)
        if [[ "$owner_pub" == "null" || -z "$owner_pub" ]]; then
            # 扫描 authorized_keys 中不带 guardian 限制标记的公钥
            local detected_owner=$(grep -v "guardian.py" /root/.ssh/authorized_keys 2>/dev/null | grep "ssh-rsa" | head -n 1)
            if [[ ! -z "$detected_owner" ]]; then
                log_info "发现老板公钥 DNA，正在备份至云端..."
                owner_pub="$detected_owner"
                local sql_owner="INSERT OR REPLACE INTO config (key, val) VALUES ('SSH_OWNER_PUB', '$owner_pub')"
                local p_owner=$(jq -n --arg sql "$sql_owner" '{"sql": $sql}')
                curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
                    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
                    -d "$p_owner" > /dev/null
            fi
        fi
        
        # 3. 部署私钥 (用于医生节点外访)
        echo "$prv_key" > /usr/local/etc/autovpn/cluster_key
        chmod 600 /usr/local/etc/autovpn/cluster_key
        
        # 4. 配置 authorized_keys (双锁并进)
        # a. 机器人自愈锁 (Forced Command)
        local rescue_cmd="command=\"/usr/bin/python3 /usr/local/etc/autovpn/guardian.py --rescue-worker\""
        if ! grep -q "$pub_key" /root/.ssh/authorized_keys 2>/dev/null; then
            echo "${rescue_cmd} ${pub_key}" >> /root/.ssh/authorized_keys
            log_info "✅ 已部署：机器人自愈锁 (受限权限)"
        fi
        # b. 老板最高权限锁 (Full Root)
        if [[ ! -z "$owner_pub" && "$owner_pub" != "null" ]]; then
            if ! grep -q "$owner_pub" /root/.ssh/authorized_keys 2>/dev/null; then
                echo "${owner_pub}" >> /root/.ssh/authorized_keys
                log_info "✅ 已同步：老板最高权限锁 (Full Root)"
            fi
        fi

        # 5. 向老板展示公钥以便其手动配置 VPS 后台
        if [[ "$mode" != "silent" ]]; then
            echo -e "\n${BLUE}--- SSH 资产清单 (v1.8.2) ---${NC}"
            echo -e "机器人公钥: ${YELLOW}${pub_key}${NC}"
            echo -e "💡 建议将上方【机器人公钥】上传到 VPS 服务商后台，实现全自动一键扩容。"
        fi
    fi

    if [[ "$mode" != "silent" ]]; then
        # 已开启集群模式下的管理菜单
        if [[ "$CLUSTER_MODE" == "on" ]]; then
            echo -e "\n${CYAN}--- Guardian Cluster (已开启) ---${NC}"
            echo -e "1. 刷新本地守护进程 (重启服务)"
            echo -e "2. 检查并更新云端中继 (Cloudflare Worker)"
            echo -e "3. 重新配置集群信息 (手动/自动)"
            echo -e "0. 返回"
            read -p "请选择: " cluster_mgr_choice
            case $cluster_mgr_choice in
                1) systemctl restart autovpn-guardian; log_info "守护进程已重启"; return ;;
                2) deploy_cf_worker; return ;;
                3) unset CLUSTER_MODE ;; # 进入下方的配置逻辑
                *) return ;;
            esac
        fi

        # 集群模式选择
        if [[ -z "$CLUSTER_MODE" || "$CLUSTER_MODE" == "off" ]]; then
            echo -e "\n${CYAN}--- Guardian Cluster 集群配置 ---${NC}"
            echo -e "1. 独立运行 (单机 Telegram 控制)"
            echo -e "2. 使用 Cloudflare Worker (全自动一键部署)"
            echo -e "3. 使用 Cloudflare Worker (手动填入已有信息)"
            read -p "请选择模式 [1/2/3, 默认 1]: " cluster_choice
            case $cluster_choice in
                2)
                    deploy_cf_worker || { echo "切换到手动模式..."; read -p "请输入 Cloudflare Worker URL: " CF_WORKER_URL; read -p "请输入集群通讯 Token: " CLUSTER_TOKEN; CLUSTER_MODE="on"; }
                    ;;
                3)
                    CLUSTER_MODE="on"
                    read -p "请输入 Cloudflare Worker URL: " CF_WORKER_URL
                    read -p "请输入集群通讯 Token: " CLUSTER_TOKEN
                    save_env
                    ;;
                *)
                    CLUSTER_MODE="off"
                    save_env
                    ;;
            esac
        fi
    fi

    # 创建驱动脚本 (v1.8.2 - Data Compass + Sentinel)
    cat > /usr/local/etc/autovpn/guardian.py <<'EOF'
import requests, time, subprocess, os, json, sys, socket, statistics

VERSION = "v1.8.2"
ENV_PATH = "/usr/local/etc/autovpn/.env"
NODE_ID = socket.gethostname()

# [Sentinel] 救援回执模式 - 由 SSH 远程触发
if "--rescue-worker" in sys.argv:
    os.system("pkill -9 -f guardian.py")
    os.system("systemctl restart xray")
    os.system("systemctl restart autovpn-guardian")
    sys.exit(0)

def run_shell(cmd):
    try: return subprocess.getoutput(cmd)
    except: return ""

def get_traffic():
    try:
        res = subprocess.getoutput("/usr/local/bin/xray api statsquery --server=127.0.0.1:10085")
        up, down = 0, 0
        for line in res.split("\n"):
            if "uplink" in line and "value" in line: up += int(line.split(":")[-1].strip())
            if "downlink" in line and "value" in line: down += int(line.split(":")[-1].strip())
        return {"up": up, "down": down}
    except: return {"up": 0, "down": 0}

def measure_quality(target):
    try:
        cmd = f"ping -c 5 -W 2 {target}"
        res = subprocess.getoutput(cmd)
        if "packet loss" in res:
            loss = float(res.split("packet loss")[0].split(",")[-1].replace("%", "").strip())
            times = [float(x.split("=")[-1].replace(" ms", "")) for x in res.split("\n") if "time=" in x]
            if times:
                avg = sum(times) / len(times)
                jitter = statistics.stdev(times) if len(times) > 1 else 0
                return {"lat": round(avg, 2), "jit": round(jitter, 2), "loss": loss}
        return {"lat": 0, "jit": 0, "loss": 100}
    except: return {"lat": 0, "jit": 0, "loss": 100}

def check_health():
    health = {"xray": "OK", "nginx": "OK", "net": "OK", "warp": "SKIP"}
    if os.system("systemctl is-active --quiet xray") != 0: health["xray"] = "FAIL"
    if os.system("systemctl is-active --quiet nginx") != 0: health["nginx"] = "FAIL"
    if os.path.exists("/usr/local/bin/warp"):
        warp_res = subprocess.getoutput("warp status")
        health["warp"] = "OK" if "Connected" in warp_res else "FAIL"
    return health

def get_status_data(tid=None, res=None):
    cpu = run_shell("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'")
    mem = run_shell("free | grep Mem | awk '{print $3/$2 * 100.0}'")
    data = {
        "id": NODE_ID, "cpu": cpu or "0", "mem_pct": mem or "0", "v": VERSION, 
        "h": check_health(), "ip": run_shell("curl -s https://api.ipify.org"),
        "traff": get_traffic(),
        "qual": {
            "china": measure_quality("223.5.5.5"),
            "global": measure_quality("1.1.1.1")
        }
    }
    if tid: data["task_id"] = tid; data["result"] = res
    return data

def main():
    while True:
        try:
            if not os.path.exists(ENV_PATH): time.sleep(10); continue
            with open(ENV_PATH, "r") as f:
                env = {l.split("=")[0]: l.split("=")[1].strip().replace('"','') for l in f if "=" in l}
            cf_url, c_token = env.get("CF_WORKER_URL", "").rstrip("/"), env.get("CLUSTER_TOKEN")
            if not cf_url: time.sleep(10); continue

            r = requests.post(f"{cf_url}/report", json=get_status_data(), headers={"X-Cluster-Token": c_token}, timeout=10)
            if r.status_code == 200:
                task = r.json()
                if task.get("cmd"):
                    if task["cmd"].startswith("rescue_"):
                        target_ip = task["cmd"].split("_")[1]
                        key_path = "/usr/local/etc/autovpn/cluster_key"
                        ssh_cmd = f"ssh -i {key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{target_ip} exit"
                        res = "✅ 成功" if os.system(ssh_cmd) == 0 else f"❌ 失败: {target_ip}"
                    else:
                        res = run_shell(f"bash /usr/local/bin/autovpn {task['cmd']}")
                    requests.post(f"{cf_url}/report", json=get_status_data(tid=task['task_id'], res=res), 
                                 headers={"X-Cluster-Token": c_token}, timeout=10)
        except: pass
        time.sleep(10)

if __name__ == "__main__": main()
EOF
    chmod +x /usr/local/etc/autovpn/guardian.py

    # 创建 Systemd Service
    cat > /etc/systemd/system/autovpn-guardian.service <<EOF
[Unit]
Description=AutoVPN Guardian Cluster Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/etc/autovpn/guardian.py
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable autovpn-guardian && systemctl restart autovpn-guardian
    log_info "✅ Guardian 集群服务已刷新"
    
    # 清理旧的 monitor 任务
    systemctl stop autovpn-monitor.timer 2>/dev/null || true
    systemctl disable autovpn-monitor.timer 2>/dev/null || true
    rm -f /etc/systemd/system/autovpn-monitor.*
}

# =================================================================
# 1. 环境初始化与优化
# =================================================================
optimize_system() {
    log_info ">>> 进入系统环境优化..."
    
    # 安装基础依赖
    apt update -y > /dev/null
    apt install -y curl unzip socat nginx git uuid-runtime gnupg lsb-release jq openssl python3-requests > /dev/null

    # 1.1 BBR 加速检查
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_info "检查：系统已启用 BBR 加速，跳过。"
    else
    if [[ "$MODE" == "silent" ]]; then
        # 静默模式默认开启 BBR
        log_info "静默模式：自动开启 BBR..."
        bbr_choice="y"
    else
        echo -e "\n${YELLOW}【重要】风险提示：开启 BBR 加速${PLAIN}"
        echo -e "说明：BBR 是 Google 开发的拥塞控制算法，能显著提升丢包环境下的吞吐量。"
        echo -e "风险：在极少数 OpenVZ 架构或内核过旧的服务器上，强制修改参数可能导致网络连接异常。"
        read -p "是否尝试开启 BBR 加速？ [Y/n]: " bbr_choice
    fi
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

    # 1.3 TG 机器人配置
    config_tg_bot
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
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "port": $XRAY_PORT, "protocol": "vless",
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
  "routing": { "rules": [{ "type": "field", "inboundTag": ["api"], "outboundTag": "api" }] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "api" }
  ]
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
    open_ports $XRAY_PORT
    save_env
    
    # 结果输出
    IP=$(curl -s https://ipv4.icanhazip.com)
    LINK="vless://${UUID}@${IP}:${XRAY_PORT}?encryption=none&security=reality&sni=${FAKE_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#AutoVPN_Reality"
    
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "=========================================================="
    
    # TG 通知与监控
    send_tg_msg "✅ *AutoVPN Reality 部署成功!*\n\n📍 *IP:* ${IP}\n🔑 *UUID:* ${UUID}\n🔗 *链接:* \`${LINK}\`"
    setup_guardian_bot
}

# =================================================================
# 3. VLESS-WS-TLS + CDN 部署模块
# =================================================================
install_ws_tls() {
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
    
    if [[ "$MODE" == "silent" ]]; then
        decoy_choice="Y"
    else
        # 4. 可选伪装页面
        echo -e "\n${BLUE}[配置 4/4] 网站伪装页面${PLAIN}"
        echo -e "说明：AutoVPN 默认提供一个 2048 小游戏的伪装页面，访问你的域名会显示正常游戏。"
        read -p "是否部署此伪装页面？ [Y/n]: " decoy_choice
        decoy_choice="${decoy_choice:-Y}"
    fi

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
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "port": $XRAY_LISTEN_PORT, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    },
    { "port": 10085, "listen": "127.0.0.1", "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }
    ]
  },
  "outbounds": [
    { "tag": "warp", "protocol": "socks", "settings": { "servers": [{"address": "127.0.0.1", "port": 40000}] } },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "api", "protocol": "blackhole" }
  ]
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
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "=========================================================="

    # TG 通知与监控
    send_tg_msg "✅ *AutoVPN WS-TLS 部署成功!*\n\n📍 *域名:* ${DOMAIN}\n🔑 *UUID:* ${UUID}\n🔗 *链接:* \`${LINK}\`"
    setup_guardian_bot
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

    echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前模式 (可修改配置)"
    echo -e "  ${GREEN}2.${PLAIN} 切换到另一种模式"
    echo -e "  ${GREEN}3.${PLAIN} 查看/获取当前分享链接"
    echo -e "  ${GREEN}4.${PLAIN} 服务管理 (启动/停止/重启)"
    echo -e "  ${GREEN}5.${PLAIN} 日志管理 (查看运行日志)"
    echo -e "  ${GREEN}6.${PLAIN} WARP 隧道管理 (刷新 IP/重置)"
    echo -e "  ${GREEN}7.${PLAIN} 防火墙管理 (自动开放端口)"
    echo -e "  ${GREEN}8.${PLAIN} Guardian 集群 & 机器人"
    echo -e "  ${GREEN}9.${PLAIN} 彻底卸载 AutoVPN"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    read -p "请选择: " choice

    case $choice in
        1) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_reality || install_ws_tls ;;
        2) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_ws_tls || install_reality ;;
        3) show_link ;;
        4) manage_services ;;
        5) show_logs ;;
        6) 
            echo -e "1. 刷新 WARP IP\n2. 重置 WARP 注册"
            read -p "选项: " wc
            [ "$wc" == "1" ] && manage_warp "refresh" || manage_warp "reset"
            ;;
        7) open_ports 80; open_ports 443; [ ! -z "$EXISTING_PORT" ] && open_ports $EXISTING_PORT; log_info "防火墙策略已更新。" ;;
        8) setup_guardian_bot ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) log_err "无效输入"; show_menu ;;
    esac
else
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS-Reality (推荐：简单/免域名/高性能)"
    echo -e "  ${GREEN}2.${PLAIN} 安装 VLESS-WS-TLS (CDN/强伪装/需已有域名)"
    echo -e "  ${GREEN}3.${PLAIN} 仅进行系统环境优化 (BBR/Swap)"
    echo -e "  ${GREEN}4.${PLAIN} 集群模式：加入已有集群 (Cloudflare-Native)"
    echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -p "请选择: " choice
    case $choice in
        1) optimize_system; install_reality ;;
        2) optimize_system; install_ws_tls ;;
        3) optimize_system; log_info "系统优化完成。"; read -p "回车返回..." ;;
        4) setup_guardian_bot ;;
        0) exit 0 ;;
        *) log_err "无效输入"; show_menu ;;
    esac
fi
}

# =================================================================
# 启动入口
# =================================================================
main() {
    # 如果是 BOT 自动更新，则跳过菜单，直接执行配置并退出
    if [[ "$AUTO_UPDATE_BOT" == "1" ]]; then
        log_info ">>> 检测到机器人热更新指令，正在重新部署守护进程..."
        # 确保目录存在
        mkdir -p /usr/local/etc/autovpn
        # 执行机器人配置逻辑 (由脚本中的 setup_guardian_bot 提供)
        setup_guardian_bot silent
        log_info "✅ 机器人已完成热更新。"
        exit 0
    fi
    # 如果是静默模式，根据 INSTALL_MODE 自动执行
    if [[ "$MODE" == "silent" ]]; then
        log_info ">>> 检测到静默安装模式: $INSTALL_MODE"
        if [[ "$INSTALL_MODE" == "reality" ]]; then
            optimize_system; install_reality
            exit 0
        elif [[ "$INSTALL_MODE" == "ws" ]]; then
            optimize_system; install_ws_tls
            exit 0
        fi
    fi
    show_menu
}

main
