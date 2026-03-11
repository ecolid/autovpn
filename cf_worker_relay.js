/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (Serverless Master v1.2.0)
 * Handles Telegram Webhooks and coordinates On-demand Sync across VPS nodes.
 */

const CLUSTER_TOKEN = "your_private_token_here"; // Will be replaced by install.sh

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        // 1. Handle Telegram Webhook (The Master Logic)
        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) {
                return new Response(e.message, { status: 500 });
            }
        }

        // Security check for VPS nodes
        const token = request.headers.get("X-Cluster-Token");
        if (token !== CLUSTER_TOKEN) {
            return new Response("Unauthorized", { status: 403 });
        }

        // 2. Node Heartbeat & Command Retrieval: GET/POST /report
        if (url.pathname === "/report") {
            const nodeId = url.searchParams.get("id") || (await request.json().then(d => d.id).catch(() => null));
            if (!nodeId) return new Response("Missing Node ID", { status: 400 });

            if (request.method === "POST") {
                const data = await request.json();
                // Store on-demand status
                await env.STATUS_KV.put(`status_${nodeId}`, JSON.stringify(data), { expirationTtl: 300 });
                return new Response(JSON.stringify({ ok: true }));
            }

            // check for commands
            const command = await env.STATUS_KV.get(`cmd_${nodeId}`);
            if (command) {
                await env.STATUS_KV.delete(`cmd_${nodeId}`);
                return new Response(command, { headers: { "Content-Type": "application/json" } });
            }

            // Check for global "Status Request"
            const statusReq = await env.STATUS_KV.get("status_request_active");
            if (statusReq) {
                return new Response(JSON.stringify({ cmd: "STATUS_REQ" }), { headers: { "Content-Type": "application/json" } });
            }

            return new Response(JSON.stringify({ ok: true }));
        }

        // 3. Command Dispatch (Used by Webhook or API)
        if (url.pathname === "/command" && request.method === "POST") {
            const { target_id, cmd, task_id } = await request.json();
            await env.STATUS_KV.put(`cmd_${target_id}`, JSON.stringify({ cmd, task_id }), { expirationTtl: 300 });
            return new Response("OK");
        }

        // 4. Global Status Query
        if (url.pathname === "/all_status") {
            const list = await env.STATUS_KV.list({ prefix: "status_" });
            const results = {};
            for (const key of list.keys) {
                const val = await env.STATUS_KV.get(key.name);
                results[key.name.replace("status_", "")] = JSON.parse(val);
            }
            return new Response(JSON.stringify(results));
        }

        return new Response("AutoVPN Serverless Master Online", { status: 200 });
    }
};

/**
 * Handle Telegram Webhook Events
 */
async function handleTelegramUpdate(update, env) {
    const BOT_TOKEN = await env.STATUS_KV.get("BOT_TOKEN");
    const CHAT_ID = await env.STATUS_KV.get("CHAT_ID");

    if (!update.message && !update.callback_query) return new Response("OK");

    const msg = update.message || update.callback_query.message;
    const chatId = msg.chat.id.toString();
    if (chatId !== CHAT_ID) return new Response("Unauthorized Chat", { status: 200 });

    const text = update.message ? update.message.text : null;
    const cbData = update.callback_query ? update.callback_query.data : null;

    // Handle Commands
    if (text === "/status" || cbData === "show_status") {
        const nodes = await getActiveNodes(env);
        let res = "📊 <b>集群实时看板 (Serverless)</b>\n";
        if (nodes.length === 0) {
            res += "\n⚠️ 目前没有在线节点报告。请确保节点已通过 <code>install.sh</code> 配置。";
        } else {
            for (const s of nodes) {
                const age = Math.floor((Date.now() / 1000) - (s.t || 0));
                const status = age < 60 ? "🟢" : "🔘";
                res += `🆔 <code>${s.id}</code> [${status}]\n`;
                res += ` ├ CPU: ${genBar(s.cpu)}\n`;
                res += ` └ Mem: ${genBar(s.mem_pct)} (v${s.v || '?'})\n\n`;
            }
        }
        res += `\n<i>最后更新: ${new Date().toLocaleTimeString('zh-CN', { timeZone: 'Asia/Shanghai' })}</i>`;

        const btns = { inline_keyboard: [[{ text: "🔄 刷新数据", callback_data: "show_status" }]] };

        // Trigger background sync for next refresh
        await env.STATUS_KV.put("status_request_active", "true", { expirationTtl: 20 });

        await sendTelegram(BOT_TOKEN, chatId, res, btns, update.callback_query ? update.callback_query.message.message_id : null);
        return new Response("OK");
    }

    if (text === "/logs") {
        const btns = {
            inline_keyboard: [
                [{ text: "🧵 Xray 日志", callback_data: "log_xray" }],
                [{ text: "💠 Nginx 日志", callback_data: "log_nginx" }]
            ]
        };
        await sendTelegram(BOT_TOKEN, chatId, "📂 <b>日志查询中心 (Serverless)</b>\n请选择查看项：", btns);
    }

    if (cbData && cbData.startsWith("log_")) {
        const logType = cbData.split("_")[1];
        // In Webhook mode, we broadcast a log request to all nodes or a specific one? 
        // For simplicity, let's assume we request from all for now or the first active one.
        await env.STATUS_KV.put("global_cmd", JSON.stringify({ cmd: `logs ${logType}`, t: Date.now() }), { expirationTtl: 60 });
        await sendTelegram(BOT_TOKEN, chatId, `🔍 已下发日志提取请求 (${logType.toUpperCase()})，请留意后续节点回传。`, null, update.callback_query.message.message_id);
    }

    if (text === "/update") {
        const nodes = await getActiveNodes(env);
        const btns = nodes.map(n => [{ text: `☐ ${n.id} (v${n.v || '?'})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (Serverless)</b>\n请勾选需要同步的节点：", { inline_keyboard: btns });
    }

    if (cbData && cbData.startsWith("chk_")) {
        const nodeId = cbData.split("_")[1];
        const msgId = update.callback_query.message.message_id;
        const key = `registry_${msgId}`;
        let selected = JSON.parse(await env.STATUS_KV.get(key) || "[]");

        if (selected.includes(nodeId)) selected = selected.filter(id => id !== nodeId);
        else selected.push(nodeId);

        await env.STATUS_KV.put(key, JSON.stringify(selected), { expirationTtl: 600 });

        const nodes = await getActiveNodes(env);
        const btns = nodes.map(n => [{ text: `${selected.includes(n.id) ? '✅' : '☐'} ${n.id} (v${n.v || '?'})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (Serverless)</b>\n请勾选需要同步的节点：", { inline_keyboard: btns }, msgId);
    }

    if (cbData === "bulk_up") {
        const msgId = update.callback_query.message.message_id;
        const key = `registry_${msgId}`;
        const selected = JSON.parse(await env.STATUS_KV.get(key) || "[]");

        if (selected.length === 0) return new Response("OK");

        for (const id of selected) {
            await env.STATUS_KV.put(`cmd_${id}`, JSON.stringify({ cmd: "--update-bot", task_id: Date.now() }), { expirationTtl: 300 });
        }
        await sendTelegram(BOT_TOKEN, chatId, `✅ <b>指令已分发</b>: 已向 ${selected.length} 个节点下发热更新指令。`, null, msgId);
    }

    return new Response("OK");
}

async function getActiveNodes(env) {
    const list = await env.STATUS_KV.list({ prefix: "status_" });
    const nodes = [];
    for (const key of list.keys) {
        const val = await env.STATUS_KV.get(key.name);
        nodes.push(JSON.parse(val));
    }
    return nodes;
}

async function sendTelegram(token, chat_id, text, reply_markup = null, edit_id = null) {
    const url = `https://api.telegram.org/bot${token}/${edit_id ? 'editMessageText' : 'sendMessage'}`;
    const body = { chat_id, text, parse_mode: "HTML" };
    if (edit_id) body.message_id = edit_id;
    if (reply_markup) body.reply_markup = reply_markup;

    await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    });
}

function genBar(pct, length = 10) {
    try {
        let p = parseFloat(pct);
        let filled = Math.round((p / 100) * length);
        if (filled > length) filled = length;
        if (filled < 0) filled = 0;
        return "█".repeat(filled) + "░".repeat(length - filled) + ` ${p.toFixed(1)}%`;
    } catch (e) {
        return "░".repeat(length) + " 0%";
    }
}
