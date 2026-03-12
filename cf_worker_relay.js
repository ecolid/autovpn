/**
 * Cloudflare Worker for AutoVPN Guardian Cluster (v1.7.0 - Final Sentinel Edition)
 * Orchestrates: Inter-node Rescue, Interactive Deployment Wizard, Bulk Updates.
 */

const CLUSTER_TOKEN = "your_private_token_here"; // Replaced by install.sh

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) { return new Response(e.message, { status: 200 }); }
        }

        const token = request.headers.get("X-Cluster-Token");
        if (token !== CLUSTER_TOKEN) return new Response("Unauthorized", { status: 403 });

        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            const node = await env.DB.prepare("SELECT state, is_selected FROM nodes WHERE id = ?").bind(data.id).first();
            if (node && node.state === 'offline') {
                await env.DB.prepare("UPDATE nodes SET state = 'online', alert_sent = 0 WHERE id = ?").bind(data.id).run();
                const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                const CHAT_ID = await getConfig(env, "CHAT_ID");
                if (BOT_TOKEN && CHAT_ID) await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ <b>节点重连通知</b>\n节点 <code>${data.id}</code> 已恢复连接。`);
            }

            const healthStr = JSON.stringify(data.h || {});
            const trafficStr = JSON.stringify(data.traff || { up: 0, down: 0 });
            const qualityStr = JSON.stringify(data.qual || {});
            const isSelected = node ? node.is_selected : 0;

            await env.DB.prepare(`
                INSERT INTO nodes (id, cpu, mem_pct, v, t, state, health, traffic_total, quality, ip, alert_sent, is_selected) 
                VALUES (?, ?, ?, ?, ?, 'online', ?, ?, ?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET 
                cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, state='online', health=EXCLUDED.health, 
                traffic_total=EXCLUDED.traffic_total, quality=EXCLUDED.quality, ip=EXCLUDED.ip, alert_sent=0
            `).bind(data.id, data.cpu, data.mem_pct, data.v, now, healthStr, trafficStr, qualityStr, data.ip || '0.0.0.0', isSelected).run();

            // 每 15 分钟存一个快照 (简单降频逻辑)
            if (now % 900 < 15) {
                await env.DB.prepare("INSERT INTO traffic_snapshots (node_id, up, down, t) VALUES (?, ?, ?, ?)")
                    .bind(data.id, data.traff?.up || 0, data.traff?.down || 0, now).run();
            }

            if (data.task_id && data.result) {
                await env.DB.prepare("UPDATE commands SET result = ?, status = 'done', completed_at = ? WHERE task_id = ? AND target_id = ?")
                    .bind(data.result, now, data.task_id, data.id).run();
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

    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        if (!BOT_TOKEN || !CHAT_ID) return;
        const now = Math.floor(Date.now() / 1000);
        const nodes = await env.DB.prepare("SELECT * FROM nodes WHERE state = 'online'").all();
        for (const node of nodes.results) {
            let reason = "", h = {};
            try { h = JSON.parse(node.health || "{}"); } catch (e) { }
            if (now - node.t > 30) reason = "📉 <b>节点彻底失联</b>";
            else if (h.xray === 'FAIL') reason = "🧨 <b>Xray 服务崩溃</b>";
            else if (h.net === 'FAIL') reason = "🌐 <b>网络出口阻断</b>";
            if (reason) {
                const btns = [[{ text: "🚑 尝试跨机救援", callback_data: `rescue_${node.id}` }]];
                await sendTelegram(BOT_TOKEN, CHAT_ID, `🚨 <b>故障警报</b>\n节点: <code>${node.id}</code>\n原因: ${reason}`, { inline_keyboard: btns });
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

    // 1. Status Board
    if (text === "/status" || cbData === "show_status") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let selectedCount = 0;
        let res = "📊 <b>集群实时看板 (v1.7.0)</b>\n";
        const btns = [];
        for (const s of nodes.results) {
            const st = s.state === 'online' ? "🟢" : "🔴";
            const sel = s.is_selected ? " [✅ 已选]" : "";
            if (s.is_selected) selectedCount++;

            res += `<b>${s.id}</b> [${st}]${sel}\n`;
            res += `├ IP: <code>${s.ip}</code> | v${s.v}\n`;
            res += `└ 负荷: ${genBar(s.cpu)}\n\n`;

            btns.push([
                { text: `${s.is_selected ? '❌ 取消勾选' : '✔️ 勾选升级'}`, callback_data: `chk_${s.id}` },
                { text: `🛠️ 管理`, callback_data: `mgr_${s.id}` }
            ]);
        }

        let bottomBtns = [{ text: "🔄 刷新数据", callback_data: "show_status" }];
        if (selectedCount > 0) {
            res += `\n📦 <b>当前已勾选 <code>${selectedCount}</code> 台设备</b>`;
            bottomBtns.unshift({ text: `🚀 批量升级 (${selectedCount})`, callback_data: "bulk_up" });
        }
        btns.push(bottomBtns);
        await sendTelegram(BOT_TOKEN, CHAT_ID, res, { inline_keyboard: btns }, update.callback_query?.message.message_id);
    }

    // 2. Data Stats Board (v1.8.0)
    if (text === "/stats" || cbData === "show_stats") {
        const nodes = await env.DB.prepare("SELECT * FROM nodes ORDER BY t DESC").all();
        let report = "📊 <b>AutoVPN 数据罗盘 (v1.8.0)</b>\n\n";

        for (const s of nodes.results) {
            let t = { up: 0, down: 0 }, q = { china: { lat: 0, jit: 0, loss: 0 } };
            try { t = JSON.parse(s.traffic_total || "{}"); } catch (e) { }
            try { q = JSON.parse(s.quality || "{}"); } catch (e) { }

            const upGB = (t.up / (1024 ** 3)).toFixed(2);
            const downGB = (t.down / (1024 ** 3)).toFixed(2);
            const lossIcon = q.china?.loss > 5 ? "⚠️" : "✅";

            report += `🖥 <b>${s.id}</b>\n`;
            report += `├ 流量: 🔼 ${upGB}GB | 🔽 ${downGB}GB\n`;
            report += `└ 线路: 📶 ${q.china?.lat || 0}ms | ⏳ ${q.china?.jit || 0}ms | ${lossIcon} ${q.china?.loss || 0}%\n\n`;
        }

        const btns = [[{ text: "🔄 刷新统计", callback_data: "show_stats" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, report, { inline_keyboard: btns }, update.callback_query?.message.message_id);
    }

    // 3. Rescue logic
    if (cbData?.startsWith("rescue_")) {
        const pid = cbData.split("_")[1];
        const p = await env.DB.prepare("SELECT ip FROM nodes WHERE id = ?").bind(pid).first();
        const d = await env.DB.prepare("SELECT id FROM nodes WHERE state = 'online' AND id != ? AND health LIKE '%\"net\":\"OK\"%' ORDER BY t DESC LIMIT 1").bind(pid).first();
        if (!p?.ip || !d) return await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 无法救援: 条件不足");
        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(d.id, `rescue_${p.ip}`, Date.now()).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🚑 <b>紧急救援已发派</b>\n病人: ${pid}\n医生: ${d.id}`);
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

    if (cbData?.startsWith("mgr_")) {
        const nodeId = cbData.split("_")[1];
        const btns = [[{ text: "⚡ 服务控制", callback_data: `sub_svc_${nodeId}` }], [{ text: "🔍 诊断查询", callback_data: `sub_diag_${nodeId}` }], [{ text: "🔙 返回", callback_data: "show_status" }]];
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🎮 <b>管理:</b> <code>${nodeId}</code>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
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

async function getConfig(env, key) { return await env.DB.prepare("SELECT val FROM config WHERE key = ?").bind(key).first("val"); }
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
