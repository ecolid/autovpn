#!/usr/bin/env bash
set -e

# =================================================================
# AutoVPN - 一键 VPS 代理配置脚本
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] $1${PLAIN}"; }

# 0. 配置文件加载与检测
CONFIG_PATH="/usr/local/etc/xray/config.json"
ENV_PATH="/usr/local/etc/autovpn/.env"

load_config() {
    if [ -f "$CONFIG_PATH" ] && [ -f "$ENV_PATH" ]; then
        IS_MANAGED_BY_AUTOVPN=true
        source "$ENV_PATH"
        EXISTING_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_PATH" 2>/dev/null)
        if grep -q "reality" "$CONFIG_PATH"; then
            EXISTING_MODE="Reality"
        else
            EXISTING_MODE="WS-TLS"
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

# WARP 管理模块
manage_warp() {
    local action=$1
    case $action in
        "refresh") warp-cli disconnect && warp-cli connect ;;
        "reset") warp-cli registration new ;;
        "install") log_info "正在安装 WARP..." ;;
    esac
}

# 主菜单
show_menu() {
    load_config
    clear
    echo -e "${BLUE}AutoVPN 一键代理安装脚本${PLAIN}"
    if [ "$IS_MANAGED_BY_AUTOVPN" == "true" ]; then
        echo -e "当前安装状态:"
        echo -e "  - 模式: ${GREEN}$EXISTING_MODE${PLAIN}"
        echo -e "  - UUID: ${YELLOW}$EXISTING_UUID${PLAIN}"
        echo ""
        echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前配置"
        echo -e "  ${GREEN}2.${PLAIN} 切换安装模式"
        echo -e "  ${GREEN}3.${PLAIN} 刷新 WARP 出口 IP"
    else
        echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS-Reality (推荐)"
        echo -e "  ${GREEN}2.${PLAIN} 安装 VLESS-WS-TLS (CDN)"
    fi
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    read -p "请选择: " choice
    case $choice in
        3) manage_warp "refresh" ;;
        *) exit 0 ;;
    esac
}

show_menu
