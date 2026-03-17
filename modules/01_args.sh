# =================================================================
# 模块: 01_args.sh — 命令行参数解析 & 管道检测
# =================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --silent) MODE="silent"; shift ;;
        --uuid) UUID="$2"; shift 2 ;;
        --port) XRAY_PORT="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --mode) INSTALL_MODE="$2"; shift 2 ;;
        --update-bot)
            ENV_PATH="/usr/local/etc/autovpn/.env"
            if [ -f "$ENV_PATH" ]; then source "$ENV_PATH"; fi
            AUTO_UPDATE_BOT=1; MODE="silent"; shift ;;
        start|stop|restart|log|speed) CMD_ACTION="$1"; shift ;;
        --cf-worker-url) CF_WORKER_URL="$2"; shift 2 ;;
        --cluster-token) CLUSTER_TOKEN="$2"; shift 2 ;;
        --deploy-silent) DEPLOY_SILENT=1; MODE="silent"; shift ;;
        --node-id) NODE_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# 管道执行检测
has_deploy_silent=0
for arg in "$@"; do
    if [[ "$arg" == "--deploy-silent" ]]; then
        has_deploy_silent=1
        break
    fi
done

if [ $has_deploy_silent -eq 0 ] && [ ! -t 0 ] && [[ "$0" != "/tmp/autovpn_install.sh" ]]; then
    echo -e "\033[0;36m>>> 检测到管道安装模式，正在下载脚本...\033[0m"
    if curl -sL --connect-timeout 10 --max-time 60 -o /tmp/autovpn_install_new.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh; then
        chmod +x /tmp/autovpn_install_new.sh
        mv /tmp/autovpn_install_new.sh /tmp/autovpn_install.sh
        echo -e "\033[0;32m✅ 脚本下载完成，正在执行...\033[0m"
        bash /tmp/autovpn_install.sh "$@" < /dev/tty || bash /tmp/autovpn_install.sh "$@"
        exit 0
    else
        echo -e "\033[0;31m❌ 下载失败，请检查网络连接\033[0m" >&2
        echo ""
        echo "请使用以下命令手动安装："
        echo ""
        echo "  curl -sL -o install.sh https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh"
        echo "  chmod +x install.sh"
        echo "  ./install.sh"
        echo ""
        exit 1
    fi
fi

# 快速动作指令
if [ ! -z "$CMD_ACTION" ]; then
    case $CMD_ACTION in
        start) systemctl start xray ;;
        stop) systemctl stop xray ;;
        restart) systemctl restart xray ;;
        log) journalctl -u xray --no-pager -n 50 ;;
        speed)
            if ! command -v speedtest-cli &> /dev/null; then
                apt-get update && apt-get install -y speedtest-cli
            fi
            speedtest-cli --simple
            ;;
    esac
    exit 0
fi
