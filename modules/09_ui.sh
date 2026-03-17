# =================================================================
# 模块: 09_ui.sh — 用户界面（菜单、链接、日志、服务管理）
# =================================================================

show_link() {
    clear
    load_config
    if [ -z "$EXISTING_MODE" ]; then
        log_err "未检测到有效安装，无法生成链接。"
        read -p "按回车返回..."
        return
    fi

    if ! systemctl is-active --quiet xray; then
        log_err "Xray 服务未运行，无法生成有效链接。请检查服务状态。"
        read -p "按回车返回..."
        return
    fi

    IP=$(curl -s https://ipv4.icanhazip.com)
    echo -e "${GREEN}==================== 当前连接信息 ====================${PLAIN}"
    if [ "$EXISTING_MODE" == "Reality" ]; then
        PUBLIC_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$CONFIG_PATH" 2>/dev/null || echo "需重装获取")
        SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_PATH" 2>/dev/null || echo "需重装获取")
        LINK="vless://${EXISTING_UUID}@${IP}:${EXISTING_PORT}?encryption=none&security=reality&sni=${EXISTING_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#AutoVPN_Reality"
    else
        LINK="vless://${EXISTING_UUID}@${EXISTING_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${EXISTING_DOMAIN}&sni=${EXISTING_DOMAIN}&path=$(echo $EXISTING_PATH | sed 's/\//%2F/g')#AutoVPN_WS_CDN"
    fi

    echo -e "模式: ${BLUE}$EXISTING_MODE${PLAIN}"
    echo -e "UUID: ${BLUE}$EXISTING_UUID${PLAIN}"
    echo -e "\n分享链接:"
    echo -e "${GREEN}$LINK${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    read -p "按回车返回菜单..."
}

show_logs() {
    while true; do
        clear
        echo -e "${BLUE}==================== 日志管理中心 ====================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看 Xray 运行日志 (最后 50 行)"
        echo -e "  ${GREEN}2.${PLAIN} 查看 Nginx 访问日志 (WS-TLS 模式)"
        echo -e "  ${GREEN}3.${PLAIN} 查看 Nginx 错误日志"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择: " log_choice
        case $log_choice in
            1) journalctl -u xray --no-pager -n 50 ;;
            2) [ -f /var/log/nginx/access.log ] && tail -n 50 /var/log/nginx/access.log || echo "日志文件不存在" ;;
            3) [ -f /var/log/nginx/error.log ] && tail -n 50 /var/log/nginx/error.log || echo "日志文件不存在" ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

manage_services() {
    while true; do
        clear
        echo -e "${BLUE}==================== 服务控制中心 ====================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 重启所有服务 (Xray/Nginx)"
        echo -e "  ${GREEN}2.${PLAIN} 停止所有服务"
        echo -e "  ${GREEN}3.${PLAIN} 启动所有服务"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        read -p "请选择: " svc_choice
        case $svc_choice in
            1) systemctl restart xray; systemctl restart nginx 2>/dev/null; log_info "已重启" ;;
            2) systemctl stop xray; systemctl stop nginx 2>/dev/null; log_info "已停止" ;;
            3) systemctl start xray; systemctl start nginx 2>/dev/null; log_info "已启动" ;;
            0) break ;;
        esac
        read -p "按回车继续..."
    done
}

uninstall_all() {
    echo -e "${RED}警告：此操作将彻底删除 Xray, Nginx, acme.sh 以及所有配置和网站数据！${PLAIN}"
    read -p "确定要彻底卸载吗？ [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在清理系统..."
        systemctl stop xray nginx warp-svc 2>/dev/null || true
        systemctl disable xray nginx warp-svc 2>/dev/null || true
        apt purge -y xray nginx cloudflare-warp 2>/dev/null || true
        rm -rf /usr/local/etc/xray /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /var/www/html/*
        rm -rf /usr/local/etc/autovpn ~/.acme.sh
        rm -f /etc/systemd/system/xray.service /swapfile
        log_info "✅ 卸载完成，系统已恢复纯净。"
        exit 0
    fi
}

show_comparison() {
    echo -e "${BLUE}=================== 代理模式深度对比 ===================${PLAIN}"
    echo -e "${GREEN}1. VLESS-Reality (高性能免域名专线)${PLAIN}"
    echo -e "   - ${BLUE}适用场景：${PLAIN}追求极速体验，不想购买或维护域名。"
    echo -e "   - ${BLUE}工作原理：${PLAIN}完美的流控伪装，使 VPS 看起来像是在访问知名大厂网站。"
    echo -e "   - ${BLUE}优/缺点：${PLAIN}速度最快（原生 TCP），抗封锁强，但不支持 CDN 转发。"
    echo ""
    echo -e "${GREEN}2. VLESS-WS-TLS (CDN 级强力避风港)${PLAIN}"
    echo -e "   - ${BLUE}适用场景：${PLAIN}敏感时期，或 VPS 的 IP 已经被墙时使用。"
    echo -e "   - ${BLUE}工作原理：${PLAIN}将流量封包在标准 HTTPS 请求中，可通过 Cloudflare 节点转发。"
    echo -e "   - ${BLUE}优/缺点：${PLAIN}生存力极强，支持 CDN 救活 IP，但延迟比 Reality 稍高。"
    echo -e "${BLUE}========================================================${PLAIN}"
}

show_menu() {
    load_config
    clear
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "   🚀 ${BLUE}AutoVPN Master Controller${PLAIN} - ${YELLOW}${VERSION}${PLAIN}"
    echo -e "   状态: ${GREEN}稳定${PLAIN} | 核心: ${MAGENTA}Xray${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo ""

    if [ ! -z "$EXISTING_MODE" ]; then
        echo -e "${BLUE}[ 当前运行状态 ]${PLAIN}"
        echo -e "  💎 协议模式: ${GREEN}$EXISTING_MODE${PLAIN}"
        echo -e "  🆔 终端 UUID: ${CYAN}$EXISTING_UUID${PLAIN}"
        [ ! -z "$EXISTING_DOMAIN" ] && echo -e "  🌐 绑定域名: ${YELLOW}$EXISTING_DOMAIN${PLAIN}"
        [ ! -z "$EXISTING_PORT" ] && echo -e "  🔌 服务端口: ${YELLOW}$EXISTING_PORT${PLAIN}"

        XRAY_STATUS=$(systemctl is-active xray || echo "inactive")
        NGINX_STATUS=$(systemctl is-active nginx || echo "inactive")
        WARP_STATUS=$(systemctl is-active warp-svc || echo "inactive")

        echo -n "  🖥️ 核心服务: "
        [ "$XRAY_STATUS" == "active" ] && echo -en "${GREEN}Xray[ON]${PLAIN}  " || echo -en "${RED}Xray[OFF]${PLAIN} "
        if [ "$EXISTING_MODE" == "WS-TLS" ]; then
            [ "$NGINX_STATUS" == "active" ] && echo -en "${GREEN}Nginx[ON]${PLAIN} " || echo -en "${RED}Nginx[OFF]${PLAIN} "
        fi
        [ "$WARP_STATUS" == "active" ] && echo -en "${GREEN}WARP[ON]${PLAIN}" || echo -en "${RED}WARP[OFF]${PLAIN}"
        echo ""

        if [ "$WARP_STATUS" == "active" ]; then
            WARP_IP=$(curl -s --socks5 127.0.0.1:40000 https://ipv4.icanhazip.com || echo "获取失败")
            echo -e "  🌍 WARP 出口: ${MAGENTA}$WARP_IP${PLAIN}"
        fi
        echo ""

        echo -e "${BLUE}[ 核心管理 ]${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 更新/重装当前模式 (优化配置)"
        echo -e "  ${GREEN}2.${PLAIN} 切换协议 (Reality ⇄ WS-TLS)"
        echo -e "  ${GREEN}3.${PLAIN} 提取链接 (订阅/分享二维码)"
        echo -e "  ${GREEN}4.${PLAIN} 服务控制 (启动/停止/重启)"
        echo ""
        echo -e "${BLUE}[ 进阶运维 ]${PLAIN}"
        echo -e "  ${GREEN}5.${PLAIN} 日志诊断 (实时追踪日志)"
        echo -e "  ${GREEN}6.${PLAIN} WARP 隧道 (刷新出口 IP)"
        echo -e "  ${GREEN}7.${PLAIN} 安全加固 (防火墙端口同步)"
        echo -e "  ${GREEN}8.${PLAIN} ${YELLOW}Guardian 集群 & 机器人 (D1 状态机)${PLAIN}"
        echo ""
        echo -e "${BLUE}[ 脚本选项 ]${PLAIN}"
        echo -e "  ${GREEN}9.${PLAIN} 脚本维护 (更新/卸载) | ${CYAN}0. 退出管家${PLAIN}"
        echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
        read -p " 请输入指令 [0-9]: " choice

        case $choice in
            1) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_reality || install_ws_tls; echo -e "\n${GREEN}操作完成。${PLAIN}"; read -p "按回车键返回菜单..." ;;
            2) optimize_system; [ "$EXISTING_MODE" == "Reality" ] && install_ws_tls || install_reality; echo -e "\n${GREEN}操作完成。${PLAIN}"; read -p "按回车键返回菜单..." ;;
            3) show_link; echo ""; read -p "按回车键返回菜单..." ;;
            4) manage_services; read -p "按回车键返回菜单..." ;;
            5) show_logs; read -p "按回车键返回菜单..." ;;
            6)
                echo -e "1. 刷新 WARP IP"
                echo -e "2. 重置 WARP 注册"
                echo -e "0. 返回主菜单"
                read -p "选项: " wc
                case $wc in
                    1) manage_warp "refresh" ;;
                    2) manage_warp "reset" ;;
                    *) ;;
                esac
                read -p "按回车键返回菜单..."
                ;;
            7) open_ports 80; open_ports 443; [ ! -z "$EXISTING_PORT" ] && open_ports $EXISTING_PORT; log_info "防火墙策略已更新。"; read -p "按回车键返回菜单..." ;;
            8)
                echo -e "\n${BLUE}--- Guardian 集群中心 ---${NC}"
                echo -e "1. 配置集群 (首次部署)"
                echo -e "2. 刷新本地守护进程"
                echo -e "0. 返回主菜单"
                read -p "请选择: " guardian_choice
                case $guardian_choice in
                    1) setup_guardian_bot ;;
                    2) systemctl restart autovpn-guardian && log_info "✅ 守护进程已重启" || log_err "重启失败" ;;
                    0) ;;
                    *) log_err "无效输入"; sleep 1 ;;
                esac
                read -p "按回车键返回菜单..."
                ;;
            9)
                echo -e "\n${BLUE}--- 脚本维护选项 ---${NC}"
                echo -e "1. 检查并更新脚本 (Self-Update)"
                echo -e "2. 彻底卸载 AutoVPN (清理所有配置)"
                echo -e "0. 返回主菜单"
                read -p "请选择: " maint_choice
                case $maint_choice in
                    1) update_script ;;
                    2) uninstall_all; exit 0 ;;
                    0) ;;
                    *) log_err "无效输入"; sleep 1 ;;
                esac
                ;;
            0) exit 0 ;;
            *) log_err "无效输入"; sleep 1 ;;
        esac
    else
        echo -e "${BLUE}[ 代理部署方案 ]${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} VLESS-Reality (推荐：极致极速/免域名/抗封锁)"
        echo -e "  ${GREEN}2.${PLAIN} VLESS-WS-TLS (备选：CDN 级强力避风港)"
        echo ""
        echo -e "${BLUE}[ 环境与集群 ]${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 系统环境优化 (BBR/Swap/内核微调)"
        echo -e "  ${GREEN}4.${PLAIN} 节点扩容：加入现有 Cloudflare 集群"
        echo ""
        echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
        echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
        read -p " 请选择指令 [0-4]: " choice
        case $choice in
            1) optimize_system; install_reality; read -p "安装完成。按回车键返回菜单..." ;;
            2) optimize_system; install_ws_tls; read -p "安装完成。按回车键返回菜单..." ;;
            3) optimize_system; log_info "系统优化完成。"; read -p "按回车键返回菜单..." ;;
            4) setup_guardian_bot; read -p "按回车键返回菜单..." ;;
            0) exit 0 ;;
            *) log_err "无效输入"; sleep 1 ;;
        esac
    fi
}
