# =================================================================
# 模块: 11_warp.sh — WARP 管理
# =================================================================

manage_warp() {
    local action="$1"

    if [ "$action" == "install" ]; then
        if ! command -v warp-cli &> /dev/null; then
            log_info "安装 Cloudflare WARP..."
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
            apt update -y && apt install -y cloudflare-warp
        fi
        systemctl enable warp-svc && systemctl restart warp-svc && sleep 3
        warp-cli --accept-tos registration new || true
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port 40000
        warp-cli --accept-tos connect
    elif [ "$action" == "refresh" ]; then
        log_info "正在刷新 WARP 节点 IP..."
        warp-cli --accept-tos disconnect
        sleep 2
        warp-cli --accept-tos connect
        log_info "✅ 已发起重连"
    elif [ "$action" == "reset" ]; then
        log_info "正在重置 WARP 注册信息..."
        warp-cli --accept-tos registration delete &>/dev/null || true
        warp-cli --accept-tos registration new
        log_info "✅ 注册信息已更新"
    fi
}
