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

# 1. 环境初始化
init_system() {
    log_info "正在优化系统设置..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 2. VLESS-Reality 部署
install_reality() {
    log_info ">>> 配置 VLESS-Reality..."
    read -p "请输入 UUID [当前: ${UUID:-$(uuidgen)}]: " UUID
    UUID="${UUID:-$(uuidgen)}"
    read -p "请输入端口 [目前: 443]: " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-443}"
    save_env
    log_info "Reality 安装完成。"
}

# 3. VLESS-WS-TLS 部署
install_ws_tls() {
    log_info ">>> 配置 VLESS-WS-TLS..."
    read -p "请输入域名 [当前: ${DOMAIN}]: " DOMAIN
    read -p "请输入 Cloudflare Token: " CF_TOKEN
    save_env
    log_info "WS-TLS 安装完成。"
}

# 主菜单
show_menu() {
    load_config
    clear
    echo -e "${BLUE}AutoVPN 一键代理安装脚本${PLAIN}"
    if [ "$IS_MANAGED_BY_AUTOVPN" == "true" ]; then
        echo -e "已检测到安装模式: ${GREEN}$EXISTING_MODE${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前配置"
        echo -e "  ${GREEN}2.${PLAIN} 切换安装模式"
    else
        echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS-Reality (推荐)"
        echo -e "  ${GREEN}2.${PLAIN} 安装 VLESS-WS-TLS (CDN)"
    fi
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    read -p "请选择: " choice
    # 选择逻辑简化
    case $choice in
        1) install_reality ;;
        2) install_ws_tls ;;
        *) exit 0 ;;
    esac
}

init_system
show_menu
