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

# 1. 环境初始化
init_system() {
    log_info "正在优化系统设置 (BBR, Swap)..."
    # 开启 BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 2. VLESS-Reality 部署
install_reality() {
    log_info ">>> 配置 VLESS-Reality..."
    read -p "请输入 UUID: " UUID
    UUID="${UUID:-$(uuidgen)}"
    read -p "请输入端口 [默认: 443]: " XRAY_PORT
    XRAY_PORT="${XRAY_PORT:-443}"
    # ... 简化版逻辑 ...
}

# 3. VLESS-WS-TLS 部署
install_ws_tls() {
    log_info ">>> 配置 VLESS-WS-TLS..."
    read -p "请输入域名: " DOMAIN
    # ... 简化版逻辑 ...
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}AutoVPN 一键代理安装脚本${PLAIN}"
    echo -e "--------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装 VLESS-Reality (推荐)"
    echo -e "  ${GREEN}2.${PLAIN} 安装 VLESS-WS-TLS (CDN)"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    read -p "请选择: " choice
    case $choice in
        1) install_reality ;;
        2) install_ws_tls ;;
        *) exit 0 ;;
    esac
}

init_system
show_menu
