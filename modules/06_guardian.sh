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
