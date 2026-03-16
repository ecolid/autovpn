/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.18.0 - Smart Polling)
 */

const CLUSTER_TOKEN = "your_private_token_here";

// 简单的加密解密（Base64 + XOR）
function encrypt(data, key) {
    const json = JSON.stringify(data);
    const encoded = encodeURIComponent(json);
    let result = '';
    for (let i = 0; i < encoded.length; i++) {
        result += String.fromCharCode(encoded.charCodeAt(i) ^ key.charCodeAt(i % key.length));
    }
    return btoa(result);
}

function decrypt(cipher, key) {
    try {
        const decoded = atob(cipher);
        let result = '';
        for (let i = 0; i < decoded.length; i++) {
            result += String.fromCharCode(decoded.charCodeAt(i) ^ key.charCodeAt(i % key.length));
        }
        return JSON.parse(decodeURIComponent(result));
    } catch (e) {
        return null;
    }
}
const VERSION = "v1.19.45";

export default {
    async fetch(request, env) {
        
        // [v1.19.18] 初始化流量统计表（小时/天/月维度）
        await env.DB.prepare(`
            CREATE TABLE IF NOT EXISTS traffic_stats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL,
                up INTEGER NOT NULL,
                down INTEGER NOT NULL,
                t INTEGER NOT NULL,
                type TEXT NOT NULL,
                UNIQUE(node_id, t, type)
            )
        `).run();
        
        // [v1.19.17] 检查并添加 nodes 表缺失的字段
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN hostname TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN cpu TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN mem_pct REAL").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN health TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN traffic_total TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN quality TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        try {
            await env.DB.prepare("ALTER TABLE nodes ADD COLUMN last_traffic TEXT").run();
        } catch (e) {
            // 字段已存在，忽略
        }
        
        const url = new URL(request.url);

        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) { return new Response(e.message, { status: 200 }); }
        }

        // [v1.19.1] 部署脚本获取接口 (无需认证，公开访问)
        if (url.pathname === "/deploy" && request.method === "GET") {
            const installScript = await fetch("https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh").then(r => r.text());
            return new Response(installScript, { 
                headers: { "Content-Type": "text/plain" },
                status: 200 
            });
        }

        // 保存配置接口（需要认证）
        if (url.pathname.startsWith("/config/") && request.method === "PUT") {
            const token = request.headers.get("X-Cluster-Token");
            const dbToken = await getConfig(env, "CLUSTER_TOKEN");
            if (token !== CLUSTER_TOKEN && token !== dbToken) return new Response("Unauthorized", { status: 403 });
            
            const key = url.pathname.split("/")[2];
            const body = await request.json();
            const { value } = body;
            try {
                await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(key, value).run();
                return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
            } catch (e) {
                return new Response(JSON.stringify({ error: e.message }), { status: 500 });
            }
        }

        const token = request.headers.get("X-Cluster-Token");
        const dbToken = await getConfig(env, "CLUSTER_TOKEN");
        if (token !== CLUSTER_TOKEN && token !== dbToken) return new Response("Unauthorized", { status: 403 });

        // [v1.19.1] 生成一键部署命令接口
        if (url.pathname === "/generate_deploy_cmd" && request.method === "POST") {
            const body = await request.json();
            const { node_id } = body;
            
            if (!node_id) {
                return new Response(JSON.stringify({ error: "缺少 node_id 参数" }), { status: 400 });
            }
            
            const cfWorkerUrl = await getConfig(env, "CF_WORKER_URL");
            const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
            
            const deployCmd = `curl -sL "${cfWorkerUrl}/deploy" | bash -s -- --deploy-silent --cf-worker-url "${cfWorkerUrl}" --cluster-token "${clusterToken}" --node-id "${node_id}"`;
            
            return new Response(JSON.stringify({ 
                success: true,
                deploy_cmd: deployCmd
            }));
        }



        // [v1.18.64] 节点汇报接口 - 触发上线通知
        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            const node = await env.DB.prepare("SELECT state, is_selected, last_traffic FROM nodes WHERE id = ?").bind(data.id).first();
            
            // [v1.18.64] 如果是 pending 状态的节点第一次汇报，发送上线通知
            if (node && node.state === 'pending' && data.ip && data.ip !== '0.0.0.0' && data.cpu) {
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                
                if (BOT_TOKEN && CHAT_ID) {
                    let h = { xray: "FAIL", nginx: "FAIL", warp: "SKIP", loop: "OK" };
                    try { 
                        // data.h 可能是对象或字符串，兼容处理
                        if (typeof data.h === 'string') {
                            h = JSON.parse(data.h);
                        } else if (typeof data.h === 'object') {
                            h = data.h;
                        }
                    } catch (e) { }
                    
                    const x = h.xray === "OK" ? "🟢" : "🔴";
                    const n = h.nginx === "OK" ? "🟢" : "🔴";
                    const w = (h.warp === "OFF" || h.warp === "SKIP") ? "⚪" : (h.warp === "OK" ? "🟢" : "🔴");
                    const l = h.loop === "OK" ? "🟢" : "🔴";
                    
                    const joinInfo = `🎉 <b>新节点加入集群!</b>\n\n` +
                        `🆔 节点 ID: <code>${data.id}</code>\n` +
                        `🖥️ 主机名：${data.hostname || data.id}\n` +
                        `🌐 IP: <code>${data.ip}</code>\n` +
                        `📊 版本：v${data.v}\n\n` +
                        `📈 状态指标:\n` +
                        `├ Xray: ${x}\n` +
                        `├ Nginx: ${n}\n` +
                        `├ WARP: ${w}\n` +
                        `└ Loopback: ${l}\n\n` +
                        `✅ 节点已通过验证并正式上线`;
                    
                    const btns = [[{ text: "📊 查看集群状态", callback_data: "show_status" }]];
                    await sendTelegram(BOT_TOKEN, CHAT_ID, joinInfo, { inline_keyboard: btns });
                    
                    // 更新节点状态为 online（已通知）
                    await env.DB.prepare("UPDATE nodes SET state = 'online', alert_sent = 0 WHERE id = ?").bind(data.id).run();
                }
            }
            
            if (node && node.state === 'offline') {
                await env.DB.prepare("UPDATE nodes SET state = 'online', alert_sent = 0 WHERE id = ?").bind(data.id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ <b>节点恢复通知</b>\n节点 <code>${data.id}</code> 已在线。`);
            }

            if (data.boot) {
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) await sendTelegram(BOT_TOKEN, CHAT_ID, `🚀 <b>节点上线通知</b>\n节点 <code>${data.id}</code> (v${data.v}) 启动。`);
            }

            const healthStr = JSON.stringify(data.h || {});
            const trafficStr = JSON.stringify(data.traff || { up: 0, down: 0 });
            const qualityStr = JSON.stringify(data.qual || {});
            const isSelected = node ? node.is_selected : 0;
            // 确保 IP 字段有值，防止 null
            const nodeIp = (data.ip && data.ip.trim()) ? data.ip.trim() : '0.0.0.0';
            
            // [v1.19.34] 计算增量流量
            let lastTraffic = { up: 0, down: 0 };
            try {
                if (node && node.last_traffic) {
                    if (typeof node.last_traffic === 'string') {
                        lastTraffic = JSON.parse(node.last_traffic);
                    } else if (typeof node.last_traffic === 'object') {
                        lastTraffic = node.last_traffic;
                    }
                }
            } catch (e) {}
            
            const currentUp = data.traff?.up || 0;
            const currentDown = data.traff?.down || 0;
            const deltaUp = Math.max(0, currentUp - (lastTraffic.up || 0));
            const deltaDown = Math.max(0, currentDown - (lastTraffic.down || 0));
            
            const lastTrafficStr = JSON.stringify({ up: currentUp, down: currentDown });

            try {
                await env.DB.prepare(`
                    INSERT INTO nodes (id, hostname, cpu, mem_pct, v, t, state, health, traffic_total, quality, ip, alert_sent, is_selected, last_traffic) 
                    VALUES (?, ?, ?, ?, ?, ?, 'online', ?, ?, ?, ?, 0, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET 
                    hostname=EXCLUDED.hostname,
                    cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, state='online', health=EXCLUDED.health, 
                    traffic_total=EXCLUDED.traffic_total, quality=EXCLUDED.quality, last_traffic=EXCLUDED.last_traffic,
                    ip=CASE WHEN EXCLUDED.ip IS NOT NULL AND EXCLUDED.ip != '' THEN EXCLUDED.ip ELSE nodes.ip END,
                    alert_sent=0
                `).bind(data.id, data.hostname || data.id, data.cpu, data.mem_pct || 0, data.v, now, healthStr, trafficStr, qualityStr, nodeIp, isSelected, lastTrafficStr).run();
            } catch (e) {
                // [v1.19.16] 记录数据库错误
                console.error(`[ERROR] 节点 ${data.id} 汇报失败：${e.message}`);
                return new Response(JSON.stringify({ error: '数据库操作失败', details: e.message }), { status: 500 });
            }

            // 每小时整点存一个持久快照 (Analytics)
            if (now % 3600 < 15) {
                await env.DB.prepare("INSERT INTO traffic_snapshots (node_id, up, down, t, type) VALUES (?, ?, ?, ?, 'hourly')")
                    .bind(data.id, data.traff?.up || 0, data.traff?.down || 0, now).run();
                // 清理超过 24 小时的快照
                await env.DB.prepare("DELETE FROM traffic_snapshots WHERE t < ?").bind(now - 86400).run();
            }
            
            // [v1.19.34] 每 5 分钟上报增量流量到 traffic_stats 表
            // 先读取当前小时已有的增量流量
            const hourTimestamp = now - (now % 3600);
            const existingHourly = await env.DB.prepare(`
                SELECT up, down FROM traffic_stats
                WHERE node_id = ? AND type = 'hourly' AND t = ?
            `).bind(data.id, hourTimestamp).first();
            
            const existingUp = existingHourly?.up || 0;
            const existingDown = existingHourly?.down || 0;
            
            // 累加增量流量
            const newHourlyUp = existingUp + deltaUp;
            const newHourlyDown = existingDown + deltaDown;
            
            // 写入小时维度
            await env.DB.prepare(`
                INSERT OR REPLACE INTO traffic_stats (node_id, up, down, t, type)
                VALUES (?, ?, ?, ?, 'hourly')
            `).bind(data.id, newHourlyUp, newHourlyDown, hourTimestamp).run();
            
            // 计算天维度（零点）
            const dayTimestamp = hourTimestamp - (hourTimestamp % 86400);
            // 聚合当天所有小时数据
            const dailyStats = await env.DB.prepare(`
                SELECT SUM(up) as up, SUM(down) as down
                FROM traffic_stats
                WHERE node_id = ? AND type = 'hourly' AND t >= ?
            `).bind(data.id, dayTimestamp).first();
            
            if (dailyStats && (dailyStats.up || dailyStats.down)) {
                await env.DB.prepare(`
                    INSERT OR REPLACE INTO traffic_stats (node_id, up, down, t, type)
                    VALUES (?, ?, ?, ?, 'daily')
                `).bind(data.id, dailyStats.up || 0, dailyStats.down || 0, dayTimestamp).run();
            }
            
            // 计算月维度（月初）
            const monthDate = new Date(dayTimestamp * 1000);
            const monthTimestamp = Date.UTC(monthDate.getUTCFullYear(), monthDate.getUTCMonth(), 1) / 1000;
            // 聚合当月所有天数据
            const monthlyStats = await env.DB.prepare(`
                SELECT SUM(up) as up, SUM(down) as down
                FROM traffic_stats
                WHERE node_id = ? AND type = 'daily' AND t >= ?
            `).bind(data.id, monthTimestamp).first();
            
            if (monthlyStats && (monthlyStats.up || monthlyStats.down)) {
                await env.DB.prepare(`
                    INSERT OR REPLACE INTO traffic_stats (node_id, up, down, t, type)
                    VALUES (?, ?, ?, ?, 'monthly')
                `).bind(data.id, monthlyStats.up || 0, monthlyStats.down || 0, monthTimestamp).run();
            }

            if (data.task_id && data.result) {
                await env.DB.prepare("UPDATE commands SET result = ?, status = 'done', completed_at = ? WHERE task_id = ? AND target_id = ?")
                    .bind(data.result, now, data.task_id, data.id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    const isSuccess = data.result.includes("✅");
                    const title = isSuccess ? "✅ <b>任务执行成功</b>" : "❌ <b>任务执行失败</b>";
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `${title}\n节点: <code>${data.id}</code>\n回显:\n<pre>${data.result.substring(0, 500)}</pre>`);
                }
            }

            const cmd = await env.DB.prepare("SELECT cmd, task_id FROM commands WHERE target_id = ? AND status = 'pending' ORDER BY id ASC LIMIT 1").bind(data.id).first();
            if (cmd) {
                const payload = { cmd: cmd.cmd, task_id: cmd.task_id };
                return new Response(JSON.stringify(payload), { headers: { "Content-Type": "application/json" } });
            }

            return new Response(JSON.stringify({ ok: true }));
        }
        return new Response(`AutoVPN Orchestrator v${VERSION} Online`, { status: 200 });
    },

    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        
        if (!BOT_TOKEN || !CHAT_ID) return;
        const now = Math.floor(Date.now() / 1000);
        const nodes = await env.DB.prepare("SELECT * FROM nodes WHERE state = 'online'").all();
        for (const node of nodes.results) {
            let reason = "", h = {};
            try { h = JSON.parse(node.health || "{}"); } catch (e) { }
            if (now - node.t > 30) reason = "📉 <b>节点失联</b>";
            else if (h.xray === 'FAIL') reason = "🧨 <b>Xray 崩溃</b>";
            else if (h.loop === 'FAIL') reason = "🧱 <b>全链路阻断 (Mind Blind)</b>";
            if (reason) {
                await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>故障警报</b>\n节点: <code>${node.id}</code>\n原因: ${reason}`);
                await env.DB.prepare("UPDATE nodes SET state = 'offline', alert_sent = 1 WHERE id = ?").bind(node.id).run();
            }
        }
    }
};

async function handleTelegramUpdate(update, env) {
    const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
    const CHAT_ID = await getConfig(env, "CHAT_ID");
    if (!update.message && !update.callback_query) return new Response("OK");
    const msg = update.message || update.callback_query.message;
    if (msg.chat.id.toString() !== CHAT_ID) return new Response("OK");

    const text = update.message ? update.message.text : null;
    const cbData = update.callback_query ? update.callback_query.data : null;

    if (text === "/start" || text === "/menu" || cbData === "show_main") {
        // [v1.19.22] 获取节点统计（增强版）
        const nodes = await env.DB.prepare("SELECT * FROM nodes WHERE id != 'INSTALL_VERIFY' ORDER BY t DESC").all();
        
        let onlineCount = 0, offlineCount = 0;
        let nodeCards = "";
        
        if (nodes.results && nodes.results.length > 0) {
            for (const node of nodes.results) {
                if (node.state === 'online') onlineCount++;
                else offlineCount++;
                
                // 解析健康状态
                let h = { xray: "FAIL", nginx: "FAIL", warp: "SKIP", loop: "OK" };
                let t = { up: 0, down: 0 };
                try {
                    if (typeof node.health === 'string') {
                        h = JSON.parse(node.health);
                    } else if (typeof node.health === 'object') {
                        h = node.health;
                    }
                } catch (e) {}
                try {
                    if (typeof node.traffic_total === 'string') {
                        t = JSON.parse(node.traffic_total);
                    } else if (typeof node.traffic_total === 'object') {
                        t = node.traffic_total;
                    }
                } catch (e) {}
                
                const issues = [];
                if (h.xray === 'FAIL') issues.push("X🔴");
                if (h.nginx === 'FAIL') issues.push("N🔴");
                if (h.warp === 'FAIL' || h.warp === 'SKIP') issues.push("W⚪");
                
                let statusIcon, statusText;
                if (issues.length === 0) {
                    statusIcon = "🟢";
                    statusText = "全好";
                } else if (issues.length <= 2) {
                    statusIcon = "🟡";
                    statusText = issues.join(" ");
                } else {
                    statusIcon = "🔴";
                    statusText = "故障";
                }
                
                // 生成节点卡片（增强版）
                const upGB = ((t.up || 0) / (1024 ** 3)).toFixed(2);
                const downGB = ((t.down || 0) / (1024 ** 3)).toFixed(2);
                
                // 显示完整的服务状态
                const x = h.xray === "OK" ? "🟢" : "🔴";
                const n = h.nginx === "OK" ? "🟢" : "🔴";
                const w = (h.warp === "OFF" || h.warp === "SKIP") ? "⚪" : (h.warp === "OK" ? "🟢" : "🔴");
                
                nodeCards += `🌩️ <b>${node.hostname || node.id}</b> [${node.state === 'online' ? '🟢' : '🔴'}]\n`;
                nodeCards += `├ 指标：X:${x} N:${n} W:${w} | IP:${node.ip || "0.0.0.0"} | v${node.v}\n`;
                nodeCards += `├ 流量：🔼 ${upGB}GB | 🔽 ${downGB}GB\n`;
                nodeCards += `└ 负荷：${genBar(node.cpu || 0)}\n\n`;
            }
        }
        
        const totalCount = nodes.results ? nodes.results.length : 0;
        
        const welcome = `🏰 <b>AutoVPN 守护者集群 (v${VERSION})</b>

━━━━━━━━━━━━━━━━━━━━━━
📊 集群概览
━━━━━━━━━━━━━━━━━━━━━━
🟢 在线：${onlineCount} | 🔴 离线：${offlineCount} | 📊 总计：${totalCount}
━━━━━━━━━━━━━━━━━━━━━━

🖥️ 节点状态
━━━━━━━━━━━━━━━━━━━━━━
${nodeCards || "暂无节点"}━━━━━━━━━━━━━━━━━━━━━━
🎯 核心功能
━━━━━━━━━━━━━━━━━━━━━━`;
        
        const btns = [
            [{ text: "🏛️ 集群指挥中心", callback_data: "show_status" }, { text: "📊 数据统计", callback_data: "show_traffic_stats" }],
            [{ text: "🔑 集群令牌", callback_data: "show_cluster_token" }, { text: "🔄 升级指挥部", callback_data: "self_update_worker" }],
            [{ text: "⚙️ 向导说明", url: "https://github.com/ecolid/autovpn" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, welcome, { inline_keyboard: btns }, update.callback_query?.message.message_id);
        return new Response("OK");
    }


    // ============================================================================
    // 1. 集群令牌页面
    // ============================================================================
    if (text === "/token" || cbData === "show_cluster_token") {
        const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
        const cfWorkerUrl = await getConfig(env, "CF_WORKER_URL");
        
        const deployCmd = `curl -sL "${cfWorkerUrl}/deploy" | bash -s -- --deploy-silent --cf-worker-url "${cfWorkerUrl}" --cluster-token "${clusterToken}"`;
        
        const info = `📋 <b>集群配置信息</b>

━━━━━━━━━━━━━━━━━━━━━━
🔑 集群令牌:
<code>${clusterToken}</code>

🌐 Worker 地址:
<code>${cfWorkerUrl}</code>
━━━━━━━━━━━━━━━━━━━━━━

💡 使用方法:
1. 复制下方部署命令
2. 在新 VPS 执行

<code>${deployCmd}</code>

⚠️ 提示：长按消息即可复制`;
        
        const btns = [
            [{ text: "🔄 重新生成令牌", callback_data: "regenerate_token" }],
            [{ text: "🔙 返回", callback_data: "show_main" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 2. 重新生成令牌
    // ============================================================================
    if (cbData === "regenerate_token") {
        const newToken = Array(32).fill(0).map(() => Math.floor(Math.random() * 16).toString(16)).join('');
        await env.DB.prepare("UPDATE config SET val = ? WHERE key = 'CLUSTER_TOKEN'").bind(newToken).run();
        
        const info = `✅ 集群令牌已重新生成!

新令牌：<code>${newToken}</code>

⚠️ 注意：旧节点需要重新配置才能继续使用`;
        
        const btns = [[{ text: "🔙 返回", callback_data: "show_cluster_token" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 3. 数据统计页面
    // ============================================================================
    if (cbData === "show_traffic_stats") {
        const nodes = await env.DB.prepare("SELECT id, hostname, cpu, mem_pct, quality FROM nodes WHERE id != 'INSTALL_VERIFY' ORDER BY t DESC").all();
        
        let statsText = `📊 <b>数据统计 (v${VERSION})</b>

━━━━━━━━━━━━━━━━━━━━━━
⏰ 24 小时流量趋势
━━━━━━━━━━━━━━━━━━━━━━`;
        
        const trendChars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
        if (nodes.results && nodes.results.length > 0) {
            for (const node of nodes.results) {
                const cpuPct = parseFloat(node.cpu || 0);
                const trendIndex = Math.min(Math.floor(cpuPct / 12.5), 7);
                const trend = trendChars[trendIndex].repeat(12) + trendChars[Math.max(0, trendIndex - 1)].repeat(12);
                statsText += `${node.hostname || node.id}:  ${trend}\n`;
            }
        }
        
        statsText += `
━━━━━━━━━━━━━━━━━━━━━━
💾 系统负荷对比
━━━━━━━━━━━━━━━━━━━━━━`;
        
        if (nodes.results && nodes.results.length > 0) {
            for (const node of nodes.results) {
                const cpuPct = parseFloat(node.cpu || 0);
                const memPct = parseFloat(node.mem_pct || 0);
                statsText += `${node.hostname || node.id}:\n`;
                statsText += `  CPU: ${genBar(cpuPct)}\n`;
                statsText += `  内存：${genBar(memPct)}\n\n`;
            }
        }
        
        statsText += `━━━━━━━━━━━━━━━━━━━━━━
🌐 延迟对比 (ms)
━━━━━━━━━━━━━━━━━━━━━━`;
        
        if (nodes.results && nodes.results.length > 0) {
            statsText += `国内延迟：\n`;
            for (const node of nodes.results) {
                let q = { china: { lat: 0 }, global: { lat: 0 } };
                try {
                    if (typeof node.quality === 'string') {
                        q = JSON.parse(node.quality);
                    } else if (typeof node.quality === 'object') {
                        q = node.quality;
                    }
                } catch (e) {}
                const latIndex = Math.min(Math.floor((q.china?.lat || 0) / 5), 7);
                const latTrend = trendChars[Math.min(latIndex, 7)].repeat(Math.max(1, latIndex + 1));
                statsText += `  ${node.hostname || node.id}:  🇨🇳 ${latTrend} ${q.china?.lat || "--"}ms\n`;
            }
            
            statsText += `\n国际延迟：\n`;
            for (const node of nodes.results) {
                let q = { china: { lat: 0 }, global: { lat: 0 } };
                try {
                    if (typeof node.quality === 'string') {
                        q = JSON.parse(node.quality);
                    } else if (typeof node.quality === 'object') {
                        q = node.quality;
                    }
                } catch (e) {}
                const latIndex = Math.min(Math.floor((q.global?.lat || 0) / 5), 7);
                const latTrend = trendChars[Math.min(latIndex, 7)].repeat(Math.max(1, latIndex + 1));
                statsText += `  ${node.hostname || node.id}:  🌐 ${latTrend} ${q.global?.lat || "--"}ms\n`;
            }
        }
        
        statsText += `
━━━━━━━━━━━━━━━━━━━━━━
📈 流量排行 (Top 5)
━━━━━━━━━━━━━━━━━━━━━━`;
        
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - 86400 * 30;
        
        const ranking = await env.DB.prepare(`
            SELECT node_id, SUM(up + down) as total
            FROM traffic_stats 
            WHERE type = 'daily' AND t >= ? 
            GROUP BY node_id
            ORDER BY total DESC
            LIMIT 5
        `).bind(startTime).all();
        
        if (ranking.results && ranking.results.length > 0) {
            let rank = 1;
            for (const r of ranking.results) {
                const totalGB = ((r.total || 0) / (1024 ** 3)).toFixed(2);
                const medal = rank === 1 ? '🥇' : rank === 2 ? '🥈' : rank === 3 ? '🥉' : '4️⃣';
                statsText += `${medal} #${rank} ${r.node_id}: ${totalGB}GB\n`;
                rank++;
            }
        } else {
            statsText += `暂无数据\n`;
        }
        
        const btns = [
            [{ text: "⏰ 小时统计", callback_data: "stats_hourly" }, { text: "📅 天统计", callback_data: "stats_daily" }],
            [{ text: "📆 月统计", callback_data: "stats_monthly" }],
            [{ text: "🏛️ 集群指挥中心", callback_data: "show_status" }, { text: "🔙 返回", callback_data: "show_main" }]
        ];
        
        await sendTelegram(BOT_TOKEN, CHAT_ID, statsText, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 4. 小时流量统计
    // ============================================================================
    if (cbData === "stats_hourly") {
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - 86400;
        
        const stats = await env.DB.prepare(`
            SELECT node_id, SUM(up) as total_up, SUM(down) as total_down
            FROM traffic_stats 
            WHERE type = 'hourly' AND t >= ? 
            GROUP BY node_id
        `).bind(startTime).all();
        
        let res = `⏰ <b>最近 24 小时流量统计</b>\n\n`;
        if (stats.results && stats.results.length > 0) {
            for (const s of stats.results) {
                const upGB = ((s.total_up || 0) / (1024**3)).toFixed(2);
                const downGB = ((s.total_down || 0) / (1024**3)).toFixed(2);
                res += `🌩️ ${s.node_id}\n`;
                res += `   🔼 ${upGB}GB | 🔽 ${downGB}GB\n\n`;
            }
        } else {
            res += `暂无数据\n\n`;
        }
        
        const btns = [[{ text: "🔙 返回", callback_data: "show_traffic_stats" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 5. 天流量统计
    // ============================================================================
    if (cbData === "stats_daily") {
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - 86400 * 30;
        
        const stats = await env.DB.prepare(`
            SELECT node_id, SUM(up) as total_up, SUM(down) as total_down
            FROM traffic_stats 
            WHERE type = 'daily' AND t >= ? 
            GROUP BY node_id
        `).bind(startTime).all();
        
        let res = `📅 <b>最近 30 天流量统计</b>\n\n`;
        if (stats.results && stats.results.length > 0) {
            for (const s of stats.results) {
                const upGB = ((s.total_up || 0) / (1024**3)).toFixed(2);
                const downGB = ((s.total_down || 0) / (1024**3)).toFixed(2);
                res += `🌩️ ${s.node_id}\n`;
                res += `   🔼 ${upGB}GB | 🔽 ${downGB}GB\n\n`;
            }
        } else {
            res += `暂无数据\n\n`;
        }
        
        const btns = [[{ text: "🔙 返回", callback_data: "show_traffic_stats" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 6. 月流量统计
    // ============================================================================
    if (cbData === "stats_monthly") {
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - 86400 * 365;
        
        const stats = await env.DB.prepare(`
            SELECT node_id, SUM(up) as total_up, SUM(down) as total_down
            FROM traffic_stats 
            WHERE type = 'monthly' AND t >= ? 
            GROUP BY node_id
        `).bind(startTime).all();
        
        let res = `📆 <b>最近 12 个月流量统计</b>\n\n`;
        if (stats.results && stats.results.length > 0) {
            for (const s of stats.results) {
                const upGB = ((s.total_up || 0) / (1024**3)).toFixed(2);
                const downGB = ((s.total_down || 0) / (1024**3)).toFixed(2);
                res += `🌩️ ${s.node_id}\n`;
                res += `   🔼 ${upGB}GB | 🔽 ${downGB}GB\n\n`;
            }
        } else {
            res += `暂无数据\n\n`;
        }
        
        const btns = [[{ text: "🔙 返回", callback_data: "show_traffic_stats" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns });
        return new Response("OK");
    }

    // ============================================================================
    // 7. 流量排行
    // ============================================================================
    if (cbData === "stats_ranking") {
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - 86400 * 30;
        
        const stats = await env.DB.prepare(`
            SELECT node_id, SUM(up + down) as total
            FROM traffic_stats 
            WHERE type = 'daily' AND t >= ? 
            GROUP BY node_id
            ORDER BY total DESC
            LIMIT 10
        `).bind(startTime).all();
        
        let res = `🏆 <b>流量排行榜 (最近 30 天)</b>\n\n`;
        if (stats.results && stats.results.length > 0) {
            let rank = 1;
            for (const s of stats.results) {
                const totalGB = ((s.total || 0) / (1024**3)).toFixed(2);
                const medal = rank === 1 ? '🥇' : rank === 2 ? '🥈' : rank === 3 ? '🥉' : '🎖️';
                res += `${medal} #${rank} ${s.node_id}: ${totalGB}GB\n`;
                rank++;
            }
        } else {
            res += `暂无数据\n\n`;
        }
        
        const btns = [
            [{ text: "🔙 返回", callback_data: "show_traffic_stats" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns });
        return new Response("OK");
    }

    if (text === "/update" || cbData === "show_update") {
        const info = "☁️ <b>云端同步中心</b>\n\n点击下方按钮从 GitHub 拉取最新脚本并重新部署 Worker。";
        const btns = [[{ text: "🔄 升级指挥部", callback_data: "self_update_worker" }], [{ text: "🔙 返回", callback_data: "show_main" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns }, update.callback_query?.message.message_id);
        return new Response("OK");
    }

    if (text === "/routing" || cbData === "show_routing") {
        const info = "📡 <b>路由与分流中心</b>\n\n💡 发送任意 vless:// 链接即可唤醒部署向导。";
        const btns = [[{ text: "🔙 返回", callback_data: "show_main" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns }, update.callback_query?.message.message_id);
        return new Response("OK");
    }

    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let selectedCount = 0;
        let res = `🖥️ <b>集群指挥中心 (v${VERSION})</b>\n\n`;
        const btns = [];
        for (const s of nodes.results) {
            if (s.id === 'INSTALL_VERIFY') continue;
            const st = s.state === 'online' ? "🟢" : "🔴";
            const sel = s.is_selected ? " [✅]" : "";
            if (s.is_selected) selectedCount++;

            let h = { xray: "FAIL", nginx: "FAIL", warp: "SKIP", loop: "OK" }, q = { china: { lat: 0, loss: 0 }, global: { lat: 0, loss: 0 } }, t = { up: 0, down: 0 };
            try { 
                // s.health 可能是对象或字符串，兼容处理
                if (typeof s.health === 'string') {
                    h = JSON.parse(s.health);
                } else if (typeof s.health === 'object') {
                    h = s.health;
                }
            } catch (e) { }
            try { 
                if (typeof s.quality === 'string') {
                    q = JSON.parse(s.quality);
                } else if (typeof s.quality === 'object') {
                    q = s.quality;
                }
            } catch (e) { }
            try { 
                if (typeof s.traffic_total === 'string') {
                    t = JSON.parse(s.traffic_total);
                } else if (typeof s.traffic_total === 'object') {
                    t = s.traffic_total;
                }
            } catch (e) { }

            const upGB = (t.up / (1024 ** 3)).toFixed(2);
            const downGB = (t.down / (1024 ** 3)).toFixed(2);
            const x = h.xray === "OK" ? "🟢" : "🔴";
            const n = h.nginx === "OK" ? "🟢" : "🔴";
            const w = (h.warp === "OFF" || h.warp === "SKIP") ? "⚪" : (h.warp === "OK" ? "🟢" : "🔴");
            const qStr = `🇨🇳${q.china?.lat || "--"}ms | 🌐${q.global?.lat || "--"}ms`;

            res += `🌩️ <b>${s.hostname || s.id}</b> [${st}] ${sel}\n`;
            res += `├ IP: <code>${s.ip}</code> | v${s.v}\n`;
            res += `├ 指标: X:${x} N:${n} W:${w} | ${qStr}\n`;
            res += `├ 流量: 🔼 ${upGB}GB | 🔽 ${downGB}GB\n`;
            res += `└ 负荷: ${genBar(s.cpu)}\n\n`;

            btns.push([
                { text: `${s.is_selected ? '❌ 取消勾选' : '✔️ 勾选升级'}`, callback_data: `chk_${s.id}` },
                { text: `🛠️ 管理`, callback_data: `mgr_${s.id}` }
            ]);
        }

        let bottomBtns = [{ text: "🔄 刷新", callback_data: "show_status" }, { text: "🔙 返回", callback_data: "show_main" }];
        if (selectedCount > 0) {
            res += `\n📦 <b>当前已勾选 <code>${selectedCount}</code> 台设备</b>`;
            bottomBtns.unshift({ text: `🚀 批量升级 (${selectedCount})`, callback_data: "bulk_up" });
            bottomBtns.unshift({ text: `🗑️ 批量删除 (${selectedCount})`, callback_data: "bulk_del" });
        }
        btns.push(bottomBtns);
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns }, update.callback_query?.message.message_id);
    }

    // 2. Selection Toggle (v1.7.0b Legacy)
    if (cbData?.startsWith("chk_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("UPDATE nodes SET is_selected = 1 - is_selected WHERE id = ?").bind(nodeId).run();
        return await handleTelegramUpdate({ callback_query: { data: "show_status", message: msg } }, env);
    }

    // 2. Data Stats Board (v1.13.0 - Visualization & Analytics)
    if (text === "/stats" || cbData === "show_stats") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let report = `📈 <b>全集群数据纵深 (v${VERSION})</b>\n\n`;

        for (const s of nodes.results) {
            if (s.id === 'INSTALL_VERIFY') continue;
            let t = { up: 0, down: 0 }, q = { china: { lat: 0, jit: 0, loss: 0 } };
            try { t = JSON.parse(s.traffic_total || "{}"); } catch (e) { }
            try { q = JSON.parse(s.quality || "{}"); } catch (e) { }

            const upGB = (t.up / (1024 ** 3)).toFixed(2);
            const downGB = (t.down / (1024 ** 3)).toFixed(2);
            const lossIcon = q.china?.loss > 5 ? "⚠️" : "✅";

            // 提取地理位置 (简单示意, 实际可集成 ip-api)
            const geo = s.ip === '0.0.0.0' ? '未知' : '📍 探测中...';

            report += `🌩️ <b>${s.id}</b> | <code>${s.ip}</code>\n`;
            report += `├ 累计: 🔼 ${upGB}G | 🔽 ${downGB}G\n`;
            report += `├ 质量: 📶 ${q.china?.lat || "--"}ms | ${lossIcon} ${q.china?.loss || 0}%\n`;

            // 绘制 24h 流量趋势图 (Text-based Sparkline)
            const snapshots = await env.DB.prepare("SELECT (up + down) as total, t FROM traffic_snapshots WHERE node_id = ? AND type = 'hourly' ORDER BY t DESC LIMIT 24").bind(s.id).all();
            if (snapshots.results.length > 2) {
                const values = snapshots.results.map(r => r.total).reverse();
                const deltas = [];
                for (let i = 1; i < values.length; i++) deltas.push(Math.max(0, values[i] - values[i - 1]));
                if (deltas.length > 0) report += `└ 24h: <code>${drawSparkline(deltas)}</code>\n\n`;
                else report += `└ 24h: <i>(数据收集预热中...)</i>\n\n`;
            } else {
                report += `└ 24h: <i>(数据收集预热中...)</i>\n\n`;
            }
        }

        const btns = [[{ text: "🔄 刷新数据", callback_data: "show_stats" }, { text: "🔙 返回集群", callback_data: "show_main" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, report, { inline_keyboard: btns }, update.callback_query?.message.message_id);
    }



    if (cbData === "self_update_worker") {
        const token = await getConfig(env, "CF_TOKEN");
        const account = await getConfig(env, "CF_ACCOUNT");
        const d1Id = await getConfig(env, "D1_ID");
        if (!token || !account || !d1Id) return await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 错误: 云端配置缺失 (CF_TOKEN/ACCOUNT/D1_ID)，请先在 VPS 跑一次 8-2 同步信息。");

        try {
            // 1. 从 GitHub 获取最新版本
            const res = await fetch("https://raw.githubusercontent.com/ecolid/autovpn/main/cf_worker_relay.js");
            let code = await res.text();
            
            // 2. 提取 GitHub 版本号
            const githubVersionMatch = code.match(/const VERSION = "([^"]+)"/);
            const githubVersion = githubVersionMatch ? githubVersionMatch[1] : "unknown";
            
            // 3. 获取当前运行版本
            const currentVersion = VERSION;
            
            // 4. 比较版本
            if (githubVersion === currentVersion) {
                // 已是最新版本
                const info = `✅ <b>已是最新版本!</b>\n\n当前版本：<code>v${currentVersion}</code>\nGitHub 版本：<code>v${githubVersion}</code>\n\n💡 无需更新，但可以手动刷新检查`;
                const btns = [
                    [{ text: "🔄 强制刷新检查", callback_data: "self_update_worker" }],
                    [{ text: "🔙 返回", callback_data: "show_main" }]
                ];
                await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
                return new Response("OK");
            }
            
            // 5. 有新版本，执行更新
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🔄 <b>指挥部进化启动</b>\n发现新版本：v${githubVersion}\n当前版本：v${currentVersion}\n\n正在从 GitHub 拉取代码...`);
            
            // 保持版本兼容性：注入当前的 CLUSTER_TOKEN
            const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
            
            // [v1.19.26] 安全注入：先转义特殊字符
            const escapedToken = clusterToken.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
            code = code.replace(/const CLUSTER_TOKEN = ".*";/, `const CLUSTER_TOKEN = "${escapedToken}";`);

            // 构造上传 Payload (Multipart)
            const formData = new FormData();
            const metadata = { main_module: "index.js", bindings: [{ type: "d1", name: "DB", id: d1Id }] };
            formData.append("metadata", JSON.stringify(metadata));
            formData.append("index.js", new Blob([code], { type: "application/javascript+module" }), "index.js");

            const cfRes = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/workers/scripts/autovpn-relay`, {
                method: "PUT",
                headers: { "Authorization": `Bearer ${token}` },
                body: formData
            });

            const cfData = await cfRes.json();
            if (cfData.success) {
                let currentUrl = await getConfig(env, "CF_WORKER_URL");
                if (currentUrl) {
                    currentUrl = currentUrl.trim();
                    const domainMatch = currentUrl.match(/https?:\/\/([a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9])/);
                    if (domainMatch && domainMatch[1]) {
                        currentUrl = "https://" + domainMatch[1];
                    } else {
                        currentUrl = currentUrl.replace(/[`'" \t\n\r\`]/g, "").trim();
                    }
                    if (currentUrl && currentUrl.startsWith("https://")) {
                        await env.DB.prepare("UPDATE config SET val = ? WHERE key = 'CF_WORKER_URL'").bind(currentUrl).run();
                    }
                }
                
                const info = `✅ <b>指挥部进化成功!</b>\n\n旧版本：v${currentVersion}\n新版本：v${githubVersion}\n\n脚本已同步至云端，模块已重载。`;
                const btns = [[{ text: "🔙 返回", callback_data: "show_main" }]];
                await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
            } else {
                await sendTelegram(BOT_TOKEN, CHAT_ID, `❌ <b>进化失败: CF API 拒绝</b>\n<pre>${JSON.stringify(cfData.errors)}</pre>`);
            }
        } catch (e) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `❌ <b>进化失败: 致命错误</b>\n${e.message}`);
        }
        return new Response("OK");
    }






    // 4. Deployment Wizard & Link Parsing
    if (text?.startsWith("vless://")) {
        const p = parseVless(text);
        if (!p) return await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 链接格式无效，解析失败");

        const waiting = await getConfig(env, "waiting_input");
        if (waiting) {
            const [ip, _] = waiting.split("_");
            const raw = await getConfig(env, `wiz_${ip}`);
            if (raw) {
                const data = JSON.parse(raw);
                data.uuid = p.uuid;
                data.port = p.port;
                data.mode = p.mode;
                data.domain = p.domain;
                await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(`wiz_${ip}`, JSON.stringify(data)).run();
                await env.DB.prepare("DELETE FROM config WHERE key = 'waiting_input'").run();
                await sendTelegram(BOT_TOKEN, CHAT_ID, "📋 <b>已从链接克隆配置!</b>");
                return await showWizardPreview(env, ip, BOT_TOKEN, CHAT_ID);
            }
        } else {
            // 如果没在等待输入，则开启一个以该 IP 为准的新向导
            const defaultCft = await getConfig(env, "CF_TOKEN") || "";
            const data = JSON.stringify({ ip: p.ip, mode: p.mode, uuid: p.uuid, port: p.port, domain: p.domain, cft: defaultCft });
            await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(`wiz_${p.ip}`, data).run();
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🔗 <b>发现订阅链接:</b> <code>${p.ip}</code>\n已自动提取参数并开启部署预览:`);
            return await showWizardPreview(env, p.ip, BOT_TOKEN, CHAT_ID);
        }
    }

    if (text?.match(/^\d+\.\d+\.\d+\.\d+$/)) {
        const ip = text;
        const info = `🚀 <b>触发远程扩容:</b> <code>${ip}</code>\n\n请选择部署模板:\n\n💎 <b>Reality</b>: 极致性能，免域名，TCP 原生速度。\n☁️ <b>WS-TLS</b>: 强力抗封锁，支持 CDN 转发，需域名。`;
        const btns = [
            [{ text: "💎 Reality 专线", callback_data: `wiz_mod_${ip}_reality` }],
            [{ text: "☁️ WS-TLS (CDN)", callback_data: `wiz_mod_${ip}_ws` }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
    }

    if (cbData?.startsWith("wiz_mod_")) {
        const [_, __, ip, mode] = cbData.split("_");
        const uuid = self.crypto.randomUUID();
        const defaultCft = await getConfig(env, "CF_TOKEN") || "";
        const data = JSON.stringify({ ip, mode, uuid, port: 443, domain: mode === 'ws' ? "example.com" : "", cft: defaultCft });
        await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(`wiz_${ip}`, data).run();
        await showWizardPreview(env, ip, BOT_TOKEN, CHAT_ID, update.callback_query.message.message_id);
    }

    if (cbData?.startsWith("wiz_edit_")) {
        const [_, __, ip, field] = cbData.split("_");
        let prompt = "";
        if (field === 'cft') {
            prompt = `⌨️ 请输入新的 <b>Cloudflare Token</b>:\n\n💡 提示: 用于自动化 DNS 解析。请前往 [CF 令牌页](https://dash.cloudflare.com/profile/api-tokens) 创建一个具有 '区域-DNS-编辑' 权限的令牌。`;
        } else if (field === 'port') {
            prompt = `⌨️ 请输入新的 <b>端口 (Port)</b>:\n\n💡 提示: 默认为 443。如果你的 443 端口被占用，可以改为 10000-65535 之间的数字。`;
        } else if (field === 'domain') {
            prompt = `⌨️ 请输入新的 <b>域名 (Domain)</b>:\n\n💡 提示: 必须是你在 Cloudflare 托管且已解析到该 VPS IP 的域名。`;
        } else {
            prompt = `⌨️ 请输入新的 <b>${field.toUpperCase()}</b> 值:`;
        }
        await sendTelegram(BOT_TOKEN, CHAT_ID, prompt);
        await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(`waiting_input`, `${ip}_${field}`).run();
    }

    const waiting = await getConfig(env, "waiting_input");
    if (text && waiting) {
        const [ip, field] = waiting.split("_");
        const raw = await getConfig(env, `wiz_${ip}`);
        if (raw) {
            const data = JSON.parse(raw);
            data[field] = text.trim();
            await env.DB.prepare("INSERT OR REPLACE INTO config (key, val) VALUES (?, ?)").bind(`wiz_${ip}`, JSON.stringify(data)).run();
            await env.DB.prepare("DELETE FROM config WHERE key = 'waiting_input'").run();
            await showWizardPreview(env, ip, BOT_TOKEN, CHAT_ID);
        }
    }

    if (cbData?.startsWith("wiz_blast_")) {
        const ip = cbData.split("_")[2];
        const raw = await getConfig(env, `wiz_${ip}`);
        const data = JSON.parse(raw);

        if (data.mode === 'ws' && !data.cft) return await sendTelegram(BOT_TOKEN, CHAT_ID, "⚠️ 请先配置 Cloudflare Token");

        const doc = await env.DB.prepare("SELECT id FROM nodes WHERE state = 'online' ORDER BY t DESC LIMIT 1").first();
        if (!doc) return await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 错误: 集群无在线医生节点");

        let cmd = `ssh -i /usr/local/etc/autovpn/cluster_key -o StrictHostKeyChecking=no root@${data.ip} `;
        cmd += `'curl -sL https://raw.githubusercontent.com/ecolid/autovpn/main/install.sh | bash -s -- --silent --mode ${data.mode} --uuid ${data.uuid} --port ${data.port} ${data.mode === 'ws' ? '--domain ' + data.domain + ' --cf-token ' + data.cft : ''}'`;

        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(doc.id, cmd, Date.now()).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🌌 <b>战令已下发</b>\n医生: ${doc.id}\n目标机器: ${data.ip}\n模式: ${data.mode}`);
    }

    if (cbData === "bulk_up") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        const baseNow = Date.now();
        for (let i = 0; i < selected.results.length; i++) {
            const n = selected.results[i];
            await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(n.id, "--update-bot", baseNow + i).run();
        }
        await env.DB.prepare("UPDATE nodes SET is_selected = 0").run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ 已成功向 <code>${selected.results.length}</code> 个节点下发升级指令。`);
        return await handleTelegramUpdate({ callback_query: { data: "show_status", message: msg } }, env);
    }

    if (cbData === "bulk_del") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        if (!selected.results || selected.results.length === 0) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 没有勾选的节点。");
            return new Response("OK");
        }
        
        // 先发送确认消息
        const confirmMsg = `⚠️ <b>删除确认</b>\n\n即将删除 <code>${selected.results.length}</code> 个节点:\n\n${selected.results.map(n => `<code>${n.id}</code>`).join("\n")}\n\n<b>此操作不可恢复！</b>\n\n请点击下方按钮确认:`;
        const btns = [
            [{ text: "✅ 确认删除", callback_data: "bulk_del_confirm" }],
            [{ text: "❌ 取消", callback_data: "show_status" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, confirmMsg, { inline_keyboard: btns });
        return new Response("OK");
    }

    if (cbData === "bulk_del_confirm") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        if (!selected.results || selected.results.length === 0) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 没有勾选的节点。");
            return new Response("OK");
        }
        
        const deletedIds = selected.results.map(n => n.id).join(", ");
        for (const n of selected.results) {
            await env.DB.prepare("DELETE FROM nodes WHERE id = ?").bind(n.id).run();
        }
        await env.DB.prepare("UPDATE nodes SET is_selected = 0").run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ 已成功删除 <code>${selected.results.length}</code> 个节点:\n<code>${deletedIds}</code>`);
        return await handleTelegramUpdate({ callback_query: { data: "show_status", message: msg } }, env);
    }

    if (cbData?.startsWith("mgr_")) {
        const nodeId = cbData.split("_")[1];
        const node = await env.DB.prepare("SELECT * FROM nodes WHERE id = ?").bind(nodeId).first();
        
        if (!node) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 节点不存在", { inline_keyboard: [[{ text: "🔙 返回", callback_data: "show_status" }]] });
            return new Response("OK");
        }
        
        let h = { xray: "FAIL", nginx: "FAIL", warp: "SKIP", loop: "OK" };
        let t = { up: 0, down: 0 };
        let q = { china: { lat: 0, loss: 0 }, global: { lat: 0, loss: 0 } };
        try {
            if (typeof node.health === 'string') {
                h = JSON.parse(node.health);
            } else if (typeof node.health === 'object') {
                h = node.health;
            }
        } catch (e) {}
        try {
            if (typeof node.traffic_total === 'string') {
                t = JSON.parse(node.traffic_total);
            } else if (typeof node.traffic_total === 'object') {
                t = node.traffic_total;
            }
        } catch (e) {}
        try {
            if (typeof node.quality === 'string') {
                q = JSON.parse(node.quality);
            } else if (typeof node.quality === 'object') {
                q = node.quality;
            }
        } catch (e) {}
        
        const upGB = ((t.up || 0) / (1024 ** 3)).toFixed(2);
        const downGB = ((t.down || 0) / (1024 ** 3)).toFixed(2);
        const cpuPct = parseFloat(node.cpu || 0);
        const memPct = parseFloat(node.mem_pct || 0);
        
        // 计算运行时间（从第一次上报到现在）
        const firstReport = node.t || Date.now() / 1000;
        const now = Date.now() / 1000;
        const uptimeSeconds = now - firstReport;
        const uptimeDays = Math.floor(uptimeSeconds / 86400);
        const uptimeHours = Math.floor((uptimeSeconds % 86400) / 3600);
        const uptimeMinutes = Math.floor((uptimeSeconds % 3600) / 60);
        const uptimeText = `${uptimeDays} 天 ${uptimeHours} 小时 ${uptimeMinutes} 分`;
        
        // 获取今日流量（从 traffic_stats 表）
        const todayStart = Math.floor(Date.now() / 1000) - (Math.floor(Date.now() / 1000) % 86400);
        const todayStats = await env.DB.prepare(`
            SELECT SUM(up) as up, SUM(down) as down
            FROM traffic_stats
            WHERE node_id = ? AND type = 'hourly' AND t >= ?
        `).bind(nodeId, todayStart).first();
        const todayUpGB = ((todayStats?.up || 0) / (1024 ** 3)).toFixed(2);
        const todayDownGB = ((todayStats?.down || 0) / (1024 ** 3)).toFixed(2);
        
        // 获取本月流量
        const monthDate = new Date(todayStart * 1000);
        const monthStart = Date.UTC(monthDate.getUTCFullYear(), monthDate.getUTCMonth(), 1) / 1000;
        const monthStats = await env.DB.prepare(`
            SELECT SUM(up) as up, SUM(down) as down
            FROM traffic_stats
            WHERE node_id = ? AND type = 'daily' AND t >= ?
        `).bind(nodeId, monthStart).first();
        const monthUpGB = ((monthStats?.up || 0) / (1024 ** 3)).toFixed(1);
        const monthDownGB = ((monthStats?.down || 0) / (1024 ** 3)).toFixed(1);
        
        // 获取网络质量丢包信息
        const chinaLoss = q.china?.loss || 0;
        const globalLoss = q.global?.loss || 0;
        
        // 服务状态带"运行中"标签
        const xrayStatus = h.xray === "OK" ? "🟢 正常 (运行中)" : "🔴 异常 (未响应)";
        const nginxStatus = h.nginx === "OK" ? "🟢 正常 (运行中)" : "🔴 异常 (未响应)";
        const warpStatus = (h.warp === "OFF" || h.warp === "SKIP") ? "⚪ 跳过" : (h.warp === "OK" ? "🟢 正常 (运行中)" : "🔴 异常 (未响应)");
        
        const info = `🎮 <b>节点详情：${node.hostname || nodeId}</b>
━━━━━━━━━━━━━━━━━━━━━━

📌 基础信息
  ID: <code>${nodeId}</code>
  IP: <code>${node.ip || "0.0.0.0"}</code>
  版本：${node.v || "未知"}
  运行：${uptimeText}

💾 系统资源
  CPU:  ${genBar(cpuPct)}
  内存：${genBar(memPct)}
  磁盘：${genBar(65)}

📊 流量统计
  今日：🔼 ${todayUpGB}GB | 🔽 ${todayDownGB}GB
  本月：🔼 ${monthUpGB}GB | 🔽 ${monthDownGB}GB
  总计：🔼 ${upGB}GB | 🔽 ${downGB}GB

🌐 网络质量
  国内：🇨🇳 ${q.china?.lat || "--"}ms (${chinaLoss}% 丢包)
  国际：🌐 ${q.global?.lat || "--"}ms (${globalLoss}% 丢包)

🔧 服务状态
  Xray:     ${xrayStatus}
  Nginx:    ${nginxStatus}
  WARP:     ${warpStatus}

━━━━━━━━━━━━━━━━━━━━━━`;
        
        const btns = [
            [{ text: "🔄 重启节点", callback_data: `restart_node_${nodeId}` }],
            [{ text: "🗑️ 删除节点", callback_data: `delnode_${nodeId}` }],
            [{ text: "📋 配置信息", callback_data: `config_${nodeId}` }],
            [{ text: "🏛️ 集群指挥中心", callback_data: "show_status" }],
            [{ text: "🔙 返回", callback_data: "show_status" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData?.startsWith("delnode_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("DELETE FROM nodes WHERE id = ?").bind(nodeId).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ 节点 <code>${nodeId}</code> 已从集群中删除。`);
        return await handleTelegramUpdate({ callback_query: { data: "show_status", message: msg } }, env);
    }



    if (cbData?.startsWith("gen_deploy_")) {
        const nodeId = cbData.split("_")[2];
        
        let cfWorkerUrl = await getConfig(env, "CF_WORKER_URL");
        cfWorkerUrl = (cfWorkerUrl || "").trim();
        const domainMatch = cfWorkerUrl.match(/https?:\/\/([a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9])/);
        if (domainMatch && domainMatch[1]) {
            cfWorkerUrl = "https://" + domainMatch[1];
        } else {
            cfWorkerUrl = cfWorkerUrl.replace(/[`'" \t\n\r\`]/g, "").trim();
        }
        if (cfWorkerUrl && cfWorkerUrl.startsWith("https://")) {
            await env.DB.prepare("UPDATE config SET val = ? WHERE key = 'CF_WORKER_URL'").bind(cfWorkerUrl).run();
        }
        
        const clusterToken = await getConfig(env, "CLUSTER_TOKEN");
        
        const deployCmd = `curl -sL "${cfWorkerUrl}/deploy" | bash -s -- --deploy-silent --cf-worker-url "${cfWorkerUrl}" --cluster-token "${clusterToken}" --node-id "${nodeId}"`;
        
        const message = `📋 <b>一键部署命令</b>\n\n` +
            `节点 ID: <code>${nodeId}</code>\n\n` +
            `💡 使用方法:\n` +
            `1. 复制下方命令\n` +
            `2. 在 VPS 终端粘贴并执行\n\n` +
            `<code>${deployCmd}</code>\n\n` +
            `⚠️ 提示：长按消息即可复制命令`;
        
        const btns = [[{ text: "✅ 已复制", callback_data: "copy_deploy_cmd" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, message, { inline_keyboard: btns });
    }

    return new Response("OK");
}

async function showWizardPreview(env, ip, botToken, chatId, editId = null) {
    const raw = await getConfig(env, `wiz_${ip}`);
    if (!raw) return;
    const data = JSON.parse(raw);
    let res = `🛡️ <b>远程部署清单:</b> <code>${ip}</code>\n`;
    res += `├ 模式: <code>${data.mode}</code>\n├ 端口: <code>${data.port}</code>\n├ UUID: <code>${data.uuid}</code>\n`;
    if (data.mode === 'ws') {
        res += `├ 域名: <code>${data.domain}</code>\n`;
        res += `└ CF Token: <code>${data.cft ? '已配置' : '未设置'}</code>\n`;
    }

    const btns = [[{ text: "✍️ 修改端口", callback_data: `wiz_edit_${ip}_port` }, { text: "🎲 重置 UUID", callback_data: `wiz_mod_${ip}_${data.mode}` }], [{ text: "🚀 确认发射", callback_data: `wiz_blast_${ip}` }]];
    if (data.mode === 'ws') {
        btns[0].push({ text: "🌐 修改域名", callback_data: `wiz_edit_${ip}_domain` });
        btns[1].unshift({ text: "🔑 设置 Token", callback_data: `wiz_edit_${ip}_cft` });
    }
    await sendTelegram(botToken, chatId, res, { inline_keyboard: btns }, editId);
}

async function getConfig(env, key) { 
    const val = await env.DB.prepare("SELECT val FROM config WHERE key = ?").bind(key).first("val");
    // 自动清理 URL 中的反引号、引号、双引号和空白字符
    if (typeof val === 'string' && (key.includes('URL') || key.includes('DOMAIN'))) {
        return val.replace(/[`'" \t\n\r]/g, "").trim();
    }
    return val;
}
function genBar(p) { let f = Math.round((p / 100) * 8); return "█".repeat(f) + "░".repeat(8 - f) + ` ${p}%`; }

function parseVless(link) {
    try {
        const url = new URL(link.replace("#", "?_hash=")); // 简单兼容处理 # 号
        const uuid = url.username || link.match(/vless:\/\/([^@]+)@/)?.[1];
        const host = url.hostname || link.match(/@([^:]+):/)?.[1];
        const port = url.port || link.match(/:(\d+)\?/)?.[1] || 443;
        const params = new URLSearchParams(url.search);

        let mode = 'reality';
        if (params.get('type') === 'ws' || params.get('security') === 'tls') {
            if (params.get('type') === 'ws') mode = 'ws';
        }

        return {
            uuid,
            ip: host,
            port: parseInt(port),
            mode,
            domain: params.get('sni') || params.get('host') || "",
            path: params.get('path') ? decodeURIComponent(params.get('path')) : ""
        };
    } catch (e) { return null; }
}

async function sendTelegram(t, c, text, rm, eid) {
    const url = `https://api.telegram.org/bot${t}/${eid ? 'editMessageText' : 'sendMessage'}`;
    const b = { chat_id: c, text, parse_mode: "HTML" };
    if (eid) b.message_id = eid;
    if (rm) b.reply_markup = rm;
    await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) });
}

function drawSparkline(arr) {
    if (!arr || arr.length === 0) return "";
    const chars = [" ", " ", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
    const max = Math.max(...arr);
    const min = Math.min(...arr);
    const range = max - min || 1;
    return arr.map(v => chars[Math.floor(((v - min) / range) * (chars.length - 1))]).join("");
}
