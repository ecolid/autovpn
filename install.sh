#!/bin/bash
# AutoVPN - 一键 VPS 代理配置脚本
# =================================================================
# ⚠️ 此文件由 build.sh 自动生成，请勿手动编辑
# ⚠️ 修改请编辑 modules/ 下的模块文件，然后运行 ./build.sh
# =================================================================


# =================================================================
# 模块: 00_common.sh — 颜色、日志、常量、基础检查
# =================================================================

VERSION="v1.21.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
NC='\033[0m'

# 路径常量
CONFIG_PATH="/usr/local/etc/xray/config.json"
ENV_PATH="/usr/local/etc/autovpn/.env"

# 日志函数
log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] $1${PLAIN}"; }

# 信号捕获
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
# 模块: 01_args.sh — 命令行参数解析 & 管道检测
# =================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --silent) MODE="silent"; shift ;;
        --uuid) UUID="$2"; shift 2 ;;
        --port) XRAY_PORT="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --mode) INSTALL_MODE="$2"; shift 2 ;;
        --update-bot)
            ENV_PATH="/usr/local/etc/autovpn/.env"
            if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
            AUTO_UPDATE_BOT=1; MODE="silent"; shift ;;
        start|stop|restart|log|speed) CMD_ACTION="$1"; shift ;;
        --cf-worker-url) CF_WORKER_URL="$2"; shift 2 ;;
        --cluster-token) CLUSTER_TOKEN="$2"; shift 2 ;;
        --deploy-silent) DEPLOY_SILENT=1; MODE="silent"; shift ;;
        --node-id) NODE_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# 管道执行检测
has_deploy_silent=0
for arg in "$@"; do
    if [[ "$arg" == "--deploy-silent" ]]; then
        has_deploy_silent=1
        break
    fi
done

if [ $has_deploy_silent -eq 0 ] && [ ! -t 0 ] && [[ "$0" != "/tmp/autovpn_install.sh" ]]; then
    echo -e "\033[0;36m>>> 检测到管道安装模式，正在下载脚本...\033[0m"
    if curl -sL --connect-timeout 10 --max-time 60 -o /tmp/autovpn_install_new.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh; then
        chmod +x /tmp/autovpn_install_new.sh
        mv /tmp/autovpn_install_new.sh /tmp/autovpn_install.sh
        echo -e "\033[0;32m✅ 脚本下载完成，正在执行...\033[0m"
        bash /tmp/autovpn_install.sh "$@" < /dev/tty || bash /tmp/autovpn_install.sh "$@"
        exit 0
    else
        echo -e "\033[0;31m❌ 下载失败，请检查网络连接\033[0m" >&2
        echo ""
        echo "请使用以下命令手动安装："
        echo ""
        echo "  curl -sL -o install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh"
        echo "  chmod +x install.sh"
        echo "  ./install.sh"
        echo ""
        exit 1
    fi
fi

# 快速动作指令
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


# =================================================================
# 模块: 02_config.sh — 配置加载与持久化
# =================================================================

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
NODE_ID="$NODE_ID"
EOF
}

load_config() {
    # 1. 基础检测：扫描常见的代理核心和其配置文件
    CORES=()
    DISCOVERY_INFO=""

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

    # 2. 检查是否由 AutoVPN 管理
    if [ -f "$ENV_PATH" ]; then
        IS_MANAGED_BY_AUTOVPN=true
        source "$ENV_PATH"
    fi

    if [ ! -z "$DOMAIN" ] || [ ! -z "$UUID" ] || [ ! -z "$CF_TOKEN" ]; then
        IS_MANAGED_BY_AUTOVPN=true
    fi

    # 3. 处理未管理的情况（接管提示）
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

            local first_path=$(echo -e "$DISCOVERY_INFO" | grep "路径=" | head -n 1 | awk -F'路径=' '{print $2}' | awk -F',' '{print $1}')
            if [ -f "$first_path" ]; then
                log_info "正在尝试从 $first_path 提取关键配置信息..."
                EXT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$first_path" 2>/dev/null || grep -oP '"id":\s*"[a-f0-9-]{36}"' "$first_path" | head -n1 | grep -oP '[a-f0-9-]{36}')
                EXT_PORT=$(jq -r '.inbounds[0].port' "$first_path" 2>/dev/null || grep -oP '"port":\s*\d+' "$first_path" | head -n1 | grep -oP '\d+')
                EXT_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$first_path" 2>/dev/null || grep -oP '"path":\s*"[^"]+"' "$first_path" | head -n1 | grep -oP '"[^"]+"$' | tr -d '"')

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

    # 4. 解析现有配置
    if [ -f "$CONFIG_PATH" ]; then
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


# =================================================================
# 模块: 03_utils.sh — 通用工具函数
# =================================================================

# Cloudflare API 调用器
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

    if ! echo "$res" | jq -e . >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] 接收到非 JSON 响应!${NC}" >&2
        echo -e "${YELLOW}原始回显: ${NC}\n$res" >&2
        return 1
    fi

    local success=$(echo "$res" | jq -r '.success')
    if [[ "$success" != "true" ]]; then
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

# 防火墙端口开放
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

# 发送 Telegram 消息
send_tg_msg() {
    local message="$1"
    if [ ! -z "$TG_BOT_TOKEN" ] && [ ! -z "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=Markdown" > /dev/null
    fi
}


# =================================================================
# 模块: 08_tg_bot.sh — Telegram 机器人配置
# =================================================================

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


# =================================================================
# 模块: 04_system.sh — 系统环境优化
# =================================================================

optimize_system() {
    log_info ">>> 进入系统环境优化..."

    # 安装基础依赖
    apt update -y > /dev/null
    apt install -y curl unzip socat nginx git uuid-runtime gnupg lsb-release jq openssl python3-requests > /dev/null

    # BBR 加速检查
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_info "检查：系统已启用 BBR 加速，跳过。"
    else
        if [[ "$MODE" == "silent" ]]; then
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

    # Swap 虚拟内存检查
    local current_swap=$(swapon --show --noheadings | wc -l)
    if [ "$current_swap" -gt 0 ]; then
        log_info "检查：系统已存在 Swap，跳过。"
    else
        local mem_total=$(free -m | awk '/^Mem:/{print $2}')
        if [ "$mem_total" -le 1024 ]; then
            if [[ "$MODE" == "silent" ]]; then
                log_info "静默模式：检测到内存小于 1GB，自动配置 Swap..."
                swap_choice="y"
            else
                echo -e "\n${YELLOW}【重要】风险提示：开启 Swap 虚拟内存${PLAIN}"
                echo -e "说明：检测到你的内存小于 1GB。开启 Swap 可以防止因内存溢出导致的进程（如 Xray）崩溃。"
                echo -e "影响：将占用 2GB 硬盘空间。风险：对于磁盘 IO 极差的服务器，频繁交换可能导致系统卡顿。"
                read -p "是否创建 2GB Swap？ [Y/n]: " swap_choice
            fi
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

    # TG 机器人配置
    config_tg_bot
}


# =================================================================
# 模块: 11_warp.sh — WARP 管理
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
# 模块: 07_cf_worker.sh — Cloudflare Worker 部署
# =================================================================

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

    # 创建 D1 数据库
    log_info "确保依赖环境 (jq)..."
    if ! command -v jq &> /dev/null; then
        apt-get update &> /dev/null && apt-get install -y jq &> /dev/null
    fi

    log_info "正在配置云端 D1 数据库..."
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

    # 初始化 Schema
    log_info "正在初始化 SQL 表结构..."
    local sql_init="CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, hostname TEXT, cpu REAL, mem_pct REAL, v TEXT, t INTEGER, state TEXT DEFAULT 'online', health TEXT DEFAULT '{}', traffic_total TEXT DEFAULT '{}', quality TEXT DEFAULT '{}', ip TEXT, is_selected INTEGER DEFAULT 0, alert_sent INTEGER DEFAULT 0, last_traffic TEXT DEFAULT '{}');
    CREATE TABLE IF NOT EXISTS traffic_snapshots (node_id TEXT, up INTEGER, down INTEGER, t INTEGER, type TEXT DEFAULT 'realtime');
    CREATE TABLE IF NOT EXISTS traffic_stats (id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT NOT NULL, up INTEGER NOT NULL, down INTEGER NOT NULL, t INTEGER NOT NULL, type TEXT NOT NULL, UNIQUE(node_id, t, type));
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

    # 部署 Worker
    log_info "正在上传并绑定 Worker 脚本..."

    log_info "正在从 GitHub 下载最新 Worker 代码..."
    local worker_js_tmp="/tmp/index.js"
    if ! curl -sL "https://raw.githubusercontent.com/ecolid/autovpn/main/cf_worker_relay.js" -o "$worker_js_tmp"; then
        log_err "下载 Worker 代码失败"
        return 1
    fi

    sed -i "s/your_private_token_here/${CLUSTER_TOKEN}/g" "$worker_js_tmp"

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

    # 刷新机器人菜单
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

    # 获取 subdomain
    log_info "正在配置 Webhook 路由监控..."
    local subdomain=""
    while [[ -z "$subdomain" || "$subdomain" == "null" ]]; do
        local subdomain_res=$(cf_api GET "/workers/subdomain") || return 1
        subdomain=$(echo "$subdomain_res" | jq -r '.result.subdomain')
        if [[ "$subdomain" == "null" || -z "$subdomain" ]]; then
            log_err "检测到你的 CF 账户尚未配置 workers.dev 子域名。"
            echo -e "请按照上方引导完成配置后按回车重试。"
            read -p "等待中 (按回车重试)..."
        fi
    done

    CF_WORKER_URL="https://autovpn-relay.${subdomain}.workers.dev"

    # 保存 Worker URL
    curl -s -X PUT "${CF_WORKER_URL}/config/CF_WORKER_URL" \
        -H "X-Cluster-Token: ${CLUSTER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"value\": \"${CF_WORKER_URL}\"}" > /dev/null

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setWebhook" -d "url=${CF_WORKER_URL}/webhook" > /dev/null

    # 就绪确认
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}&text=🏰 <b>AutoVPN 指挥部已就位 (v${VERSION})</b>%0A✅ Webhook: 已激活%0A✅ 云端 D1: 已绑定%0A%0A等待节点加入...&parse_mode=HTML" > /dev/null

    CLUSTER_MODE="on"
    [ -z "$CLUSTER_TOKEN" ] && CLUSTER_TOKEN=$(openssl rand -hex 16)
    save_env
    systemctl restart autovpn-guardian &>/dev/null || true

    # 自检
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

verify_cluster_health() {
    sleep 3
    echo -e "\n${BLUE}--- 集群连通性深度自检 ---${NC}"
    local is_healthy=true

    # Worker 响应
    log_info "正在探测 Worker 网关状态..."
    local worker_ping=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Cluster-Token: ${CLUSTER_TOKEN}" "${CF_WORKER_URL}")
    if [[ "$worker_ping" == "200" ]]; then
        echo -e "   - Worker 网关: ${GREEN}正常 (200 OK)${NC}"
    else
        echo -e "   - Worker 网关: ${RED}异常 ($worker_ping)${NC}"
        is_healthy=false
    fi

    # Telegram Webhook
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

    # D1 数据一致性
    log_info "正在同步 D1 数据库 heartbeats..."
    local report_test=$(curl -s -X POST "${CF_WORKER_URL}/report" \
        -H "X-Cluster-Token: ${CLUSTER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"INSTALL_VERIFY\", \"cpu\": \"0\", \"mem_pct\": \"0\", \"v\": \"v1.18.0\", \"h\": {\"verify\": \"OK\"}}")

    if echo "$report_test" | grep -q "true"; then
        echo -e "   - D1 状态机: ${GREEN}正常 (读写存取 OK)${NC}"
        cf_api POST "/d1/database/${d1_id}/query" "{\"sql\": \"DELETE FROM nodes WHERE id = 'INSTALL_VERIFY'\"}" > /dev/null
    else
        echo -e "   - D1 状态机: ${RED}异常 (汇报失败)${NC}"
        is_healthy=false
    fi

    [[ "$is_healthy" == "true" ]] && return 0 || return 1
}


# =================================================================
# 模块: 06_guardian.sh — Guardian 守护进程管理 (已拆分)
# =================================================================
# 原 setup_guardian_bot (331行) 拆分为 3 个独立函数：
#   deploy_guardian_py()      — 下载并部署 guardian.py
#   configure_cluster()       — 集群模式配置（交互/静默）
#   install_guardian_service() — Systemd 服务安装与启动
# 入口函数 setup_guardian_bot() 按顺序调用以上三者

# --- 1. 部署 guardian.py ---
deploy_guardian_py() {
    log_info "正在部署 guardian.py..."

    # 确保 Python 环境
    if ! command -v python3 &> /dev/null; then
        apt-get update &> /dev/null && apt-get install -y python3 python3-requests &> /dev/null
    fi
    if ! python3 -c "import requests" &> /dev/null; then
        log_info "正在安装 Python 依赖..."
        apt-get update &> /dev/null && apt-get install -y python3-requests python3-pip &> /dev/null
        if ! python3 -c "import requests" &> /dev/null; then
            pip3 install requests &> /dev/null || true
        fi
    fi

    # 从 GitHub 下载最新 guardian.py（不再使用 heredoc）
    mkdir -p /usr/local/etc/autovpn
    if curl -sL --connect-timeout 10 --max-time 30 -o /tmp/guardian_new.py \
        "https://raw.githubusercontent.com/ecolid/autovpn/main/guardian.py"; then
        mv /tmp/guardian_new.py /usr/local/etc/autovpn/guardian.py
        chmod +x /usr/local/etc/autovpn/guardian.py
        log_info "✅ guardian.py 已更新 (v$(grep 'VERSION = ' /usr/local/etc/autovpn/guardian.py | head -1 | cut -d'\"' -f2))"
    else
        log_warn "⚠️ 从 GitHub 下载 guardian.py 失败，尝试使用本地副本..."
        # 如果下载失败且本地已有，保留现有版本
        if [ ! -f /usr/local/etc/autovpn/guardian.py ]; then
            log_err "❌ guardian.py 不存在且无法下载！"
            return 1
        fi
    fi

    # 注入 NODE_ID（如果需要）
    local env_node_id=""
    if [[ -f "$ENV_PATH" ]]; then
        env_node_id=$(grep "^NODE_ID=" "$ENV_PATH" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    fi
    local final_node_id="${NODE_ID:-$env_node_id}"

    if [[ -n "$final_node_id" && "$final_node_id" != "$(hostname)" ]]; then
        sed -i "s/^NODE_ID = .*/NODE_ID = \"$final_node_id\"/" /usr/local/etc/autovpn/guardian.py
        log_info "✅ 节点 ID 已注入：$final_node_id"
    fi
}

# --- 2. 集群模式配置 ---
configure_cluster() {
    local mode=$1

    # 检查 .env
    if [[ ! -f "$ENV_PATH" ]]; then
        log_err "❌ .env 文件不存在，无法配置集群！"
        return 1
    fi

    # NODE_ID 容错
    local env_node_id=$(grep "^NODE_ID=" "$ENV_PATH" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    if [[ -z "$env_node_id" ]]; then
        log_warn "⚠️ .env 文件中 NODE_ID 为空，将使用主机名作为节点 ID"
        env_node_id=$(hostname)
        echo "NODE_ID=\"$env_node_id\"" >> "$ENV_PATH"
        log_info "已自动设置 NODE_ID 为：$env_node_id"
    fi

    # 静默模式或已配置集群时跳过交互
    if [[ "$mode" == "silent" || ( -n "$CLUSTER_MODE" && "$CLUSTER_MODE" == "on" ) ]]; then
        # 通过命令行参数自动加入
        if [[ -n "$CF_WORKER_URL" && -n "$CLUSTER_TOKEN" ]]; then
            CLUSTER_MODE="on"
            save_env
            log_info "✅ 已通过参数成功加入集群。"
        fi
        return 0
    fi

    # 交互式集群配置（仅首次或未配置时）
    if [[ -z "$CLUSTER_MODE" || "$CLUSTER_MODE" == "off" ]]; then
        if [[ -n "$CF_WORKER_URL" && -n "$CLUSTER_TOKEN" ]]; then
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
}

# --- 3. 安装 Guardian 系统服务 ---
install_guardian_service() {
    # Systemd service
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

    # 脚本持久化
    local target_script="/usr/local/etc/autovpn/install.sh"
    if [[ ! -f "$target_script" || "$MODE" != "silent" ]]; then
        if [[ -f "$0" && ! "$0" == *"bash"* ]]; then
            cp "$(readlink -f "$0")" "$target_script"
        else
            wget -qO "$target_script" https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh
        fi
        chmod +x "$target_script"
    fi
    ln -sf "$target_script" /usr/local/bin/autovpn

    systemctl daemon-reload

    if systemctl enable autovpn-guardian && systemctl restart autovpn-guardian; then
        log_info "✅ Guardian 服务已启动并启用"

        # 等待第一次汇报测试
        log_info "正在等待 guardian 第一次汇报..."
        sleep 3

        if [[ -f "$ENV_PATH" ]]; then
            source "$ENV_PATH"
            local test_report=$(curl -s -X POST "${CF_WORKER_URL}/report" \
                -H "Content-Type: application/json" \
                -H "X-Cluster-Token: ${CLUSTER_TOKEN}" \
                -d "{\"id\":\"${NODE_ID}\",\"cpu\":\"0\",\"mem_pct\":\"0\",\"v\":\"test\",\"h\":{},\"ip\":\"0.0.0.0\",\"traff\":{},\"qual\":{}}")

            if echo "$test_report" | jq -e '.success' > /dev/null 2>&1; then
                log_info "✅ Guardian 汇报测试成功"
            else
                log_warn "⚠️ Guardian 汇报测试失败，但服务已启动"
                log_info "请检查：journalctl -u autovpn-guardian -n 20"
            fi
        fi
    else
        log_err "❌ Guardian 服务启动失败！请检查日志：journalctl -u autovpn-guardian"
        return 1
    fi

    log_info "✅ Guardian 集群服务与全局指令已刷新"

    # 清理旧的 monitor 任务
    systemctl stop autovpn-monitor.timer 2>/dev/null || true
    systemctl disable autovpn-monitor.timer 2>/dev/null || true
    rm -f /etc/systemd/system/autovpn-monitor.*
}

# --- 入口函数（保持向后兼容） ---
setup_guardian_bot() {
    local mode=$1
    log_info "正在配置 AutoVPN Guardian 集群服务..."

    deploy_guardian_py || return 1
    configure_cluster "$mode"
    install_guardian_service
}


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


# =================================================================
# 模块: 10_update.sh — 脚本在线自我更新
# =================================================================

update_script() {
    log_info "正在从 GitHub 检查最新版本..."

    local remote_version=$(curl -sL "https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh" | grep "^VERSION=" | head -1 | cut -d'"' -f2)

    if [[ -z "$remote_version" ]]; then
        log_err "无法获取远程版本号，请检查网络"
        return 1
    fi

    log_info "远程版本：$remote_version | 当前版本：$VERSION"

    if [[ "$remote_version" == "$VERSION" ]]; then
        log_info "✅ 当前已是最新版本 ($VERSION)"
        echo ""
        echo "💡 提示：如果 GitHub 还在同步中，您可以选择强制更新。"
        read -p "是否强制更新？ [y/N]: " force_update
        if [[ "$force_update" != "y" && "$force_update" != "Y" ]]; then
            return 0
        fi
    else
        log_warn "检测到新版本：$remote_version (当前 $VERSION)"
        read -p "是否立即升级？ [Y/n]: " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            return 0
        fi
    fi

    log_info "正在下载最新版本..."
    if curl -sL -o install_new.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install_new.sh; then
        mv install_new.sh install.sh
        log_info "✅ 脚本已更新到 $remote_version！正在重启..."
        sleep 1
        exec ./install.sh
    else
        log_err "下载失败，请检查网络连接"
        sleep 2
        return 1
    fi
}


# =================================================================
# 模块: 09_ui.sh — 用户界面（菜单、链接、日志、服务管理）
# =================================================================

show_link() {
    clear
    load_config
    if [ -z "$EXISTING_MODE" ]; then
        log_err "未检测到有效安装，无法生成链接。"
        read -p "按回车返回..."
        return
    fi

    if ! systemctl is-active --quiet xray; then
        log_err "Xray 服务未运行，无法生成有效链接。请检查服务状态。"
        read -p "按回车返回..."
        return
    fi

    IP=$(curl -s https://ipv4.icanhazip.com)
    echo -e "${GREEN}==================== 当前连接信息 ====================${PLAIN}"
    if [ "$EXISTING_MODE" == "Reality" ]; then
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

show_menu() {
    load_config
    clear
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "   🚀 ${BLUE}AutoVPN Master Controller${PLAIN} - ${YELLOW}${VERSION}${PLAIN}"
    echo -e "   状态: ${GREEN}稳定${PLAIN} | 核心: ${MAGENTA}Xray${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo ""

    if [ ! -z "$EXISTING_MODE" ]; then
        echo -e "${BLUE}[ 当前运行状态 ]${PLAIN}"
        echo -e "  💎 协议模式: ${GREEN}$EXISTING_MODE${PLAIN}"
        echo -e "  🆔 终端 UUID: ${CYAN}$EXISTING_UUID${PLAIN}"
        [ ! -z "$EXISTING_DOMAIN" ] && echo -e "  🌐 绑定域名: ${YELLOW}$EXISTING_DOMAIN${PLAIN}"
        [ ! -z "$EXISTING_PORT" ] && echo -e "  🔌 服务端口: ${YELLOW}$EXISTING_PORT${PLAIN}"

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
                echo -e "2. 刷新本地守护进程"
                echo -e "0. 返回主菜单"
                read -p "请选择: " guardian_choice
                case $guardian_choice in
                    1) setup_guardian_bot ;;
                    2) systemctl restart autovpn-guardian && log_info "✅ 守护进程已重启" || log_err "重启失败" ;;
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
# 模块: 12_main.sh — 启动入口
# =================================================================

main() {
    # 一键部署模式
    if [[ "$DEPLOY_SILENT" == "1" ]]; then
        log_info ">>> 检测到一键部署模式，正在自动配置集群..."

        if [[ -z "$CF_WORKER_URL" || -z "$CLUSTER_TOKEN" ]]; then
            log_err "错误：一键部署模式需要提供 --cf-worker-url 和 --cluster-token 参数"
            exit 1
        fi

        if [[ -z "$NODE_ID" ]]; then
            NODE_ID=$(hostname)
            log_info "未指定节点 ID，使用主机名：$NODE_ID"
        fi

        CLUSTER_MODE="on"
        save_env
        optimize_system
        setup_guardian_bot

        log_info "✅ 节点已成功配置！"
        log_info "节点 ID: $NODE_ID"
        log_info "请稍等几分钟，节点会自动上线并汇报状态"
        exit 0
    fi

    # BOT 自动更新模式
    if [[ "$AUTO_UPDATE_BOT" == "1" ]]; then
        if [[ ! -f "/tmp/autovpn_updated" ]]; then
            log_info ">>> 正在下载最新版本脚本..."
            if curl -sL -o /tmp/install_new.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh; then
                chmod +x /tmp/install_new.sh
                touch /tmp/autovpn_updated
                log_info "✅ 已获取最新版本，正在执行更新..."
                exec /tmp/install_new.sh --update-bot --silent
            else
                log_warn "⚠️ 下载最新版本失败，使用当前脚本继续更新"
            fi
        fi

        rm -f /tmp/autovpn_updated

        log_info ">>> 执行自动更新：正在更新本地守护进程..."
        if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
        setup_guardian_bot "silent"
        exit 0
    fi

    # 静默安装模式
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

    # 自动进入 Guardian 集群配置
    if [[ ! -z "$CF_WORKER_URL" && ! -z "$CLUSTER_TOKEN" ]]; then
        log_info ">>> 检测到 Guardian 集群配置，正在自动部署..."
        CLUSTER_MODE="on"
        save_env
        setup_guardian_bot
        deploy_cf_worker
        exit 0
    fi

    # 交互式主菜单
    while true; do
        show_menu
    done
}

main

