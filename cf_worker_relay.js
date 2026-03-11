/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.3.0 - D1 SQL Edition)
 * Uses Cloudflare D1 for high-frequency heartbeat and Watchdog alerts.
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
            } catch (e) {
                return new Response(e.message, { status: 200 });
            }
        }

        // Security check for VPS nodes
        const token = request.headers.get("X-Cluster-Token");
        if (token !== CLUSTER_TOKEN) {
            return new Response("Unauthorized", { status: 403 });
        }

        // 2. Node Heartbeat & Command Retrieval: POST /report?id=xxx
        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            // Update node status in D1
            await env.DB.prepare(`
                INSERT INTO nodes (id, cpu, mem_pct, v, t) 
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET 
                cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t
            `).bind(data.id, data.cpu, data.mem_pct, data.v, now).run();

            // Fetch latest pending command
            const cmd = await env.DB.prepare(`
                SELECT id, cmd, task_id FROM commands 
                WHERE target_id = ? AND status = 'pending'
                ORDER BY id DESC LIMIT 1
            `).bind(data.id).first();

            if (cmd) {
                await env.DB.prepare("UPDATE commands SET status = 'done' WHERE id = ?").bind(cmd.id).run();
                return new Response(JSON.stringify({ cmd: cmd.cmd, task_id: cmd.task_id }), { headers: { "Content-Type": "application/json" } });
            }

            return new Response(JSON.stringify({ ok: true }));
        }

        return new Response("AutoVPN D1 Master Online", { status: 200 });
    },

    // 3. Cron Watchdog: Automated Monitoring
    async scheduled(event, env) {
        const BOT_TOKEN = await env.DB.prepare("SELECT val FROM config WHERE key = 'BOT_TOKEN'").first("val");
        const CHAT_ID = await env.DB.prepare("SELECT val FROM config WHERE key = 'CHAT_ID'").first("val");
        if (!BOT_TOKEN || !CHAT_ID) return;

        const now = Math.floor(Date.now() / 1000);
        const deadNodes = await env.DB.prepare(`
            SELECT id FROM nodes 
            WHERE t < ? AND alert_sent = 0
        `).bind(now - 60).all();

        for (const node of deadNodes.results) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>节点失联报警</b>\n节点 <code>${node.id}</code> 已超过 60 秒未响应心跳，请检查服务器状态。`);
            await env.DB.prepare("UPDATE nodes SET alert_sent = 1 WHERE id = ?").bind(node.id).run();
        }

        // Reset alert_sent for back-to-life nodes
        await env.DB.prepare("UPDATE nodes SET alert_sent = 0 WHERE t >= ?").bind(now - 60).run();
    }
};

async function handleTelegramUpdate(update, env) {
    const BOT_TOKEN = await env.DB.prepare("SELECT val FROM config WHERE key = 'BOT_TOKEN'").first("val");
    const CHAT_ID = await env.DB.prepare("SELECT val FROM config WHERE key = 'CHAT_ID'").first("val");

    if (!update.message && !update.callback_query) return new Response("OK");

    const msg = update.message || update.callback_query.message;
    const chatId = msg.chat.id.toString();
    if (chatId !== CHAT_ID) return new Response("OK");

    const text = update.message ? update.message.text : null;
    const cbData = update.callback_query ? update.callback_query.data : null;

    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let res = "📊 <b>集群监控看板 (D1 Edition)</b>\n";
        const now = Math.floor(Date.now() / 1000);

        for (const s of nodes.results) {
            const status = (now - s.t) < 60 ? "🟢" : "🔘";
            res += `🆔 <code>${s.id}</code> [${status}]\n`;
            res += ` ├ CPU: ${genBar(s.cpu)}\n`;
            res += ` └ Mem: ${genBar(s.mem_pct)} (v${s.v})\n\n`;
        }

        const btns = { inline_keyboard: [[{ text: "🔄 刷新数据", callback_data: "show_status" }]] };
        await sendTelegram(BOT_TOKEN, chatId, res, btns, update.callback_query ? update.callback_query.message.message_id : null);
    }

    if (text === "/update") {
        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (D1 SQL)</b>\n请选择目标节点：", { inline_keyboard: btns });
    }

    if (cbData && cbData.startsWith("chk_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("UPDATE nodes SET is_selected = 1 - is_selected WHERE id = ?").bind(nodeId).run();

        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (D1 SQL)</b>\n请选择目标节点：", { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData === "bulk_up") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        if (selected.results.length === 0) return new Response("OK");

        for (const n of selected.results) {
            await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(n.id, "--update-bot", Date.now()).run();
        }
        await env.DB.prepare("UPDATE nodes SET is_selected = 0").run();
        await sendTelegram(BOT_TOKEN, chatId, `✅ <b>指令已下发</b>: 已向 ${selected.results.length} 个节点推送 D1 更新任务。`, null, update.callback_query.message.message_id);
    }

    return new Response("OK");
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
