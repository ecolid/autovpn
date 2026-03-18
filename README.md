# AutoVPN

一键部署 VLESS + WS + TLS + WARP 代理，集成 [哪吒监控](https://github.com/nezhahq/nezha) Agent 自动安装。

## 快速安装

```bash
curl -sL https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh | bash
```

或下载后执行：

```bash
wget -N https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh && chmod +x install.sh && ./install.sh
```

## 静默安装（无交互）

```bash
bash install.sh --domain example.com --cf-token YOUR_TOKEN --email you@example.com --uuid YOUR_UUID
```

带哪吒监控：

```bash
bash install.sh --domain example.com --cf-token YOUR_TOKEN --email you@example.com \
    --nezha-server nezha.example.com:8008 --nezha-secret YOUR_SECRET
```

## 功能

- **VLESS + WS + TLS** — 通过 Cloudflare CDN 转发，抗封锁
- **Cloudflare WARP** — 出口 IP 伪装，解锁地区限制
- **自动 DNS** — 自动创建/更新 Cloudflare DNS 记录并开启 CDN
- **自动 SSL** — 通过 acme.sh + DNS 验证自动申请证书
- **哪吒监控** — 可选安装 Agent，接入哪吒面板统一监控

## 部署参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--domain` | 域名 | 交互输入 |
| `--cf-token` | Cloudflare API Token | 交互输入 |
| `--email` | 邮箱（SSL 证书） | 交互输入 |
| `--uuid` | VLESS UUID | 自动生成 |
| `--ws-path` | WebSocket 路径 | `/lovelinux` |
| `--port` | Xray 监听端口 | `8443` |
| `--nezha-server` | 哪吒面板地址 | 可选 |
| `--nezha-secret` | 哪吒 Agent Secret | 可选 |

## 环境要求

- Ubuntu 20.04+ / Debian 11+
- root 权限
- 512MB+ 内存

## 协议

[MIT License](LICENSE)
