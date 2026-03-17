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
