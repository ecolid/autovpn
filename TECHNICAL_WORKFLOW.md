# AutoVPN v1.8.3 全链路技术信息流 (Security & Data Edition)

本文件详细刻画了 **AutoVPN v1.8.3** 架构中所有核心功能的技术实现流。

---

## 1. 监控与数据罗盘流 (Data Compass)
节点不仅上报存活状态，还通过 Xray API 采集流量与质量数据。

```mermaid
sequenceDiagram
    participant X as Xray-Core
    participant G as Guardian.py
    participant D1 as Cloudflare D1
    participant T as Telegram

    Note over G: 每 10s 巡检一次
    G->>X: API: statsquery (Traffic)
    G->>G: Ping: 223.5.5.5 / 1.1.1.1 (Quality)
    G->>D1: POST /report {traff, qual, cpu, mem}
    
    Note over D1: 数据分级存储
    D1->>D1: UPDATE nodes (实时看板)
    D1->>D1: INSERT traffic_snapshots (历史趋势)

    Note over T: 用户请求报告
    T->>D1: 命令: /stats
    D1->>T: 发送图文报表 (G/ms/%)
```

---

## 2. 老板 DNA 基因同步 (Owner Guard)
确保“谁装的谁就是唯一老板”，且权限能在集群内自动扩散。

```mermaid
graph LR
    subgraph "Master setup (第一台)"
        A[install.sh] -->|扫描鉴别| B[老板公钥]
        B -->|备案| D1[(Cloudflare D1)]
    end

    subgraph "Node Expansion (新机器)"
        C[新小鸡] -->|安装脚本| D1
        D1 -->|下发 DNA| C
        C -->|写入锁孔| AC[authorized_keys]
    end
```

---

## 3. 密钥无感轮换 (Zero-Downtime Rotation)
三步走安全算法，防止机器人运维由于换钥匙而发生“物理断连”。

```mermaid
sequenceDiagram
    participant Boss as 老板 (TG)
    participant Doc as 医生节点
    participant All as 全集群节点
    participant D1 as D1 库

    Boss->>Doc: 命令: --rotate-keys
    Doc->>Doc: 原地生成 NEW_KEY 对
    Doc->>All: 步骤1 (部署): 追加 NEW_PUB_KEY 到备用锁孔
    Doc->>All: 步骤2 (验证): 尝试用 NEW_PRV_KEY SSH 握手
    Note over Doc,All: 成功后进入提交阶段
    Doc->>D1: 步骤3 (提交): 更新云端 Primary Key
    Doc->>All: 步骤4 (清理): 远程删除 OLD_PUB_KEY
```

---

## 4. 安全命令中心 (Security Center)
- **双锁并进**: 每一个节点同时挂载 **Boss Key (Full Root)** 和 **Robot Key (Restricted)**。
- **Forced Command**: 机器人钥匙被锁定在 `guardian.py --rescue-worker` 命令内，即便私钥泄露，黑客也无法执行任意命令。
- **云端持久化**: 所有的 SSH 资产（除了老板私钥）均在 Cloudflare D1 加密存储，实现“换机不换群”。

AutoVPN v1.8.3 构建了一个 **“去中心化执行，云端化配置”** 的高安全性代理集群。
