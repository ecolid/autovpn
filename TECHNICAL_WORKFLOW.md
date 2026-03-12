# AutoVPN v1.7.0 全链路技术信息流 (Sentinel Edition)

本文件详细刻画了 **AutoVPN v1.7.0** 架构中所有功能的核心信息传输流。

---

## 1. 核心看板与监控流 (Status & Monitoring)
这是集群的“基础代谢”，保证 Master 随时掌握所有节点的状态。

```mermaid
sequenceDiagram
    participant N as Node (Guardian.py)
    participant M as Master (CF Worker + D1)
    participant T as User (Telegram)

    Note over N: 每 10s 执行一次
    N->>N: 自检核心状态 (CPU/MEM/Xray/NET)
    N->>M: POST /report {status_data, IP, v1.7.0}
    M->>M: SQL: INSERT OR REPLACE INTO nodes
    M-->>N: Response: JSON {pending_cmd: null}

    Note over T: 用户输入 /status
    T->>M: Webhook Update
    M->>M: SQL: SELECT * FROM nodes
    M->>T: 发送聚合看板 (包含节点 IP, 版本, 健康度, 勾选状态)
```

---

## 2. 跨机自愈流 (Sentinel Rescue)
当 A 节点失联且无法自动拉起时，利用互信机制通过 B 节点强行修复。

```mermaid
sequenceDiagram
    participant T as User (Telegram)
    participant M as Master (CF Worker + D1)
    participant D as Doctor Node (Online)
    participant P as Patient Node (Offline)

    Note over M: Watchdog 侦测到故障
    M->>T: 推送告警 + [🚑 尝试跨机救援] 按钮
    T->>M: 点击救援
    M->>M: SQL: INSERT INTO commands (target=Doctor, cmd=rescue_PatientIP)
    
    Note over D: 下一次 Heartbeat (10s 内)
    D->>M: GET /report
    M-->>D: Task: {cmd: "rescue_PatientIP", task_id: 123}
    D->>D: 提取 /usr/local/etc/autovpn/cluster_key
    D->>P: SSH -i key root@PatientIP "exit" (触发 Forced Command)
    
    Note over P: 强制触发内置逻辑
    P->>P: 立即强制重启守护进程 & Xray
    P->>M: 心跳恢复 (State: Online)
```

---

## 3. 互动式部署向导 (Wizard Deployment)
从手机发送一个 IP 到全自动扩容新机器的全过程。

```mermaid
sequenceDiagram
    participant T as User (Telegram)
    participant M as Master (CF Worker + D1)
    participant D as Doctor Node (Provisioner)
    participant N as New VPS (Clean OS)

    T->>M: 发送新机器 IP (例如 1.2.3.4)
    M-->>T: 弹出模式选择 (Reality/WS)
    T->>M: 点击 Reality
    M-->>T: 展示参数预展清单 (UUID/Port)
    T->>M: 修改 Port -> 确认发射
    
    M->>M: 渲染安装命令: curl ... install.sh | bash -s -- --silent ...
    M->>M: SQL: INSERT INTO commands (target=Doctor)
    
    Note over D: 心跳领命
    D->>M: Heartbeat
    M-->>D: Task: {cmd: "ssh root@1.2.3.4 'curl... | bash...'"}
    D->>N: 执行 SSH 传输安装流
    Note over N: 全自动静默安装完成
    N->>M: 首次 Heartbeat 上报 (集群新增节点)
```

---

## 4. 批量管理流 (Bulk Operations)
点击一个按钮，全集群同步升级。

```mermaid
flowchart TD
    A[User Telegram] -->|勾选节点| B[Master CF Worker]
    B -->|SQL: is_selected = 1| C[(D1 Database)]
    A -->|点击 批量升级| D[Master CF Worker]
    D -->|SQL: INSERT INTO commands FOR ALL selected| C
    
    subgraph Nodes Group
        N1[Node 1]
        N2[Node 2]
        N3[Node 3]
    end
    
    C -->|Heartbeat Response| N1
    C -->|Heartbeat Response| N2
    C -->|Heartbeat Response| N3
    
    N1 -->|执行: --update-bot| N1
    N2 -->|执行: --update-bot| N2
```

---

## 5. 安全体系 (Security Model)
- **命令锁死**: 密钥对登录必须前置 `command="/usr/bin/python3 ..."`。
- **配置隔离**: 节点不知道云端 DB 账号，仅通过一个一次性的 `CLUSTER_TOKEN` 进行鉴权通讯。
- **环境隔离**: `Doctor` 节点只负责传递 Master 渲染好的“指令包”，不接触或存储任何部署后的动态密钥。

AutoVPN v1.7.0 构建了一个基于 **信任链 (Chain of Trust)** 的高可用自治集群。
