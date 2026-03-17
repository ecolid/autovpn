# =================================================================
# 模块: 00_common.sh — 颜色、日志、常量、基础检查
# =================================================================

VERSION="v1.21.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
NC='\033[0m'

# 路径常量
CONFIG_PATH="/usr/local/etc/xray/config.json"
ENV_PATH="/usr/local/etc/autovpn/.env"

# 日志函数
log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] $1${PLAIN}"; }

# 信号捕获
cleanup() {
    echo -e "\n${YELLOW}检测到脚本被中断。配置未完成，你可以随时再次运行脚本继续安装。"
    exit 0
}
trap cleanup SIGINT SIGTERM

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   log_err "请使用 root 权限运行此脚本 (sudo -i)"
   exit 1
fi
