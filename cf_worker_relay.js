/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.4.0 - Orchestration Edition)
 * Full management UI via D1 SQL command queuing and result feedback.
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

        // 2. Node Heartbeat & Command Retrieval: POST /report
        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            // Heartbeat
            await env.DB.prepare(`
                INSERT INTO nodes (id, cpu, mem_pct, v, t) 
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET 
                cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, alert_sent=0
            `).bind(data.id, data.cpu, data.mem_pct, data.v, now).run();

            // Handle result reporting if present
            if (data.task_id && data.result) {
                await env.DB.prepare("UPDATE commands SET result = ?, status = 'done', completed_at = ? WHERE task_id = ?")
                    .bind(data.result, now, data.task_id).run();

                // [v1.4.1] 状态感知通知
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    const isSuccess = data.result.includes("✅");
                    const title = isSuccess ? "✅ <b>任务执行成功</b>" : "❌ <b>任务执行失败</b>";
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `${title}\n节点: <code>${data.id}</code>\n回显详情:\n<pre>${data.result.substring(0, 1000)}</pre>`);
                }
            }

            // Fetch latest pending command
            const cmd = await env.DB.prepare(`
                SELECT cmd, task_id FROM commands 
                WHERE target_id = ? AND status = 'pending'
                ORDER BY id ASC LIMIT 1
            `).bind(data.id).first();

            if (cmd) {
                return new Response(JSON.stringify({ cmd: cmd.cmd, task_id: cmd.task_id }), { headers: { "Content-Type": "application/json" } });
            }

            return new Response(JSON.stringify({ ok: true }));
        }

        return new Response("AutoVPN Orchestrator Online", { status: 200 });
    },

    // 3. Watchdog
    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        if (!BOT_TOKEN || !CHAT_ID) return;

        const now = Math.floor(Date.now() / 1000);
        const deadNodes = await env.DB.prepare("SELECT id FROM nodes WHERE t < ? AND alert_sent = 0").bind(now - 60).all();

        for (const node of deadNodes.results) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>节点失联报警</b>\n节点 <code>${node.id}</code> 已超过 60 秒未响应，请检查！`);
            await env.DB.prepare("UPDATE nodes SET alert_sent = 1 WHERE id = ?").bind(node.id).run();
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

    // --- Dashboard & Status ---
    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let res = "📊 <b>集群监控项 (v1.4.0)</b>\n";
        const now = Math.floor(Date.now() / 1000);

        const btns = [];
        for (const s of nodes.results) {
            const status = (now - s.t) < 60 ? "🟢" : "🔘";
            res += `<b>${s.id}</b> [${status}]\n ├ CPU: ${genBar(s.cpu)}\n └ Mem: ${genBar(s.mem_pct)} (v${s.v})\n\n`;
            btns.push([{ text: `🛠️ 管理 ${s.id}`, callback_data: `mgr_${s.id}` }]);
        }
        btns.push([{ text: "🔄 刷新数据", callback_data: "show_status" }]);

        await sendTelegram(BOT_TOKEN, chatId, res, { inline_keyboard: btns }, update.callback_query ? update.callback_query.message.message_id : null);
    }

    // --- Node Selection Management ---
    if (cbData && cbData.startsWith("mgr_")) {
        const nodeId = cbData.split("_")[1];
        const btns = [
            [{ text: "📝 修改配置 (Port/UUID)", callback_data: `sub_cfg_${nodeId}` }],
            [{ text: "⚡ 服务控制 (重启/停启)", callback_data: `sub_svc_${nodeId}` }],
            [{ text: "⚙️ 系统管理 (BBR/Swap)", callback_data: `sub_sys_${nodeId}` }],
            [{ text: "🌐 网络管理 (WARP/Fwall)", callback_data: `sub_net_${nodeId}` }],
            [{ text: "🔍 诊断查询 (链接/日志)", callback_data: `sub_diag_${nodeId}` }],
            [{ text: "🔙 返回主列表", callback_data: "show_status" }]
        ];
        await sendTelegram(BOT_TOKEN, chatId, `🎮 <b>正在管理节点:</b> <code>${nodeId}</code>\n请选择操作大类：`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    // --- Sub-Menus ---
    if (cbData && cbData.startsWith("sub_")) {
        const parts = cbData.split("_");
        const type = parts[1];
        const nodeId = parts[2];
        let btns = [];
        let title = "";

        if (type === "cfg") {
            title = "🛠️ <b>配置修改</b>\n修改后由于需要重启 Xray，连接可能会闪断。";
            btns = [
                [{ text: "🔑 更换随机 UUID", callback_data: `run_${nodeId}_--uuid` }],
                [{ text: "🔙 返回管理菜单", callback_data: `mgr_${nodeId}` }]
            ];
        } else if (type === "svc") {
            title = "⚡ <b>服务控制</b>\n控制 Xray 和 Nginx 状态。";
            btns = [
                [{ text: "🔄 重启所有服务", callback_data: `run_${nodeId}_restart` }],
                [{ text: "🛑 停止所有服务", callback_data: `run_${nodeId}_stop` }],
                [{ text: "🔙 返回管理菜单", callback_data: `mgr_${nodeId}` }]
            ];
        } else if (type === "sys") {
            title = "⚙️ <b>系统管理</b>\n执行后需一定时间生效。";
            btns = [
                [{ text: "🚀 切换 BBR 加速", callback_data: `run_${nodeId}_--bbr` }],
                [{ text: "🔙 返回管理菜单", callback_data: `mgr_${nodeId}` }]
            ];
        } else if (type === "diag") {
            title = "🔍 <b>诊断与链接</b>";
            btns = [
                [{ text: "🔗 获取分享链接", callback_data: `run_${nodeId}_--link` }],
                [{ text: "📄 查看 Xray 日志", callback_data: `run_${nodeId}_--logs` }],
                [{ text: "🔙 返回管理菜单", callback_data: `mgr_${nodeId}` }]
            ];
        }

        await sendTelegram(BOT_TOKEN, chatId, title, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    // --- Command Dispatch ---
    if (cbData && cbData.startsWith("run_")) {
        const parts = cbData.split("_");
        const nodeId = parts[1];
        const cmd = parts[2];
        const taskId = Date.now();

        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(nodeId, cmd, taskId).run();

        await sendTelegram(BOT_TOKEN, chatId, `⏳ <b>指令已排队</b>: 已向 <code>${nodeId}</code> 下发指令 <code>${cmd}</code>，请稍后留意结果通知。`, null, update.callback_query.message.message_id);
    }

    if (text === "/update") {
        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (v1.4.0)</b>", { inline_keyboard: btns });
    }

    if (cbData && cbData.startsWith("chk_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("UPDATE nodes SET is_selected = 1 - is_selected WHERE id = ?").bind(nodeId).run();
        const nodes = await env.DB.prepare("SELECT id, v, is_selected FROM nodes").all();
        const btns = nodes.results.map(n => [{ text: `${n.is_selected ? '✅' : '☐'} ${n.id} (v${n.v})`, callback_data: `chk_${n.id}` }]);
        btns.push([{ text: "🚀 开始升级已选项", callback_data: "bulk_up" }]);
        await sendTelegram(BOT_TOKEN, chatId, "🗳️ <b>多节点勾选升级 (v1.4.0)</b>", { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData === "bulk_up") {
        const selected = await env.DB.prepare("SELECT id FROM nodes WHERE is_selected = 1").all();
        for (const n of selected.results) {
            await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(n.id, "--update-bot", Date.now()).run();
        }
        await env.DB.prepare("UPDATE nodes SET is_selected = 0").run();
        await sendTelegram(BOT_TOKEN, chatId, `✅ 已向 ${selected.results.length} 个节点推送升级任务。`, null, update.callback_query.message.message_id);
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
