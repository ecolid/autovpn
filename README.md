# AutoVPN

一键 VPS 代理配置脚本，支持 **VLESS-Reality** 和 **VLESS-WS-TLS + CDN** 双模式，集成 Cloudflare Worker 集群管理和 Telegram Bot 控制面板。

## 快速安装

```bash
wget -N https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install.sh && ./install.sh
```

## 功能

- **VLESS-Reality** — 极致性能，免域名，基于 XTLS-Reality
- **VLESS-WS-TLS + CDN** — 通过 Cloudflare CDN 转发，适合封锁环境
- **Cloudflare WARP** — 解锁地区限制服务
- **Guardian 集群** — Telegram Bot 远程管理多节点，流量统计，健康监控
- **系统优化** — BBR 加速、Swap 自动配置
- **智能接管** — 自动检测并接管已有 Xray/V2ray/Sing-box 安装

## 项目结构

```
autovpn/
├── install.sh            # 分发文件（由 build.sh 自动生成，勿手动编辑）
├── guardian.py            # 节点守护进程（独立文件，从 GitHub 下载部署）
├── cf_worker_relay.js     # Cloudflare Worker 中继 + Telegram Bot
├── deploy_node.sh         # 一键部署封装
├── build.sh               # 模块组装器
└── modules/
    ├── 00_common.sh       # 颜色、日志、常量、root 检查
    ├── 01_args.sh         # 命令行参数解析、管道检测
    ├── 02_config.sh       # 配置加载 (load_config) 与持久化 (save_env)
    ├── 03_utils.sh        # 工具函数 (cf_api, open_ports, send_tg_msg)
    ├── 04_system.sh       # 系统优化 (BBR, Swap)
    ├── 05_xray.sh         # Xray 安装 (Reality + WS-TLS)
    ├── 06_guardian.sh     # Guardian 部署（拆分为 3 个独立函数）
    ├── 07_cf_worker.sh    # Cloudflare Worker 部署
    ├── 08_tg_bot.sh       # Telegram Bot 配置
    ├── 09_ui.sh           # 交互菜单、链接生成、日志、服务管理
    ├── 10_update.sh       # 脚本自更新
    ├── 11_warp.sh         # WARP 管理
    └── 12_main.sh         # 入口函数 (main)
```

## 开发

修改 `modules/` 下的模块文件，然后运行：

```bash
./build.sh
```

会自动组装生成 `install.sh`。**不要直接编辑 `install.sh`**。

## 更新流程

- **更新 VPS**：VPS 上执行菜单选项 9→1（更新脚本 + 重装）
- **更新 Worker**：Telegram Bot 点击 "🔄 升级指挥部"
- **更新 Guardian**：`guardian.py` 作为独立文件从 GitHub 下载，跟随脚本更新自动部署

## 环境要求

- Ubuntu 20.04+ / Debian 11+
- root 权限
- 512MB+ 内存

## 协议

[MIT License](LICENSE)
