# AutoVPN

一键部署 VLESS 代理，支持两种模式，集成 [哪吒监控](https://github.com/nezhahq/nezha) Agent。

## 快速安装

```bash
curl -sL https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh | bash
```

运行后选择模式：
1. **WS + TLS + CDN** — 需要域名 + Cloudflare Token，走 CDN 抗封锁
2. **Reality** — 免域名，直连，抗检测

## 静默安装

WS 模式：
```bash
bash install.sh --mode ws --domain example.com --cf-token TOKEN --email you@example.com
```

Reality 模式：
```bash
bash install.sh --mode reality
```

带哪吒监控：
```bash
bash install.sh --mode ws --domain example.com --cf-token TOKEN --email you@example.com \
    --nezha-server nezha.example.com:8008 --nezha-secret SECRET
```

## 两种模式对比

| | WS + TLS + CDN | Reality |
|---|---|---|
| 域名 | 需要 | 不需要 |
| CF Token | 需要 | 不需要 |
| 抗封锁 | CDN 中转，IP 不暴露 | 伪装 TLS 握手 |
| 速度 | 取决于 CDN | 直连，更快 |
| 适用场景 | 重度封锁环境 | 日常使用，CF 故障备用 |

## 参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--mode` | `ws` 或 `reality` | 交互选择 |
| `--domain` | 域名 (WS 模式) | 交互输入 |
| `--cf-token` | CF API Token (WS 模式) | 交互输入 |
| `--email` | 邮箱 (WS 模式) | 交互输入 |
| `--uuid` | VLESS UUID | 自动生成 |
| `--ws-path` | WS 路径 | `/lovelinux` |
| `--port` | Xray 端口 | WS: `8443` / Reality: `443` |
| `--fake-domain` | Reality 伪装域名 | `www.cloudflare.com` |
| `--private-key` | Reality 私钥 | 自动生成 |
| `--public-key` | Reality 公钥 | 自动生成 |
| `--short-id` | Reality Short ID | 自动生成 |
| `--nezha-server` | 哪吒面板地址 | 可选 |
| `--nezha-secret` | 哪吒 Agent Secret | 可选 |

## 环境要求

- Ubuntu 20.04+ / Debian 11+
- root 权限
- 512MB+ 内存

## 协议

[MIT License](LICENSE)
