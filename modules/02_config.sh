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
