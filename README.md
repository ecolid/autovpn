# AutoVPN 🚀

AutoVPN 是一个功能强大、交互友好的 VPS 代理/VPN 一键配置脚本。它不仅支持极致性能的 **VLESS-Reality**，还支持强力伪装的 **VLESS-WS-TLS + CDN** 模式，并集成了 **Cloudflare WARP** 与多种系统优化。

> [!TIP]
> **为什么要选择 AutoVPN？**
> 我们不仅提供了安装，还提供了一套全生命周期的 VPS 网络管理方案。它能够识别你原本复杂的环境，协助你平滑交接管理权。

## ✨ 核心特性

- **多模式支持**：
  - **Reality (推荐)**：极致性能，免域名，基于 XTLS-Reality，几乎不可被主动探测。
  - **WS-TLS + CDN**：强力伪装，支持通过 Cloudflare CDN 转发，适合极端封锁环境。
- **智能诊断与接管**：
  - **深度探测 (Deep Discovery)**：自动扫描服务器上的已有的 Xray、V2ray、Sing-box 配置，并为你展示端口与协议详情。
  - **管理权重接管**：支持一键接管非脚本安装的代理服务，实现统一管理。
- **小白友好设计**：
  - **保姆级引导**：所有输入项均附带详细中文说明和配置建议。
  - **状态看板**：启动即显示核心参数、服务运行健康度以及当前的 WARP 出口 IP。
- **系统深度优化**：
  - **网络加速**：自动开启 Google BBR 拥塞控制算法。
  - **内存增强**：低内存 VPS 自动配置并启用 Swap 交换分区。
- **分流与隐私**：
  - **WARP 解锁**：集成 Cloudflare WARP 隧道，解锁 Netflix/ChatGPT 等锁区服务。
- **自动化支持**：
  - **环境意图识别**：支持通过环境变量（如 `DOMAIN`, `UUID`）实现非交互式静默安装。
  - **智能重装**：重装时自动预填旧配置，回车即刻完成。
- **Guardian Cluster (Sentinel Edition) [v1.7.0 NEW]**:
  - **中继架构**: 基于 Cloudflare Workers + D1 SQL 的高可用集群管理，**无需 SSH**，**零端口开放**。
  - **Sentinel 跨机自愈**: 节点故障时，可指派在线节点作为“医生”，通过 SSH 互信连接一键修复“病人”节点。
  - **交互式远程扩容**: 向机器人发送 IP 即可触发向导。支持模板选配（Reality/WS）及参数（UUID/端口/域名）实时微调。
  - **极速状态看板**: 发送 `/status` 指令，秒级聚合全集群负载、组件健康度及出口 IP 视图。
  - **安全加固**: 集群内互信采用 **Forced Command** 锁死权限，秘钥由 D1 统一保险，防止横向渗透。

## 📥 快速安装

只需一行代码，即可开启安装或管理菜单：

```bash
wget -N https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install.sh && ./install.sh
```

## 🛠️ 关于管理权接管

如果你原本手动安装了其他代理核心，运行脚本后：
1. 脚本会展示探测到的配置（路径、协议、端口）。
2. 询问你是否允许接管。若同意，脚本将接管服务生命周期，并按 AutoVPN 规范更新配置。
3. 若拒绝，脚本将安全退出，不触动原始文件。

## 🛡️ 要求与环境

- **操作系统**：Ubuntu 20.04+ / Debian 11+
- **权限**：必须使用 `root` 用户运行。
- **硬件**：即便是在 512MB 内存的 VPS 上也能流畅运行。

## 🤝 贡献与维护

如果你有任何建议或发现了 Bug，欢迎通过 GitHub 提交 [Issue](https://github.com/ecolid/autovpn/issues) 或直接发起 Pull Request。

## ⚖️ 开源协议

本项目采用 [MIT License](LICENSE) 协议开源。你可以自由地使用、修改和分发。

---
*Powered by AutoVPN Team*
