# AutoVPN 🚀

VPS 代理一键配置工具。专为极致体验设计，集成系统优化与强力代理。

## ✨ 特性

- **多模式支持**：Reality (高速度) 与 WS-TLS (强伪装)。
- **系统优化**：自动开启 Google BBR 加速，低内存 VPS 自动配置 Swap。
- **自动分流**：集成 Cloudflare WARP 出口，解锁被禁 IP 服务。
- **网站伪装**：自动部署 2048 网页小游戏。
- **极简链接**：安装完成后直接输出 VLESS 分享链接。

## 📥 快速安装

只需一行代码，即可开始：

```bash
wget -N https://raw.githubusercontent.com/your-username/vps/main/autovpn/install.sh && chmod +x install.sh && ./install.sh
```
> [!NOTE]
> 请注意将上面的 `your-username` 替换为您实际的仓库用户名。

## 🛠️ 交互菜单

1. **VLESS-Reality**: 最推荐的方式。不需要域名，配置简单，几乎不可被墙主动探测。
2. **VLESS-WS-TLS**: 通过 Cloudflare CDN 转发。需要您拥有一个域名并托管在 Cloudflare，适合极端封锁环境。

## ⚠️ 要求

- 操作系统：Ubuntu 20.04+ / Debian 11+
- 用户：必须使用 `root` 用户运行。
