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
