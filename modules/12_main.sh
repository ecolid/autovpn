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
