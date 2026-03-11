# AutoVPN 技术流程全解析 (D1 Edition v1.3.0)

本文件详细解释 v1.3.0 **全量 D1 SQL Serverless** 架构。

---

## 1. 架构升级：从 KV 到 D1 (SQL)

在 v1.3.0 中，我们引入了 Cloudflare D1 (关系型 SQL 数据库) 作为核心状态机。

### 为什么选择 D1？
- **100倍写入额度**: Cloudflare KV 每天限额 1000 次写入，而 D1 每天支持 **10 万次** 免费写入。
- **高频监控**: 得益于高限额，节点可以每 30 秒进行一次心跳，实现真正的“准实时”监控。
- **结构化查询**: 可以通过 SQL 语句快速筛选失联节点，代码逻辑更清晰。

---

## 2. 实时报警系统 (Watchdog)

系统通过 Cloudflare Cron Trigger 实现“哨兵”模式：

1. **心跳 (Node Heartbeat)**: 节点每 30 秒向 Worker 发送 POST 请求，Worker 执行 SQL 将时间戳存入 `nodes` 表。
2. **巡检 (Watchdog)**: Cloudflare 每分钟自动唤醒 Worker 执行 `scheduled` 任务。
3. **计算 (Logic)**: Worker 查询数据库，寻找 `last_seen < (now - 60s)` 的节点。
4. **报警 (Alert)**: 发现超时节点，Worker 直接通过 Telegram Bot 推送报警。
5. **恢复 (Auto-recovery)**: 节点重新上线后，报警标记自动重置。

---

## 3. SQL 数据库模型 (Schema)

```sql
-- 节点状态表
CREATE TABLE nodes (
    id TEXT PRIMARY KEY,
    cpu REAL,
    mem_pct REAL,
    v TEXT,
    t INTEGER,             -- 最后心跳时间戳
    is_selected INTEGER,   -- 勾选状态 (0/1)
    alert_sent INTEGER     -- 是否已发送开除通知
);

-- 指令队列表
CREATE TABLE commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id TEXT,
    cmd TEXT,
    task_id INTEGER,
    status TEXT DEFAULT 'pending'
);
```

---

## 4. 指令分发逻辑 (Command Flow)

1. **触发**: 用户在 Telegram 点击“更新”或“重启”。
2. **入库**: Worker 将指令插入 `commands` 表。
3. **拉取**: 节点在下一次 30s 心跳时，Worker 会查询对应的 `pending` 指令并在 Response 中下发。
4. **确认**: 节点取走指令后，Worker 将该指令状态设为 `done`。

---

## 5. 极致稳定性

- **无主架构**: 报警逻辑不依赖任何 VPS，由 Cloudflare 托管。
- **自动初始化**: `install.sh` 会自动检测并创建 D1 数据库、建表并完成绑定。
- **一键自愈**: 配合 OTA 更新，节点可随时拉取最新脚本进行自我修复。

---

AutoVPN v1.3.0 是目前市面上最轻量、最稳健且成本最低的集群管理方案。
