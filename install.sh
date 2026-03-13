# AutoVPN - 一键 VPS 代理配置脚本 (v1.18.0 - Smart Polling)
# =================================================================

VERSION="v1.18.21"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
NC='\033[0m'

# 解析命令行参数 (v1.18.0)
while [[ $# -gt 0 ]]; do
    case $1 in
        --silent) MODE="silent"; shift ;;
        --uuid) UUID="$2"; shift 2 ;;
        --port) XRAY_PORT="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --mode) INSTALL_MODE="$2"; shift 2 ;; 
        --rotate-keys) ROTATE_KEYS=1; shift ;;
        --update-bot)
            ENV_PATH="/usr/local/etc/autovpn/.env"
            if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
            AUTO_UPDATE_BOT=1; shift ;;
        start|stop|restart|log|speed) CMD_ACTION="$1"; shift ;;
        --cf-worker-url) CF_WORKER_URL="$2"; shift 2 ;;
        --cluster-token) CLUSTER_TOKEN="$2"; shift 2 ;;
        --pair) PAIR_CODE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# 检测是否通过管道执行，如果是则下载后本地执行
if [ ! -t 0 ]; then
    # 管道执行模式，下载脚本到本地并执行
    curl -sL -o /tmp/autovpn_install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh
    chmod +x /tmp/autovpn_install.sh
    exec /tmp/autovpn_install.sh "$@"
fi

# 如果有动作指令，直接执行并退出
if [ ! -z "$CMD_ACTION" ]; then
    case $CMD_ACTION in
        start) systemctl start xray ;;
        stop) systemctl stop xray ;;
        restart) systemctl restart xray ;;
        log) journalctl -u xray --no-pager -n 50 ;;
        speed) 
            if ! command -v speedtest-cli &> /dev/null; then
                apt-get update && apt-get install -y speedtest-cli
            fi
            speedtest-cli --simple
            ;;
    esac
    exit 0
fi

# 辅助：Cloudflare API 调用器 (v1.18.0 - Vision Patch)
cf_api() {
    local method="$1"
    local path="$2"
    shift 2
    local body="$@"
    local url="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}${path}"
    
    local res
    if [[ -z "$body" ]]; then
        res=$(curl -s -X "$method" "$url" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" 2>&1)
    else
        res=$(curl -s -X "$method" "$url" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" -d "$body" 2>&1)
    fi

    local curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        echo -e "${RED}[ERROR] 网络请求物理失败 (Exit: $curl_exit)${NC}" >&2
        echo -e "${YELLOW}详情: $res${NC}" >&2
        return 1
    fi

    # 简单校验 JSON 有效性
    if ! echo "$res" | jq -e . >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 接收到非 JSON 响应!${NC}" >&2
        echo -e "${YELLOW}原始回显: ${NC}\n$res" >&2
        return 1
    fi

    local success=$(echo "$res" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
        # 如果是因为资源已存在 (如 D1 重名 7502)，则不报错到 stderr，但返回 1 让 caller fallback
        if echo "$res" | jq -e '.errors[0].code == 7502' >/dev/null 2>&1; then
            echo "$res"
            return 1
        fi
        echo -e "${RED}[ERROR] Cloudflare 业务报错!${NC}" >&2
        echo "$res" | jq . >&2
        return 1
    fi
    
    echo "$res"
}

log_info() {
 echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() {
 echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_err()  {
 echo -e "${RED}[ERROR] $1${PLAIN}"; }

# 信号捕获 (Ctrl+C 退出提示)
cleanup() {
    echo -e "\n${YELLOW}检测到脚本被中断。配置未完成，你可以随时再次运行脚本继续安装。"
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
            EXISTING_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_PATH" 2>/dev/null || grep -oP '"id":\s*"[a-f0-9-]{36}"' "$CONFIG_PATH" | head -n1 | grep -oP '[a-f0-9-]{36}' || echo "")
            EXISTING_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_PATH" 2>/dev/null || grep -oP '"port":\s*\d+' "$CONFIG_PATH" | head -n1 | grep -oP '\d+' || echo "")
            EXISTING_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_PATH" 2>/dev/null || grep -oP '"serverNames":\s*\[\s*"[^"]+"' "$CONFIG_PATH" | head -n1 | grep -oP '"[^"]+"$' | tr -d '"' || echo "")
        elif grep -q "\"ws\"" "$CONFIG_PATH"; then
            EXISTING_MODE="WS-TLS"
            EXISTING_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_PATH" 2>/dev/null || grep -oP '"id":\s*"[a-f0-9-]{36}"' "$CONFIG_PATH" | head -n1 | grep -oP '[a-f0-9-]{36}' || echo "")
            EXISTING_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$CONFIG_PATH" 2>/dev/null || grep -oP '"path":\s*"[^"]+"' "$CONFIG_PATH" | head -n1 | grep -oP '"[^"]+"$' | tr -d '"')
            EXISTING_DOMAIN=$(ls /etc/nginx/sites-available/ 2>/dev/null | grep ".conf" | head -n 1 | sed 's/.conf//' || echo "")
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

    # 检查 Xray 服务状态
    if ! systemctl is-active --quiet xray; then
        log_err "Xray 服务未运行，无法生成有效链接。请检查服务状态。"
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
# 辅助：脚本在线自我更新 (v1.18.0)
update_script() {
    log_info "正在从 GitHub 获取最新脚本..."
    log_warn "强制更新脚本中..."
    if wget -q --user-agent="Mozilla/5.0" -O install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install.sh; then
        log_info "✅ 脚本已更新！正在重启..."
        sleep 1
        exec ./install.sh
    else
        log_err "更新失败，请检查网络连接"
        sleep 2
    fi
}


send_tg_msg() {
    local message="$1"
    if [ ! -z "$TG_BOT_TOKEN" ] && [ ! -z "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=Markdown" > /dev/null
    fi
}

# 辅助：同步老板公钥 DNA (v1.18.0)
sync_owner_dna() {
    local d1_id=$(cat /usr/local/etc/autovpn/.d1_id 2>/dev/null)
    [ -z "$d1_id" ] && return 0
    [ -z "$CF_ACCOUNT_ID" ] || [ -z "$CF_API_TOKEN" ] && return 0

    log_info "正在校验老板 DNA 同步状态..."
    local key_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        -d "{\"sql\": \"SELECT val FROM config WHERE key = 'SSH_OWNER_PUB'\"}")
    local owner_pub=$(echo "$key_res" | jq -r '.result[0].results[0].val')

    local detected_owner=$(grep -v "guardian.py" /root/.ssh/authorized_keys 2>/dev/null | grep "ssh-rsa" | head -n 1)
    if [[ ! -z "$detected_owner" ]]; then
        if [[ "$owner_pub" == "null" || -z "$owner_pub" || "$detected_owner" != "$owner_pub" ]]; then
            log_info "发现新老板公钥 DNA，正在同步云端..."
            local sql_owner="INSERT OR REPLACE INTO config (key, val) VALUES ('SSH_OWNER_PUB', '$detected_owner')"
            local p_owner=$(jq -n --arg sql "$sql_owner" '{"sql": $sql}')
            curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
                -d "$p_owner" > /dev/null
        fi
    fi
}

# 辅助：配置 TG 机器人
config_tg_bot() {
    echo -e "\n${BLUE}==================== Telegram 机器人配置 ====================${PLAIN}"
    echo -e "说明：开启后，脚本将在安装完成、故障预警或远程扩容时实时给你发通知。"
    
    local default_setup="y"
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && default_setup="n"
    
    read -p "是否配置/更新 Telegram 机器人通知？ [y/N] (默认 $default_setup): " setup_tg
    setup_tg="${setup_tg:-$default_setup}"
    
    if [[ "$setup_tg" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}1. 获取 Bot Token:${PLAIN}"
        echo -e "   - 在 Telegram 中搜索 ${YELLOW}@BotFather${PLAIN} 并发送 /newbot。"
        [ ! -z "$TG_BOT_TOKEN" ] && echo -e "   - 当前记录: ${CYAN}${TG_BOT_TOKEN:0:6}******${PLAIN}"
        read -p "请输入 Bot Token (直接回车保持不变): " INPUT_TOKEN
        TG_BOT_TOKEN="${INPUT_TOKEN:-$TG_BOT_TOKEN}"

        echo -e "\n${CYAN}2. 获取 Chat ID:${PLAIN}"
        echo -e "   - 在 Telegram 中搜索 ${YELLOW}@userinfobot${PLAIN} 并发送 /start。"
        [ ! -z "$TG_CHAT_ID" ] && echo -e "   - 当前记录: ${CYAN}$TG_CHAT_ID${PLAIN}"
        read -p "请输入 Chat ID (直接回车保持不变): " INPUT_ID
        TG_CHAT_ID="${INPUT_ID:-$TG_CHAT_ID}"
        
        if [ ! -z "$TG_BOT_TOKEN" ] && [ ! -z "$TG_CHAT_ID" ]; then
            save_env
            log_info "正在发送测试消息..."
            send_tg_msg "🚀 *AutoVPN 机器人连接成功！*\n\n这是一条测试消息，说明你的配置已持久化保存。"
            log_info "✅ 配置成功！"
        else
            log_err "Token 或 Chat ID 不能为空，配置取消。"
        fi
    fi
}

save_env() {
    mkdir -p /usr/local/etc/autovpn
    cat > "$ENV_PATH" <<EOF
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
CF_API_TOKEN="$CF_API_TOKEN"
CF_TOKEN="$CF_TOKEN"
DOMAIN="$DOMAIN"
UUID="$UUID"
XRAY_PORT="$XRAY_PORT"
WS_PATH="$WS_PATH"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
CLUSTER_MODE="$CLUSTER_MODE"
CLUSTER_TOKEN="$CLUSTER_TOKEN"
CF_WORKER_URL="$CF_WORKER_URL"
EOF
    # 同步老板钥匙 (v1.18.0)
    sync_owner_dna
}

# 辅助：一键部署 Cloudflare Worker
deploy_cf_worker() {
    echo -e "\n${CYAN}--- Cloudflare Worker 自动化部署 ---${NC}"
    echo -e "说明：此操作将自动在你的 CF 账户创建 D1 数据库并部署中继脚本。"
    
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo -e "\n${YELLOW}【重要】检测到尚未配置 Telegram 机器人。${PLAIN}"
        echo -e "说明：集群模式必须依赖机器人进行消息中继和指令下发。"
        config_tg_bot
        if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
            log_err "未配置机器人，无法启动集群模式。"
            return 1
        fi
    fi

    if [[ -z "$CF_ACCOUNT_ID" ]]; then
        echo -e "\n${CYAN}获取 Account ID:${PLAIN}"
        echo -e "   - 登录 Cloudflare 官网 (dash.cloudflare.com)。"
        echo -e "   - 在首页右侧栏最下方可以看到 'Account ID'。"
        [ ! -z "$CF_ACCOUNT_ID" ] && echo -e "   - 当前记录: ${CYAN}$CF_ACCOUNT_ID${PLAIN}"
        read -p "请输入 Cloudflare Account ID: " INPUT_ACCOUNT_ID
        CF_ACCOUNT_ID="${INPUT_ACCOUNT_ID:-$CF_ACCOUNT_ID}"
    fi

    if [[ -z "$CF_API_TOKEN" ]]; then
        echo -e "\n${CYAN}获取 API Token:${PLAIN}"
        echo -e "   - 电脑端访问: https://dash.cloudflare.com/profile/api-tokens"
        echo -e "   - 点击 '创建令牌' -> 使用 '编辑 Cloudflare Workers' 模板。"
        [ ! -z "$CF_API_TOKEN" ] && echo -e "   - 当前记录: ${CYAN}${CF_API_TOKEN:0:6}******${PLAIN}"
        read -p "请输入 Cloudflare API Token: " INPUT_API_TOKEN
        CF_API_TOKEN="${INPUT_API_TOKEN:-$CF_API_TOKEN}"
    fi
    
    if [[ -z "$CF_ACCOUNT_ID" || -z "$CF_API_TOKEN" ]]; then
        log_err "Account ID 或 Token 不能为空，取消自动化部署。"
        return 1
    fi
    
    save_env

    # [v1.7.0] 创建 D1 数据库并初始化 Schema
    log_info "确保依赖环境 (jq)..."
    if ! command -v jq &> /dev/null; then
        apt-get update &> /dev/null && apt-get install -y jq &> /dev/null
    fi

    log_info "正在配置云端 D1 数据库 (v1.18.0)..."
    local d1_res d1_id
    d1_res=$(cf_api POST "/d1/database" '{"name": "autovpn_db"}')
    if [[ $? -ne 0 ]]; then
        log_warn "正尝试获取已有 D1 实例..."
        d1_res=$(cf_api GET "/d1/database") || return 1
        d1_id=$(echo "$d1_res" | jq -r '.result[] | select(.name=="autovpn_db") | .uuid')
    else
        d1_id=$(echo "$d1_res" | jq -r '.result.uuid')
    fi
    
    if [[ -z "$d1_id" || "$d1_id" == "null" ]]; then
        log_err "关键失败：无法确定 D1 数据库 ID。"
        return 1
    fi
    echo "$d1_id" > /usr/local/etc/autovpn/.d1_id

    # 初始化 D1 Schema (v1.18.0 - Hourly Analytics)
    log_info "正在初始化任务编斥 SQL 表结构..."
    local sql_init="CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, cpu REAL, mem_pct REAL, v TEXT, t INTEGER, state TEXT DEFAULT 'online', health TEXT DEFAULT '{}', traffic_total TEXT DEFAULT '{}', quality TEXT DEFAULT '{}', ip TEXT, is_selected INTEGER DEFAULT 0, alert_sent INTEGER DEFAULT 0); 
    CREATE TABLE IF NOT EXISTS traffic_snapshots (node_id TEXT, up INTEGER, down INTEGER, t INTEGER, type TEXT DEFAULT 'realtime'); 
    CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, target_id TEXT, cmd TEXT, task_id INTEGER, result TEXT, status TEXT DEFAULT 'pending', completed_at INTEGER); 
    CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, val TEXT); 
    INSERT OR REPLACE INTO config (key, val) VALUES ('BOT_TOKEN', '$TG_BOT_TOKEN'); 
    INSERT OR REPLACE INTO config (key, val) VALUES ('CHAT_ID', '$TG_CHAT_ID'); 
    INSERT OR REPLACE INTO config (key, val) VALUES ('CF_TOKEN', '$CF_API_TOKEN');
    INSERT OR REPLACE INTO config (key, val) VALUES ('CF_ACCOUNT', '$CF_ACCOUNT_ID');
    INSERT OR REPLACE INTO config (key, val) VALUES ('D1_ID', '$d1_id');
    INSERT OR REPLACE INTO config (key, val) VALUES ('CLUSTER_TOKEN', '${CLUSTER_TOKEN:-$LOCAL_TOKEN}');"
    local payload=$(jq -n --arg sql "$sql_init" '{"sql": $sql}')
    cf_api POST "/d1/database/${d1_id}/query" "$payload" > /dev/null || return 1

    # 部署 Worker (带 D1 绑定 - 严格模式)
    log_info "正在上传并绑定 Worker 脚本..."
    
    log_info "正在从 GitHub 下载最新 Worker 代码..."
    local worker_js_tmp="/tmp/index.js"
    if ! curl -sL "https://raw.githubusercontent.com/ecolid/autovpn/main/cf_worker_relay.js" -o "$worker_js_tmp"; then
        log_err "下载 Worker 代码失败"
        return 1
    fi
    
    sed -i "s/your_private_token_here/${CLUSTER_TOKEN}/g" "$worker_js_tmp"
    
    # 检查代码是否包含 generate_pair 功能
    if grep -q "generate_pair" "$worker_js_tmp"; then
        log_info "✅ 检测到最新版本代码（含配对码功能）"
    else
        log_warn "⚠️ 下载的代码可能不是最新版本"
    fi
    
    # 准备 Worker 上传
    
    cat > /tmp/metadata.json <<EOF
{
  "main_module": "index.js",
  "bindings": [ { "type": "d1", "name": "DB", "id": "$d1_id" } ]
}
EOF
    local upload_res=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/autovpn-relay" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -F "metadata=@/tmp/metadata.json;type=application/json" \
        -F "index.js=@${worker_js_tmp};type=application/javascript+module" 2>&1)
    
    local is_success=$(echo "$upload_res" | jq -r '.success' 2>/dev/null)
    if [[ "$is_success" != "true" ]]; then
        log_err "Worker 脚本上传失败!"
        echo -e "${YELLOW}接口详情: ${NC}\n$upload_res"
        return 1
    fi

    # 激活 workers.dev 路由
    # 4. 刷新机器人菜单
    log_info "正在刷新机器人交互菜单..."
    local menu_payload='{"commands": [
        {"command": "menu", "description": "🏰 打开主控制台"},
        {"command": "status", "description": "📊 节点看板"},
        {"command": "stats", "description": "📈 数据罗盘"},
        {"command": "help", "description": "💡 向导说明"}
    ]}'
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setMyCommands" \
        -H "Content-Type: application/json" \
        -d "$menu_payload" > /dev/null

    log_info "正在开启发布 Worker 到 workers.dev 子域名..."
    cf_api POST "/workers/scripts/autovpn-relay/subdomain" '{"enabled": true}' > /dev/null || return 1

    # 获取并校验 subdomain
    log_info "正在配置 Webhook 路由监控..."
    local subdomain=""
    while [[ -z "$subdomain" || "$subdomain" == "null" ]]; do
        local subdomain_res=$(cf_api GET "/workers/subdomain") || return 1
        subdomain=$(echo "$subdomain_res" | jq -r '.result.subdomain')
        if [[ "$subdomain" == "null" || -z "$subdomain" ]]; then
            log_err "检测到你的 CF 账户尚未配置 workers.dev 子域名。"
            echo -e "请按照上方 [v1.18.0] 引导完成配置后按回车重试。"
            read -p "等待中 (按回车重试)..."
        fi
    done

    CF_WORKER_URL="https://autovpn-relay.${subdomain}.workers.dev"
    
    # 保存 Worker URL 到 D1 数据库
    curl -s -X PUT "${CF_WORKER_URL}/config/CF_WORKER_URL" \
        -H "X-Cluster-Token: ${CLUSTER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"value\": \"${CF_WORKER_URL}\"}" > /dev/null
    
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setWebhook" -d "url=${CF_WORKER_URL}/webhook" > /dev/null
    
    # 发送就绪确认
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}&text=🏰 <b>AutoVPN 指挥部已就位 (v${VERSION})</b>%0A✅ Webhook: 已激活%0A✅ 云端 D1: 已绑定%0A%0A等待节点加入...&parse_mode=HTML" > /dev/null

    # 切换本地状态
    CLUSTER_MODE="on"
    [ -z "$CLUSTER_TOKEN" ] && CLUSTER_TOKEN=$(openssl rand -hex 16)
    save_env
    systemctl restart autovpn-guardian &>/dev/null || true

    # 执行严谨自检
    if verify_cluster_health; then
        echo -e "\n${GREEN}✅ 集群环境已全部就绪！${NC}"
        local bot_username=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" | jq -r '.result.username')
        if [[ "$bot_username" == "null" || -z "$bot_username" ]]; then bot_username="Jpfqbot"; fi
        echo -e "机器人链接: ${CYAN}https://t.me/${bot_username}${NC}"
        echo -e "💡 提示：如果刚才在 Telegram 发送 /start 无反应，请尝试删除并重新开始对话。"
    else
        echo -e "\n${RED}⚠️ 集群部署虽然已完成，但部分自检未通过。${NC}"
        echo -e "建议根据上方 [ERROR] 提示进行排查。"
    fi
    return 0
}

# 辅助：集群健康在线自检 (v1.18.0 - Integrity Check)
verify_cluster_health() {
    sleep 3
    echo -e "\n${BLUE}--- 集群连通性深度自检 (v1.18.0) ---${NC}"
    local is_healthy=true
    
    # 1. 检查 Worker 响应
    log_info "正在探测 Worker 网关状态..."
    local worker_ping=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Cluster-Token: ${CLUSTER_TOKEN}" "${CF_WORKER_URL}")
    if [[ "$worker_ping" == "200" ]]; then
        echo -e "   - Worker 网关: ${GREEN}正常 (200 OK)${NC}"
    else
        echo -e "   - Worker 网关: ${RED}异常 ($worker_ping)${NC}"
        is_healthy=false
    fi

    # 2. 检查 Telegram Webhook
    log_info "正在验证 Telegram Webhook 状态..."
    local webhook_info=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getWebhookInfo")
    local webhook_url=$(echo "$webhook_info" | jq -r '.result.url')
    
    if [[ "$webhook_url" == "${CF_WORKER_URL}/webhook" ]]; then
        echo -e "   - Webhook 路由: ${GREEN}正常 (已指向 Worker)${NC}"
    else
        echo -e "   - Webhook 路由: ${RED}异常 (指向: $webhook_url)${NC}"
        log_warn "正在尝试强制修复 Webhook..."
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setWebhook" -d "url=${CF_WORKER_URL}/webhook" > /dev/null
        is_healthy=false
    fi

    # 3. 检查 D1 数据一致性
    log_info "正在同步 D1 数据库 heartbeats..."
    local report_test=$(curl -s -X POST "${CF_WORKER_URL}/report" \
        -H "X-Cluster-Token: ${CLUSTER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"INSTALL_VERIFY\", \"cpu\": \"0\", \"mem_pct\": \"0\", \"v\": \"v1.18.0\", \"h\": {\"verify\": \"OK\"}}")
    
    if echo "$report_test" | grep -q "true"; then
        echo -e "   - D1 状态机: ${GREEN}正常 (读写存取 OK)${NC}"
        # 清理测试冗余
        cf_api POST "/d1/database/${d1_id}/query" "{\"sql\": \"DELETE FROM nodes WHERE id = 'INSTALL_VERIFY'\"}" > /dev/null
    else
        echo -e "   - D1 状态机: ${RED}异常 (汇报失败)${NC}"
        is_healthy=false
    fi

    [[ "$is_healthy" == "true" ]] && return 0 || return 1
}

# 辅助：集群密钥轮换 (v1.18.0 - Zero-Downtime Rotation)
rotate_cluster_keys() {
    local d1_id=$(cat /usr/local/etc/autovpn/.d1_id 2>/dev/null)
    if [[ -z "$d1_id" ]]; then log_err "未检测到集群信息，无法轮换"; return 1; fi

    log_info "--- 正在进行密钥轮换 (v1.18.0) ---"
    
    # 步骤 1: 生成新密钥
    log_info "1. 正在生成全新机器人密钥对..."
    ssh-keygen -t rsa -b 2048 -f /tmp/id_new -N "" -q
    local new_prv=$(cat /tmp/id_new)
    local new_pub=$(cat /tmp/id_new.pub)
    
    # 获取当前在线节点列表
    local nodes_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        -d "{\"sql\": \"SELECT id, ip FROM nodes WHERE state = 'online'\"}")
    local nodes=$(echo "$nodes_res" | jq -r '.result[0].results[].ip')
    
    # 步骤 2: 部署新锁 (Dual-Key)
    log_info "2. 正在向全集群分发新公钥 (双锁过渡)..."
    for ip in $nodes; do
        log_info "   -> 正在准备节点: $ip"
        ssh -i /usr/local/etc/autovpn/cluster_key -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$ip \
            "echo '$new_pub' >> /root/.ssh/authorized_keys" && log_info "      ✅ 已挂上新锁" || log_warn "      ❌ 挂锁失败: $ip"
    done

    # 步骤 3: 验证新钥匙
    log_info "3. 正在验证新钥匙连通性..."
    local test_ip=$(echo "$nodes" | head -n 1)
    if [[ ! -z "$test_ip" ]]; then
        if ssh -i /tmp/id_new -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$test_ip "exit" 2>/dev/null; then
            log_info "   ✅ 验证通过：新钥匙工作正常！"
        else
            log_err "   ❌ 验证失败：新钥匙无法登入，正在回滚..."
            rm -f /tmp/id_new*
            return 1
        fi
    fi

    # 步骤 4: 提交并清理旧锁
    log_info "4. 正在同步云端并清理旧公钥..."
    local old_pub=$(cat /usr/local/etc/autovpn/cluster_key.pub 2>/dev/null)
    
    # 更新 D1
    local sql_upd="INSERT OR REPLACE INTO config (key, val) VALUES ('SSH_PRV', '$new_prv'), ('SSH_PUB', '$new_pub')"
    local payload=$(jq -n --arg sql "$sql_upd" '{"sql": $sql}')
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_id}/query" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
        -d "$payload" > /dev/null

    # 全集群撤旧锁
    for ip in $nodes; do
        if [[ ! -z "$old_pub" ]]; then
            ssh -i /tmp/id_new -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$ip \
                "sed -i \"\|$old_pub|d\" /root/.ssh/authorized_keys" && log_info "   -> 节点 $ip: 旧锁已卸载" || log_warn "   -> 节点 $ip: 卸木失败"
        fi
    done

    # 更新本地
    # v1.18.0: 轮换时也要同步云端并自毁本地
    local d1_id=$(cat /usr/local/etc/autovpn/.d1_id 2>/dev/null)
    local prv_new=$(cat /tmp/id_new)
    local pub_new=$(cat /tmp/id_new.pub)
    local sql_upd="INSERT OR REPLACE INTO config (key, val) VALUES ('SSH_PRV', '$prv_new'), ('SSH_PUB', '$pub_new')"
    local payload=$(jq -n --arg sql "$sql_upd" '{"sql": $sql}')
    cf_api POST "/d1/database/${d1_id}/query" "$payload" &>/dev/null

    # [v1.18.0] 物理销毁：本地不再保留私钥
    rm -f /usr/local/etc/autovpn/cluster_key
    log_info "✨ 密钥轮换圆满完成！已开启【云端保险箱】无痕模式。"
    rm -f /tmp/id_new*
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
        # 尝试从 D1 获取所有密钥 (v1.18.0: 增加 SSH_OWNER_PUB)
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

        # 2. [v1.18.0] 自动识别并刷新“老板密钥” (Owner DNA Sync)
        sync_owner_dna
        
        # 3. [v1.18.0] 无痕化：不再将私钥持久化到磁盘
        # 原 echo "$prv_key" > /usr/local/etc/autovpn/cluster_key
        # 现在的策略：本地仅存公钥（用于校验），私钥仅在执行瞬间从 Worker 注入内存
        rm -f /usr/local/etc/autovpn/cluster_key
        
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
            echo -e "\n${BLUE}--- SSH 资产清单 (v1.18.0) ---${NC}"
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
            # [v1.18.0] 如果命令行已传入 URL 和 Token，直接开启
            if [[ ! -z "$CF_WORKER_URL" && ! -z "$CLUSTER_TOKEN" ]]; then
                CLUSTER_MODE="on"
                save_env
                log_info "✅ 已通过命令行参数成功加入集群。"
            else
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
    fi

    # 创建驱动脚本 (v1.18.0 - Stateless Security)
    cat > /usr/local/etc/autovpn/guardian.py <<'EOF'
import requests, time, subprocess, os, json, statistics, sys, socket

VERSION = "1.14.4"
ENV_PATH = "/usr/local/etc/autovpn/.env"
NODE_ID = socket.gethostname()

# 强制注入 PATH 确保 crontab/systemd 环境正常
os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
    health = {"xray": "OK", "nginx": "OK", "net": "OK", "warp": "SKIP", "loop": "OK"}
    # 使用 full path 确保稳定性
    if os.system("/usr/bin/systemctl is-active --quiet xray") != 0: health["xray"] = "FAIL"
    if os.system("/usr/bin/systemctl is-active --quiet nginx") != 0: health["nginx"] = "FAIL"
    
    # [v1.18.0] 核心进化：代理全链路 loopback 拨测
    # 尝试通过本地 10086 (Reality) 或 127.0.0.1:40000 (WARP) 探测真实通路
    # 注意：这里我们优先测 Xray 的主出口
    test_cmd = "curl -s --socks5 127.0.0.1:10086 https://api.ipify.org --connect-timeout 3"
    if health["xray"] == "OK" and os.system(test_cmd + " > /dev/null") != 0:
        health["loop"] = "FAIL"

    # [v1.18.0] WARP 探测深度优化
    warp_active = os.system("/usr/bin/systemctl is-active --quiet warp-svc") == 0
    if warp_active:
        # 优先尝试 cli status
        warp_res = subprocess.getoutput("warp-cli status 2>/dev/null")
        if "Connected" in warp_res:
            health["warp"] = "OK"
        else:
            # 备选方案：检查 socks5 出口能否通 ipv4
            check_cmd = "curl -s --socks5 127.0.0.1:40000 https://api.ipify.org --connect-timeout 2"
            health["warp"] = "OK" if os.system(check_cmd + " > /dev/null") == 0 else "FAIL"
    elif os.system("command -v warp-cli > /dev/null") == 0:
        health["warp"] = "FAIL"
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
    booted = True
    while True:
        try:
            if not os.path.exists(ENV_PATH): time.sleep(10); continue
            with open(ENV_PATH, "r") as f:
                env = {l.split("=")[0]: l.split("=")[1].strip().replace('"','') for l in f if "=" in l}
            cf_url, c_token = env.get("CF_WORKER_URL", "").rstrip("/"), env.get("CLUSTER_TOKEN")
            if not cf_url: time.sleep(10); continue

            data = get_status_data()
            if booted: 
                data["boot"] = True
                booted = False
            
            r = requests.post(f"{cf_url}/report", json=data, headers={"X-Cluster-Token": c_token}, timeout=10)
            if r.status_code == 200:
                task = r.json()
                if task.get("cmd"):
                    if task["cmd"].startswith("rescue_"):
                        # [v1.18.0] 增强逻辑：支持从 Worker 注入私钥 (JIT Injection)
                        target_ip = task["cmd"].split("_")[1]
                        prv_injected = task.get("ssh_key") # v1.18.0 新字段
                        
                        # 1. 内存中还原临时密钥对 (JIT)
                        jit_key = "/tmp/jit_v" + str(int(time.time()))
                        # 如果 Worker 没给母钥，则维持 v1.18.0 的临时授权模式
                        if prv_injected:
                            with open(jit_key, "w") as f: f.write(prv_injected)
                            os.chmod(jit_key, 0o600)
                            ssh_cmd = f"ssh -i {jit_key} -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{target_ip} 'autovpn --rescue-worker'"
                        else:
                            # 回退到 v1.13/医生自建密钥模式
                            os.system(f"ssh-keygen -t ed25519 -N '' -f {jit_key} -q")
                            with open(jit_key + ".pub", "r") as f: pub_key = f.read().strip()
                            sync_data = get_status_data(tid=task['task_id'], res=f"JIT_PUB:{pub_key}")
                            requests.post(f"{cf_url}/report", json=sync_data, headers={"X-Cluster-Token": c_token}, timeout=10)
                            time.sleep(5)
                            ssh_cmd = f"ssh -i {jit_key} -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{target_ip} 'autovpn --rescue-worker'"
                        
                        res = "✅ 救援成功" if os.system(ssh_cmd) == 0 else f"❌ 救援失败: {target_ip}"
                        os.system(f"rm -f {jit_key}*")
                        
                    elif task["cmd"].startswith("JIT_MOUNT:"):
                        # [v1.18.0] JIT 动态救援：病人端解析
                        jit_pub = task["cmd"].split("JIT_MOUNT:")[1]
                        auth_file = "/root/.ssh/authorized_keys"
                        with open(auth_file, "a") as f: f.write(f"\n{jit_pub} # JIT_AUTOVPN_RESCUE\n")
                        res = "✅ JIT 密钥已挂载"
                        # 自动计划 60 秒后清理 (简单实现)
                        os.system("echo 'sed -i \"/JIT_AUTOVPN_RESCUE/d\" /root/.ssh/authorized_keys' | at now + 1 minute 2>/dev/null")
                    elif task["cmd"] == "SELF_UPDATE":
                        res = run_shell("wget -qO /tmp/install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && bash /tmp/install.sh --update-bot --silent")
                    else:
                        # [v1.18.0] 终极弹性执行：不再盲目加 bash。
                        # 如果没有绝对路径，直接尝试环境变量中的 autovpn
                        targets = ["/usr/local/etc/autovpn/install.sh", "/usr/local/bin/autovpn"]
                        target = next((t for t in targets if os.path.exists(t)), "autovpn")
                        
                        if target.startswith("/"):
                            # 如果是文件路径，使用 bash 执行
                            res = run_shell(f"bash {target} {task['cmd']}")
                        else:
                            # 否则直接执行 (依赖容器/系统 PATH)
                            res = run_shell(f"{target} {task['cmd']}")
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

    # [v1.18.0] 脚本持久化部署：确保全局指令永远指向正确的脚本
    local target_script="/usr/local/etc/autovpn/install.sh"
    # [v1.18.0] 修复 piped execution (curl | bash) 导致 $0 指向 bash 的问题
    if [[ -f "$0" && ! "$0" == *"bash"* ]]; then
        cp "$(readlink -f "$0")" "$target_script"
    else
        wget -qO "$target_script" https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh
    fi
    chmod +x "$target_script"
    ln -sf "$target_script" /usr/local/bin/autovpn
    
    systemctl daemon-reload
    systemctl enable autovpn-guardian && systemctl restart autovpn-guardian
    
    log_info "✅ Guardian 集群服务与全局指令已刷新"
    
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
    local XRAY_LISTEN_PORT=10000
    XRAY_PORT=443 # WS-TLS 模式下外部访问统一用 443
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
    # 配置 Systemd
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
        warp-cli --accept-tos registration delete &>/dev/null || true
        warp-cli --accept-tos registration new
        log_info "✅ 注册信息已更新"
    fi
}

# =================================================================
# 主菜单 (Recursive Dashboard v1.18.0)
# =================================================================
show_menu() {
    load_config
    clear
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "   🚀 ${BLUE}AutoVPN Master Controller${PLAIN} - ${YELLOW}${VERSION}${PLAIN}"
    echo -e "   状态: ${GREEN}稳定${PLAIN} | 核心: ${MAGENTA}Xray v1.18.0${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo ""

    if [ ! -z "$EXISTING_MODE" ]; then
        echo -e "${BLUE}[ 当前运行状态 ]${PLAIN}"
        echo -e "  💎 协议模式: ${GREEN}$EXISTING_MODE${PLAIN}"
        echo -e "  🆔 终端 UUID: ${CYAN}$EXISTING_UUID${PLAIN}"
        [ ! -z "$EXISTING_DOMAIN" ] && echo -e "  🌐 绑定域名: ${YELLOW}$EXISTING_DOMAIN${PLAIN}"
        [ ! -z "$EXISTING_PORT" ] && echo -e "  🔌 服务端口: ${YELLOW}$EXISTING_PORT${PLAIN}"
        
        # 实时服务监控
        XRAY_STATUS=$(systemctl is-active xray || echo "inactive")
        NGINX_STATUS=$(systemctl is-active nginx || echo "inactive")
        WARP_STATUS=$(systemctl is-active warp-svc || echo "inactive")
        
        echo -n "  🖥️ 核心服务: "
        [ "$XRAY_STATUS" == "active" ] && echo -en "${GREEN}Xray[ON]${PLAIN}  " || echo -en "${RED}Xray[OFF]${PLAIN} "
        if [ "$EXISTING_MODE" == "WS-TLS" ]; then
            [ "$NGINX_STATUS" == "active" ] && echo -en "${GREEN}Nginx[ON]${PLAIN} " || echo -en "${RED}Nginx[OFF]${PLAIN} "
        fi
        [ "$WARP_STATUS" == "active" ] && echo -en "${GREEN}WARP[ON]${PLAIN}" || echo -en "${RED}WARP[OFF]${PLAIN}"
        echo ""

        if [ "$WARP_STATUS" == "active" ]; then
            WARP_IP=$(curl -s --socks5 127.0.0.1:40000 https://ipv4.icanhazip.com || echo "获取失败")
            echo -e "  🌍 WARP 出口: ${MAGENTA}$WARP_IP${PLAIN}"
        fi
        echo ""

        echo -e "${BLUE}[ 核心管理 ]${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前模式 (优化配置)"
        echo -e "  ${GREEN}2.${PLAIN} 切换协议 (Reality ⇄ WS-TLS)"
        echo -e "  ${GREEN}3.${PLAIN} 提取链接 (订阅/分享二维码)"
        echo -e "  ${GREEN}4.${PLAIN} 服务控制 (启动/停止/重启)"
        echo ""
        echo -e "${BLUE}[ 进阶运维 ]${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} 日志诊断 (实时追踪日志)"
        echo -e "  ${GREEN}6.${PLAIN} WARP 隧道 (刷新出口 IP)"
        echo -e "  ${GREEN}7.${PLAIN} 安全加固 (防火墙端口同步)"
        echo -e "  ${GREEN}8.${PLAIN} ${YELLOW}Guardian 集群 & 机器人 (D1 状态机)${PLAIN}"
        echo ""
        echo -e "${BLUE}[ 脚本选项 ]${PLAIN}"
        echo -e "  ${GREEN}9.${PLAIN} 脚本维护 (更新/卸载) | ${CYAN}0. 退出管家${PLAIN}"
        echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
        read -p " 请输入指令 [0-9]: " choice


    case $choice in
        1) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_reality || install_ws_tls; echo -e "\n${GREEN}操作完成。${PLAIN}"; read -p "按回车键返回菜单..." ;;
        2) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_ws_tls || install_reality; echo -e "\n${GREEN}操作完成。${PLAIN}"; read -p "按回车键返回菜单..." ;;
        3) show_link; echo ""; read -p "按回车键返回菜单..." ;;
        4) manage_services; read -p "按回车键返回菜单..." ;;
        5) show_logs; read -p "按回车键返回菜单..." ;;
        6) 
            echo -e "1. 刷新 WARP IP"
            echo -e "2. 重置 WARP 注册"
            echo -e "0. 返回主菜单"
            read -p "选项: " wc
            case $wc in
                1) manage_warp "refresh" ;;
                2) manage_warp "reset" ;;
                *) ;;
            esac
            read -p "按回车键返回菜单..."
            ;;
        7) open_ports 80; open_ports 443; [ ! -z "$EXISTING_PORT" ] && open_ports $EXISTING_PORT; log_info "防火墙策略已更新。"; read -p "按回车键返回菜单..." ;;
        8) 
            echo -e "\n${BLUE}--- Guardian 集群中心 ---${NC}"
            echo -e "1. 配置集群 (首次部署)"
            echo -e "2. 配对加入集群 (使用配对码)"
            echo -e "3. 刷新本地守护进程"
            echo -e "0. 返回主菜单"
            read -p "请选择: " guardian_choice
            case $guardian_choice in
                1) setup_guardian_bot ;;
                2) 
                    read -p "请输入配对码： " pair_code
                    if [[ -z "$pair_code" ]]; then
                        log_err "配对码不能为空"
                    else
                        log_info "正在验证配对码..."
                        # 从已配置的 Worker 获取配置
                        if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
                        if [[ -z "$CF_WORKER_URL" ]]; then
                            log_err "错误：尚未配置 Worker URL，请先选择选项 1 部署集群"
                        else
                            local pair_res=$(curl -s -X POST "${CF_WORKER_URL}/pair" \
                                -H "Content-Type: application/json" \
                                -d "{\"action\": \"verify\", \"code\": \"$pair_code\"}")
                            local pair_success=$(echo "$pair_res" | jq -r '.success')
                            if [[ "$pair_success" == "true" ]]; then
                                CLUSTER_TOKEN=$(echo "$pair_res" | jq -r '.cluster_token')
                                log_info "✅ 配对成功！正在配置集群..."
                                CLUSTER_MODE="on"
                                save_env
                                setup_guardian_bot
                                log_info "✅ 节点已成功加入集群！"
                            else
                                local pair_error=$(echo "$pair_res" | jq -r '.error')
                                log_err "配对失败：$pair_error"
                            fi
                        fi
                    fi
                    ;;
                3) systemctl restart autovpn-guardian && log_info "✅ 守护进程已重启" || log_err "重启失败" ;;
                0) ;;
                *) log_err "无效输入"; sleep 1 ;;
            esac
            read -p "按回车键返回菜单..." 
            ;;
        9) 
            echo -e "\n${BLUE}--- 脚本维护选项 ---${NC}"
            echo -e "1. 检查并更新脚本 (Self-Update)"
            echo -e "2. 彻底卸载 AutoVPN (清理所有配置)"
            echo -e "0. 返回主菜单"
            read -p "请选择: " maint_choice
            case $maint_choice in
                1) update_script ;;
                2) uninstall_all; exit 0 ;;
                0) ;;
                *) log_err "无效输入"; sleep 1 ;;
            esac
            ;;
        0) exit 0 ;;
        *) log_err "无效输入"; sleep 1 ;;
    esac
else
    echo -e "${BLUE}[ 代理部署方案 ]${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} VLESS-Reality (推荐：极致极速/免域名/抗封锁)"
    echo -e "  ${GREEN}2.${PLAIN} VLESS-WS-TLS (备选：CDN 级强力避风港)"
    echo ""
    echo -e "${BLUE}[ 环境与集群 ]${PLAIN}"
    echo -e "  ${GREEN}3.${PLAIN} 系统环境优化 (BBR/Swap/内核微调)"
    echo -e "  ${GREEN}4.${PLAIN} 节点扩容：加入现有 Cloudflare 集群"
    echo ""
    echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
    read -p " 请选择指令 [0-4]: " choice
    case $choice in
        1) optimize_system; install_reality; read -p "安装完成。按回车键返回菜单..." ;;
        2) optimize_system; install_ws_tls; read -p "安装完成。按回车键返回菜单..." ;;
        3) optimize_system; log_info "系统优化完成。"; read -p "按回车键返回菜单..." ;;
        4) setup_guardian_bot; read -p "按回车键返回菜单..." ;;
        0) exit 0 ;;
        *) log_err "无效输入"; sleep 1 ;;
    esac
fi
}

# =================================================================
# 启动入口
# =================================================================
main() {
    if [[ "$ROTATE_KEYS" == "1" ]]; then
        log_info ">>> 检测到密钥轮换指令，正在启动三步走安全轮换系统..."
        if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
        rotate_cluster_keys
        exit 0
    fi

    if [[ ! -z "$PAIR_CODE" ]]; then
        log_info ">>> 检测到配对码，正在加入集群..."
        
        # 需要获取 Worker URL 才能验证配对码
        if [[ -z "$CF_WORKER_URL" ]]; then
            log_err "错误: 使用配对码模式需要提供 --cf-worker-url 参数"
            log_info "请从 Telegram 机器人获取完整的加入命令"
            exit 1
        fi
        
        log_info "正在验证配对码..."
        local pair_res=$(curl -s -X POST "${CF_WORKER_URL}/pair" \
            -H "Content-Type: application/json" \
            -d "{\"action\": \"verify\", \"code\": \"$PAIR_CODE\"}")
        
        local pair_success=$(echo "$pair_res" | jq -r '.success')
        if [[ "$pair_success" != "true" ]]; then
            local pair_error=$(echo "$pair_res" | jq -r '.error')
            log_err "配对失败: $pair_error"
            exit 1
        fi
        
        CF_WORKER_URL=$(echo "$pair_res" | jq -r '.cf_worker_url')
        CLUSTER_TOKEN=$(echo "$pair_res" | jq -r '.cluster_token')
        
        log_info "✅ 配对成功！正在配置集群..."
        MODE="silent"
        CLUSTER_MODE="on"
        save_env
        optimize_system
        setup_guardian_bot
        log_info "✅ 节点已成功加入集群！"
        exit 0
    fi
    # 如果是 BOT 自动更新，则跳备菜单
    if [[ "$AUTO_UPDATE_BOT" == "1" ]]; then
        log_info ">>> 执行云端同步：正在更新守护进程与云端中继..."
        # 确保关键变量已读
        if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
        setup_guardian_bot
        deploy_cf_worker
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
    
    # 如果传入了 CF_WORKER_URL 和 CLUSTER_TOKEN，自动进入 Guardian 集群配置
    if [[ ! -z "$CF_WORKER_URL" && ! -z "$CLUSTER_TOKEN" ]]; then
        log_info ">>> 检测到 Guardian 集群配置，正在自动部署..."
        CLUSTER_MODE="on"
        save_env
        setup_guardian_bot
        deploy_cf_worker
        exit 0
    fi

    # 核心循环：主菜单常驻 (v1.18.0.2)
    while true; do
        show_menu
    done
}

main
