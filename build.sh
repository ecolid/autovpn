#!/bin/bash
# =================================================================
# build.sh — 将模块文件组装成单一 install.sh 用于分发
# 用法: ./build.sh
# =================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$SCRIPT_DIR/install.sh"

# 模块加载顺序（依赖关系决定）
MODULES=(
    "00_common.sh"    # 颜色、日志、常量、root 检查
    "01_args.sh"      # 参数解析、管道检测
    "02_config.sh"    # load_config, save_env
    "03_utils.sh"     # cf_api, open_ports, send_tg_msg
    "08_tg_bot.sh"    # config_tg_bot (被 04_system 和 07_cf_worker 调用)
    "04_system.sh"    # optimize_system (调用 config_tg_bot)
    "11_warp.sh"      # manage_warp (被 05_xray 调用)
    "07_cf_worker.sh" # deploy_cf_worker (被 06_guardian 调用)
    "06_guardian.sh"   # setup_guardian_bot (调用 deploy_cf_worker)
    "05_xray.sh"      # install_reality, install_ws_tls (调用 setup_guardian_bot, manage_warp)
    "10_update.sh"    # update_script
    "09_ui.sh"        # show_menu (调用所有其他函数)
    "12_main.sh"      # main 入口
)

echo "🔨 正在组装 install.sh..."

# 写入文件头
cat > "$OUTPUT" <<'HEADER'
#!/bin/bash
# AutoVPN - 一键 VPS 代理配置脚本
# =================================================================
# ⚠️ 此文件由 build.sh 自动生成，请勿手动编辑
# ⚠️ 修改请编辑 modules/ 下的模块文件，然后运行 ./build.sh
# =================================================================

HEADER

# 逐模块拼接
for mod in "${MODULES[@]}"; do
    mod_path="$SCRIPT_DIR/modules/$mod"
    if [[ ! -f "$mod_path" ]]; then
        echo "❌ 模块文件不存在: $mod_path"
        exit 1
    fi
    echo "" >> "$OUTPUT"
    cat "$mod_path" >> "$OUTPUT"
    echo "" >> "$OUTPUT"
done

chmod +x "$OUTPUT"

# 统计
LINES=$(wc -l < "$OUTPUT")
FUNCS=$(grep -c '^\w.*()' "$OUTPUT" || true)
echo "✅ 组装完成: $OUTPUT"
echo "   行数: $LINES | 函数数: $FUNCS"
echo "   模块: ${#MODULES[@]} 个"
