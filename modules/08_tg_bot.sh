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
