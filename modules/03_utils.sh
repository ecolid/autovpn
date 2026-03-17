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
