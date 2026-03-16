#!/bin/bash

# =================================================================
# AutoVPN 一键部署脚本 (方案五)
# =================================================================
# 使用方法:
#   1. 上传此脚本到可访问的服务器
#   2. 在新 VPS 执行：curl -sL https://your-server.com/deploy_node.sh | bash
#   3. 或指定节点名：curl ... | bash -s -- my-node-name
# =================================================================

# 配置参数（请根据实际情况修改）
CF_WORKER_URL="https://autovpn-relay.ealth6.workers.dev"
CLUSTER_TOKEN="de9d414831796eaee3475ee47130ca8e"

# 如果没有指定节点名，使用 VPS 的 hostname
NODE_NAME=${1:-$(hostname)}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${PLAIN} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${PLAIN} $1"
}

log_err() {
    echo -e "${RED}[ERROR]${PLAIN} $1"
}

# 检查是否 root 用户
if [ "$EUID" -ne 0 ]; then
    log_err "请使用 root 用户运行此脚本"
    exit 1
fi

# 检查网络连接
log_info "检查网络连接..."
if ! ping -c 2 -W 2 github.com > /dev/null 2>&1; then
    log_err "无法连接到 GitHub，请检查网络"
    exit 1
fi

log_info "开始部署 AutoVPN 节点..."
log_info "节点名称：$NODE_NAME"
log_info "Worker URL: $CF_WORKER_URL"

# 执行部署
log_info "正在下载并执行安装脚本..."
if curl -sL "${CF_WORKER_URL}/deploy" | bash -s -- \
    --deploy-silent \
    --cf-worker-url "${CF_WORKER_URL}" \
    --cluster-token "${CLUSTER_TOKEN}" \
    --node-id "${NODE_NAME}"; then
    
    log_info "✅ 部署成功！"
    log_info "节点名称：$NODE_NAME"
    log_info ""
    log_info "验证步骤:"
    log_info "1. 在 Telegram Bot 中发送 /status"
    log_info "2. 查看节点 '$NODE_NAME' 是否在线"
    log_info ""
    log_info "管理命令:"
    log_info "  autovpn          # 进入管理菜单"
    log_info "  autovpn log      # 查看日志"
    log_info "  autovpn restart  # 重启服务"
else
    log_err "❌ 部署失败，请检查日志或联系管理员"
    exit 1
fi
