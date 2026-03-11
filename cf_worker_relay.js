/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.5.0 - State-Aware Edition)
 * High-frequency heartbeats (10s) with state-aware alerting logic.
 */

const CLUSTER_TOKEN = "your_private_token_here"; // Replaced by install.sh

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        // 1. Telegram Webhook (The Master Logic)
        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) { return new Response(e.message, { status: 200 }); }
        }

        // Security check for VPS nodes
        const token = request.headers.get("X-Cluster-Token");
        if (token !== CLUSTER_TOKEN) return new Response("Unauthorized", { status: 403 });

        // 2. Node Heartbeat & Command Retrieval: POST /report
        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            // [v1.5.0] State Transition Detection (Offline -> Online)
            const node = await env.DB.prepare("SELECT state FROM nodes WHERE id = ?").bind(data.id).first();
            if (node && node.state === 'offline') {
                await env.DB.prepare("UPDATE nodes SET state = 'online', alert_sent = 0 WHERE id = ?").bind(data.id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ <b>节点重连通知</b>\n节点 <code>${data.id}</code> 已恢复连接。`);
                }
            }

            // Heartbeat Update
            await env.DB.prepare(`
                INSERT INTO nodes (id, cpu, mem_pct, v, t, state, alert_sent) 
                VALUES (?, ?, ?, ?, ?, 'online', 0)
                ON CONFLICT(id) DO UPDATE SET 
                cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, state='online', alert_sent=0
            `).bind(data.id, data.cpu, data.mem_pct, data.v, now).run();

            // Handle result reporting
            if (data.task_id && data.result) {
                await env.DB.prepare("UPDATE commands SET result = ?, status = 'done', completed_at = ? WHERE task_id = ?")
                    .bind(data.result, now, data.task_id).run();

                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    const isSuccess = data.result.includes("✅");
                    const title = isSuccess ? "✅ <b>任务执行成功</b>" : "❌ <b>任务执行失败</b>";
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `${title}\n节点: <code>${data.id}</code>\n回显详情:\n<pre>${data.result.substring(0, 1000)}</pre>`);
                }
            }

            // Fetch pending command
            const cmd = await env.DB.prepare("SELECT cmd, task_id FROM commands WHERE target_id = ? AND status = 'pending' ORDER BY id ASC LIMIT 1").bind(data.id).first();
            if (cmd) return new Response(JSON.stringify({ cmd: cmd.cmd, task_id: cmd.task_id }), { headers: { "Content-Type": "application/json" } });

            return new Response(JSON.stringify({ ok: true }));
        }

        return new Response("AutoVPN Orchestrator v1.5.0 Online", { status: 200 });
    },

    // 3. Watchdog (Every Minute)
    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        if (!BOT_TOKEN || !CHAT_ID) return;

        const now = Math.floor(Date.now() / 1000);
        // [v1.5.0] 故障判定：超过 30s 无心跳 且 状态还是 'online'
        const deadNodes = await env.DB.prepare("SELECT id FROM nodes WHERE t < ? AND state = 'online'").bind(now - 30).all();

        for (const node of deadNodes.results) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>节点失联报警 (30s)</b>\n节点 <code>${node.id}</code> 无响应，正在切换至离线状态。`);
            await env.DB.prepare("UPDATE nodes SET state = 'offline', alert_sent = 1 WHERE id = ?").bind(node.id).run();
        }
    }
};

async function handleTelegramUpdate(update, env) {
    const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
    const CHAT_ID = await getConfig(env, "CHAT_ID");
    if (!update.message && !update.callback_query) return new Response("OK");

    const msg = update.message || update.callback_query.message;
    const chatId = msg.chat.id.toString();
    if (chatId !== CHAT_ID) return new Response("OK");

    const text = update.message ? update.message.text : null;
    const cbData = update.callback_query ? update.callback_query.data : null;

    // Dashboard
    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let res = "📊 <b>集群监控项 (v1.5.0)</b>\n";
        const btns = [];
        for (const s of nodes.results) {
            const status = s.state === 'online' ? "🟢" : "�";
            res += `<b>${s.id}</b> [${status}]\n ├ CPU: ${genBar(s.cpu)}\n └ Mem: ${genBar(s.mem_pct)} (v${s.v})\n\n`;
            btns.push([{ text: `🛠️ 管理 ${s.id}`, callback_data: `mgr_${s.id}` }]);
        }
        btns.push([{ text: "🔄 刷新数据", callback_data: "show_status" }]);
        await sendTelegram(BOT_TOKEN, chatId, res, { inline_keyboard: btns }, update.callback_query ? update.callback_query.message.message_id : null);
    }

    // Command Dispatch (truncated for brevity, logic remains v1.4.1+)
    if (cbData && cbData.startsWith("mgr_")) {
        const nodeId = cbData.split("_")[1];
        const btns = [
            [{ text: "📝 修改配置", callback_data: `sub_cfg_${nodeId}` }],
            [{ text: "⚡ 服务控制", callback_data: `sub_svc_${nodeId}` }],
            [{ text: "⚙️ 系统管理", callback_data: `sub_sys_${nodeId}` }],
            [{ text: "🔍 诊断查询", callback_data: `sub_diag_${nodeId}` }],
            [{ text: "🔙 返回主列表", callback_data: "show_status" }]
        ];
        await sendTelegram(BOT_TOKEN, chatId, `🎮 <b>管理节点:</b> <code>${nodeId}</code>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData && cbData.startsWith("sub_")) {
        const parts = cbData.split("_");
        const type = parts[1];
        const nodeId = parts[2];
        let btns = [];
        if (type === "cfg") btns = [[{ text: "🔑 更换 UUID", callback_data: `run_${nodeId}_--uuid` }]];
        else if (type === "svc") btns = [[{ text: "🔄 重启服务", callback_data: `run_${nodeId}_restart` }], [{ text: "🛑 停止服务", callback_data: `run_${nodeId}_stop` }]];
        else if (type === "sys") btns = [[{ text: "🚀 切换 BBR", callback_data: `run_${nodeId}_--bbr` }]];
        else if (type === "diag") btns = [[{ text: "🔗 获取链接", callback_data: `run_${nodeId}_--link` }], [{ text: "📄 查看日志", callback_data: `run_${nodeId}_--logs` }]];
        btns.push([{ text: "🔙 返回", callback_data: `mgr_${nodeId}` }]);
        await sendTelegram(BOT_TOKEN, chatId, `📂 <b>子菜单 - ${type.toUpperCase()}</b>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData && cbData.startsWith("run_")) {
        const parts = cbData.split("_");
        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(parts[1], parts[2], Date.now()).run();
        await sendTelegram(BOT_TOKEN, chatId, `⏳ 指令 <code>${parts[2]}</code> 已下发至 <code>${parts[1]}</code>`, null, update.callback_query.message.message_id);
    }

    if (text === "/update") {
        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 升级选中项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多选升级</b>", { inline_keyboard: btns });
    }

    if (cbData && cbData.startsWith("chk_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("UPDATE nodes SET is_selected = 1 - is_selected WHERE id = ?").bind(nodeId).run();
        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 升级选中项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多选升级</b>", { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData === "bulk_up") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        for (const n of selected.results) await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(n.id, "--update-bot", Date.now()).run();
        await env.DB.prepare("UPDATE nodes SET is_selected = 0").run();
        await sendTelegram(BOT_TOKEN, chatId, `✅ 已推送 ${selected.results.length} 个升级任务。`);
    }

    return new Response("OK");
}

async function getConfig(env, key) {
    return await env.DB.prepare("SELECT val FROM config WHERE key = ?").bind(key).first("val");
}

function genBar(pct, length = 10) {
    try {
        let p = parseFloat(pct);
        let filled = Math.round((p / 100) * length);
        if (filled > length) filled = length;
        if (filled < 0) filled = 0;
        return "█".repeat(filled) + "░".repeat(length - filled) + ` ${p.toFixed(1)}%`;
    } catch (e) { return "░".repeat(length) + " 0%"; }
}

async function sendTelegram(token, chat_id, text, reply_markup = null, edit_id = null) {
    const url = `https://api.telegram.org/bot${token}/${edit_id ? 'editMessageText' : 'sendMessage'}`;
    const body = { chat_id, text, parse_mode: "HTML" };
    if (edit_id) body.message_id = edit_id;
    if (reply_markup) body.reply_markup = reply_markup;
    await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
}
