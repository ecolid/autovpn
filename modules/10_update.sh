# =================================================================
# 模块: 10_update.sh — 脚本在线自我更新
# =================================================================

update_script() {
    log_info "正在从 GitHub 检查最新版本..."

    local remote_version=$(curl -sL "https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh" | grep "^VERSION=" | head -1 | cut -d'"' -f2)

    if [[ -z "$remote_version" ]]; then
        log_err "无法获取远程版本号，请检查网络"
        return 1
    fi

    log_info "远程版本：$remote_version | 当前版本：$VERSION"

    if [[ "$remote_version" == "$VERSION" ]]; then
        log_info "✅ 当前已是最新版本 ($VERSION)"
        echo ""
        echo "💡 提示：如果 GitHub 还在同步中，您可以选择强制更新。"
        read -p "是否强制更新？ [y/N]: " force_update
        if [[ "$force_update" != "y" && "$force_update" != "Y" ]]; then
            return 0
        fi
    else
        log_warn "检测到新版本：$remote_version (当前 $VERSION)"
        read -p "是否立即升级？ [Y/n]: " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            return 0
        fi
    fi

    log_info "正在下载最新版本..."
    if curl -sL -o install_new.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install_new.sh; then
        mv install_new.sh install.sh
        log_info "✅ 脚本已更新到 $remote_version！正在重启..."
        sleep 1
        exec ./install.sh
    else
        log_err "下载失败，请检查网络连接"
        sleep 2
        return 1
    fi
}
