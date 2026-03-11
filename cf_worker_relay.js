/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.7.0 - Sentinel Rescue)
 * Dual-layer security: Forced Commands + Just-in-time IP delivery.
 */

const CLUSTER_TOKEN = "your_private_token_here"; // Replaced by install.sh

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        // 1. Telegram Webhook
        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) { return new Response(e.message, { status: 200 }); }
        }

        const token = request.headers.get("X-Cluster-Token");
        if (token !== CLUSTER_TOKEN) return new Response("Unauthorized", { status: 403 });

        // 2. Node Heartbeat & Diagnosis: POST /report
        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            // State Transition Detection (Offline -> Online)
            const node = await env.DB.prepare("SELECT state FROM nodes WHERE id = ?").bind(data.id).first();
            if (node && node.state === 'offline') {
                await env.DB.prepare("UPDATE nodes SET state = 'online', alert_sent = 0 WHERE id = ?").bind(data.id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ <b>节点重连通知</b>\n节点 <code>${data.id}</code> 已恢复连接。`);
                }
            }

            // [v1.7.0] IP Tracking in Heartbeat
            const healthStr = JSON.stringify(data.h || {});
            await env.DB.prepare(`
                INSERT INTO nodes (id, ip, cpu, mem_pct, v, t, state, health, alert_sent) 
                VALUES (?, ?, ?, ?, ?, ?, 'online', ?, 0)
                ON CONFLICT(id) DO UPDATE SET 
                ip=EXCLUDED.ip, cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, state='online', health=EXCLUDED.health, alert_sent=0
            `).bind(data.id, data.ip || 'unknown', data.cpu, data.mem_pct, data.v, now, healthStr).run();

            // Handle result reporting
            if (data.task_id && data.result) {
                await env.DB.prepare("UPDATE commands SET result = ?, status = 'done', completed_at = ? WHERE task_id = ?").bind(data.result, now, data.task_id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) {
                    const isSuccess = data.result.includes("✅");
                    const title = isSuccess ? "✅ <b>任务执行成功</b>" : "❌ <b>任务执行失败</b>";
                    await sendTelegram(BOT_TOKEN, CHAT_ID, `${title}\n节点: <code>${data.id}</code>\n回显详情:\n<pre>${data.result.substring(0, 500)}</pre>`);
                }
            }

            const cmd = await env.DB.prepare("SELECT cmd, task_id FROM commands WHERE target_id = ? AND status = 'pending' ORDER BY id ASC LIMIT 1").bind(data.id).first();
            if (cmd) return new Response(JSON.stringify({ cmd: cmd.cmd, task_id: cmd.task_id }), { headers: { "Content-Type": "application/json" } });

            return new Response(JSON.stringify({ ok: true }));
        }
        return new Response("AutoVPN Orchestrator v1.7.0 Online", { status: 200 });
    },

    // 3. Watchdog
    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        if (!BOT_TOKEN || !CHAT_ID) return;

        const now = Math.floor(Date.now() / 1000);
        const activeNodes = await env.DB.prepare("SELECT * FROM nodes WHERE state = 'online'").all();

        for (const node of activeNodes.results) {
            let reason = "";
            let h = {}; try { h = JSON.parse(node.health || "{}"); } catch (e) { }

            if (now - node.t > 30) reason = "📉 <b>节点彻底失联</b>";
            else if (h.xray === 'FAIL') reason = "🧨 <b>Xray 服务崩溃</b>";
            else if (h.nginx === 'FAIL') reason = "🕸️ <b>Nginx 服务崩溃</b>";

            if (reason) {
                const btns = [[{ text: "🚑 尝试集群自愈 (SSH Rescue)", callback_data: `rescue_${node.id}` }]];
                await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>故障警报 (RCA)</b>\n节点: <code>${node.id}</code>\n原因: ${reason}`, { inline_keyboard: btns });
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

    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let res = "📊 <b>集群实时看板 (v1.7.0)</b>\n";
        const btns = [];
        for (const s of nodes.results) {
            let h = {}; try { h = JSON.parse(s.health || "{}"); } catch (e) { }
            const st = s.state === 'online' ? "🟢" : "🔴";
            const xi = h.xray === 'OK' ? "✅" : "❌";
            const ni = h.nginx === 'OK' ? "✅" : "❌";
            res += `<b>${s.id}</b> [${st}] (IP: ${s.ip})\n ├ X[${xi}] N[${ni}] | ${genBar(s.cpu)}\n\n`;
            btns.push([{ text: `🛠️ 管理 ${s.id}`, callback_data: `mgr_${s.id}` }]);
        }
        btns.push([{ text: "🔄 刷新", callback_data: "show_status" }]);
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns }, update.callback_query?.message_id);
    }

    // [v1.7.0] 救援中继逻辑
    if (cbData && cbData.startsWith("rescue_")) {
        const patientId = cbData.split("_")[1];
        const patient = await env.DB.prepare("SELECT ip FROM nodes WHERE id = ?").bind(patientId).first();
        const doctor = await env.DB.prepare("SELECT id FROM nodes WHERE state = 'online' AND id != ? LIMIT 1").bind(patientId).first();

        if (!doctor) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, "⚠️ <b>自愈失败</b>: 集群内没有其他在线节点可以执行救援任务。");
            return new Response("OK");
        }

        const rescueCmd = `ssh -i /usr/local/etc/autovpn/cluster_key -o StrictHostKeyChecking=no root@${patient.ip} \"--restart-only\"`;
        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(doctor.id, rescueCmd, Date.now()).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🚑 <b>自愈任务已发动</b>\n已派遣 <code>${doctor.id}</code> 前往修复 <code>${patientId}</code> (${patient.ip})。\n请留意后续心跳恢复通知。`);
    }

    if (cbData && cbData.startsWith("mgr_")) {
        const nodeId = cbData.split("_")[1];
        const btns = [[{ text: "📝 配置", callback_data: `sub_cfg_${nodeId}` }], [{ text: "⚡ 服务", callback_data: `sub_svc_${nodeId}` }], [{ text: "🔙 返回", callback_data: "show_status" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🎮 <b>管理节点:</b> <code>${nodeId}</code>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData && cbData.startsWith("sub_")) {
        const parts = cbData.split("_");
        let btns = [[{ text: "🔙 返回", callback_data: `mgr_${parts[2]}` }]];
        if (parts[1] === "cfg") btns.unshift([{ text: "🔑 更换 UUID", callback_data: `run_${parts[2]}_--uuid` }]);
        else if (parts[1] === "svc") btns.unshift([{ text: "🔄 重启服务", callback_data: `run_${parts[2]}_restart` }]);
        await sendTelegram(BOT_TOKEN, CHAT_ID, `📂 <b>子工具箱 - ${parts[1].toUpperCase()}</b>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData && cbData.startsWith("run_")) {
        const parts = cbData.split("_");
        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(parts[1], parts[2], Date.now()).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `⏳ 指令已下发`, null, update.callback_query.message.message_id);
    }

    return new Response("OK");
}

async function getConfig(env, key) { return await env.DB.prepare("SELECT val FROM config WHERE key = ?").bind(key).first("val"); }
function genBar(pct, length = 8) { let p = parseFloat(pct); let filled = Math.round((p / 100) * length); return "█".repeat(filled) + "░".repeat(length - filled) + ` ${p.toFixed(0)}%`; }
async function sendTelegram(token, chat_id, text, reply_markup = null, edit_id = null) {
    const url = `https://api.telegram.org/bot${token}/${edit_id ? 'editMessageText' : 'sendMessage'}`;
    const body = { chat_id, text, parse_mode: "HTML" };
    if (edit_id) body.message_id = edit_id;
    if (reply_markup) body.reply_markup = reply_markup;
    await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
}
