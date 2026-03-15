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
const VERSION = "v1.18.55";
const PAIR_CODE_EXPIRE = 300; // 配对码有效期 5 分钟

function generatePairCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let code = '';
    for (let i = 0; i < 6; i++) {
        code += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return code;
}

export default {
    async fetch(request, env) {
        // 初始化配对码表
        await env.DB.prepare(`
            CREATE TABLE IF NOT EXISTS pair_codes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT UNIQUE NOT NULL,
                cluster_token TEXT NOT NULL,
                expire_at INTEGER NOT NULL
            )
        `).run();
        
        const url = new URL(request.url);

        if (request.method === "POST" && url.pathname === "/webhook") {
            try {
                const update = await request.json();
                return await handleTelegramUpdate(update, env);
            } catch (e) { return new Response(e.message, { status: 200 }); }
        }

        // 配对码接口（无需认证，配对码本身就是凭证）
        if (url.pathname === "/pair" && request.method === "POST") {

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
            const body = await request.json();
            const { code, action } = body;
            
            if (action === "create") {
                // 生成配对码（需要认证）
                const token = request.headers.get("X-Cluster-Token");
                const dbToken = await getConfig(env, "CLUSTER_TOKEN");
                if (token !== CLUSTER_TOKEN && token !== dbToken) return new Response("Unauthorized", { status: 403 });
                
                // 生成加密配对码（包含 URL + Token + 过期时间）
                const cfWorkerUrl = await getConfig(env, "CF_WORKER_URL");
                const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
                const data = {
                    url: cfWorkerUrl,
                    token: clusterToken,
                    expire: Date.now() + 300000 // 5 分钟
                };
                const pairCode = encrypt(data, CLUSTER_TOKEN);
                
                return new Response(JSON.stringify({ 
                    success: true, 
                    code: pairCode,
                    expire: 300
                }));
            }
            
            if (action === "verify") {
                // 验证配对码（无需认证）
                const data = decrypt(code, CLUSTER_TOKEN);
                
                if (!data) {
                    return new Response(JSON.stringify({ success: false, error: "配对码无效或已损坏" }));
                }
                
                const now = Date.now();
                if (now > data.expire) {
                    return new Response(JSON.stringify({ success: false, error: "配对码已过期，请重新生成" }));
                }
                
                // 新节点注册：生成节点 ID 并写入 D1
                const nodeId = `node_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
                await env.DB.prepare(`
                    INSERT INTO nodes (id, state, alert_sent, is_selected, t) 
                    VALUES (?, 'online', 0, 1, ?)
                `).bind(nodeId, Math.floor(Date.now() / 1000)).run();
                
                // [v1.18.48] 配对成功时不通知，等节点第一次汇报时再通知（避免重复）
                // 通知 Bot（如果配置了）
                // try {
                //     const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
                //     const CHAT_ID = await getConfig(env, "CHAT_ID");
                //     if (BOT_TOKEN && CHAT_ID) {
                //         await sendTelegram(BOT_TOKEN, CHAT_ID, 
                //             `🎉 <b>新节点加入集群!</b>\n节点 ID: <code>${nodeId}</code>\n已自动上线并开始汇报`);
                //     }
                // } catch (e) {
                //     // Bot 通知失败不影响注册
                // }
                
                // 返回集群配置给子节点
                return new Response(JSON.stringify({ 
                    success: true, 
                    node_id: nodeId,
                    cf_worker_url: (data.url || "").replace(/[`'\s]/g, "").trim(),  // 二次清理，确保万无一失
                    cluster_token: data.token,
                    message: "✅ 注册成功！你已加入集群，请开始汇报状态"
                }));
            }
            
            return new Response(JSON.stringify({ error: "未知操作" }));
        }

        const token = request.headers.get("X-Cluster-Token");
        const dbToken = await getConfig(env, "CLUSTER_TOKEN");
        if (token !== CLUSTER_TOKEN && token !== dbToken) return new Response("Unauthorized", { status: 403 });

        // SSH 公钥接口（配对模式专用，无需认证）
        if (url.pathname === "/ssh-keys" && request.method === "GET") {
            const token = request.headers.get("X-Cluster-Token");
            const dbToken = await getConfig(env, "CLUSTER_TOKEN");
            if (token !== CLUSTER_TOKEN && token !== dbToken) return new Response("Unauthorized", { status: 403 });
            
            // 从 D1 获取 SSH 公钥
            const keys = await env.DB.prepare("SELECT key, val FROM config WHERE key IN ('SSH_PUB', 'SSH_OWNER_PUB')").all();
            const ssh_pub = keys.find(k => k.key === 'SSH_PUB')?.val || '';
            const owner_pub = keys.find(k => k.key === 'SSH_OWNER_PUB')?.val || '';
            
            return new Response(JSON.stringify({ ssh_pub, owner_pub }));
        }

        if (url.pathname === "/report" && request.method === "POST") {
            const data = await request.json();
            const now = Math.floor(Date.now() / 1000);

            const node = await env.DB.prepare("SELECT state, is_selected FROM nodes WHERE id = ?").bind(data.id).first();
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

            await env.DB.prepare(`
                INSERT INTO nodes (id, hostname, cpu, mem_pct, v, t, state, health, traffic_total, quality, ip, alert_sent, is_selected) 
                VALUES (?, ?, ?, ?, ?, ?, 'online', ?, ?, ?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET 
                hostname=COALESCE(EXCLUDED.hostname, nodes.hostname),
                cpu=EXCLUDED.cpu, mem_pct=EXCLUDED.mem_pct, v=EXCLUDED.v, t=EXCLUDED.t, state='online', health=EXCLUDED.health, 
                traffic_total=EXCLUDED.traffic_total, quality=EXCLUDED.quality, 
                ip=CASE WHEN EXCLUDED.ip IS NOT NULL AND EXCLUDED.ip != '' THEN EXCLUDED.ip ELSE nodes.ip END,
                alert_sent=0
            `).bind(data.id, data.hostname, data.cpu, data.mem_pct, data.v, now, healthStr, trafficStr, qualityStr, nodeIp, isSelected).run();

            // 每小时整点存一个持久快照 (Analytics)
            if (now % 3600 < 15) {
                await env.DB.prepare("INSERT INTO traffic_snapshots (node_id, up, down, t, type) VALUES (?, ?, ?, ?, 'hourly')")
                    .bind(data.id, data.traff?.up || 0, data.traff?.down || 0, now).run();
                // 清理超过 24 小时的快照
                await env.DB.prepare("DELETE FROM traffic_snapshots WHERE t < ?").bind(now - 86400).run();
            }

            if (data.task_id && data.result) {
                // [v1.13.0] JIT 秘钥分发逻辑
                if (data.result.startsWith("JIT_PUB:")) {
                    const jitPub = data.result.split("JIT_PUB:")[1];
                    const originalTask = await env.DB.prepare("SELECT target_id FROM commands WHERE task_id = ?").bind(data.task_id).first();
                    if (originalTask) {
                        // 向病人节点派发挂载任务
                        const patientId = originalTask.target_id;
                        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id, status) VALUES (?, ?, ?, 'pending')")
                            .bind(patientId, `JIT_MOUNT:${jitPub}`, data.task_id + 1, 'pending').run();
                    }
                    return new Response(JSON.stringify({ ok: true }));
                }

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
                // [v1.14.0] 如果是 SSH 类任务，注入云端私钥
                if (cmd.cmd.startsWith("rescue_") || cmd.cmd.startsWith("ssh ")) {
                    payload.ssh_key = await getConfig(env, "SSH_PRV");
                }
                return new Response(JSON.stringify(payload), { headers: { "Content-Type": "application/json" } });
            }

            return new Response(JSON.stringify({ ok: true }));
        }
        return new Response(`AutoVPN Orchestrator v${VERSION} Online`, { status: 200 });
    },

    async scheduled(event, env) {
        const BOT_TOKEN = await getConfig(env, "BOT_TOKEN");
        const CHAT_ID = await getConfig(env, "CHAT_ID");
        
        // 初始化配对码表
        await env.DB.prepare(`
            CREATE TABLE IF NOT EXISTS pair_codes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT UNIQUE NOT NULL,
                cluster_token TEXT NOT NULL,
                expire_at INTEGER NOT NULL
            )
        `).run();
        
        // 清理过期配对码
        await env.DB.prepare("DELETE FROM pair_codes WHERE expire_at < ?").bind(Date.now()).run();
        
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
                const btns = [[{ text: "🚑 尝试互救", callback_data: `rescue_${node.id}` }]];
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

    if (text === "/start" || text === "/menu" || cbData === "show_main") {
        const welcome = `🏰 <b>AutoVPN 守护者集群控制台 (v${VERSION})</b>\n\n请选择操作模块:`;
        const btns = [
            [{ text: "📊 节点看板 (全维度)", callback_data: "show_status" }],
            [{ text: "🚑 救援日志", callback_data: "show_rescue" }, { text: "📡 路由管理", callback_data: "show_routing" }],
            [{ text: "☁️ 云端同步", callback_data: "show_update" }, { text: "🛡️ 安全中心", callback_data: "show_security" }],
            [{ text: "⚙️ 向导说明", url: "https://github.com/ecolid/autovpn" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, welcome, { inline_keyboard: btns }, update.callback_query?.message.message_id);
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
            try { h = JSON.parse(s.health || "{}"); } catch (e) { }
            try { q = JSON.parse(s.quality || "{}"); } catch (e) { }
            try { t = JSON.parse(s.traffic_total || "{}"); } catch (e) { }

            const upGB = (t.up / (1024 ** 3)).toFixed(2);
            const downGB = (t.down / (1024 ** 3)).toFixed(2);
            const x = h.xray === "OK" ? "🟢" : "🔴";
            const n = h.nginx === "OK" ? "🟢" : "🔴";
            const w = (h.warp === "OFF" || h.warp === "SKIP") ? "⚪" : (h.warp === "OK" ? "🟢" : "🔴");
            const l = h.loop === "OK" ? "🟢" : "🔴";
            const qStr = `🇨🇳${q.china?.lat || "--"}ms | 🌐${q.global?.lat || "--"}ms`;

            res += `🌩️ <b>${s.hostname || s.id}</b> [${st}] ${sel}\n`;
            res += `├ IP: <code>${s.ip}</code> | v${s.v}\n`;
            res += `├ 指标: X:${x} N:${n} W:${w} L:${l} | ${qStr}\n`;
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

    // 3. Security Command Center (v1.14.3 - Stateless Security)
    if (text === "/ssh" || cbData === "show_security") {
        const pub = await getConfig(env, "SSH_PUB");
        const prv = await getConfig(env, "SSH_PRV");
        const owner = await getConfig(env, "SSH_OWNER_PUB");
        let info = `🛡️ <b>集群安全指挥中心 (v${VERSION})</b>\n\n`;

        info += "👤 <b>老板 DNA (Owner Key):</b>\n";
        info += owner ? `<code>${owner.substring(0, 32)}...</code>\n` : "<i>(尚未提取)</i>\n";
        info += "� <b>机器人母钥 (Cluster Pub):</b>\n";
        info += pub ? `<code>${pub.substring(0, 32)}...</code>\n` : "<i>(尚未生成)</i>\n\n";

        info += "🏦 <b>安全存储状态:</b>\n";
        info += prv ? "✅ 🔒 <b>云端保险箱 (Stateless Mode)</b>\n" : "⚠️ 🔌 <b>本地存储 (Legacy Mode)</b>\n";
        info += "💡 <i>状态：v1.14.0 后私钥不再驻留 VPS 硬盘。</i>\n\n";

        info += "⚙️ <b>指挥部维养 (Internal):</b>\n";
        info += "💡 <i>功能：无需 VPS 中放，在此一键静默升级机器人。</i>\n\n";

        info += "⚠️ <b>注意：</b> 若怀疑泄漏，请立即执行彻底轮换。";

        const btns = [
            [{ text: "🔄 升级指挥部 (Self-Update)", callback_data: "self_update_worker" }],
            [{ text: "🔗 生成配对码", callback_data: "generate_pair" }],
            [{ text: "🔄 轮换 SSH 密钥", callback_data: "rotate_ssh" }],
            [{ text: "🔙 返回主菜单", callback_data: "show_main" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns }, update.callback_query?.message.message_id);
        return new Response("OK");
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
                    [{ text: "🔙 返回", callback_data: "show_security" }]
                ];
                await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
                return new Response("OK");
            }
            
            // 5. 有新版本，执行更新
            await sendTelegram(BOT_TOKEN, CHAT_ID, `🔄 <b>指挥部进化启动</b>\n发现新版本：v${githubVersion}\n当前版本：v${currentVersion}\n\n正在从 GitHub 拉取代码...`);
            
            // 保持版本兼容性：注入当前的 CLUSTER_TOKEN
            const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
            code = code.replace(/const CLUSTER_TOKEN = ".*";/, `const CLUSTER_TOKEN = "${clusterToken}";`);

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
                const info = `✅ <b>指挥部进化成功!</b>\n\n旧版本：v${currentVersion}\n新版本：v${githubVersion}\n\n脚本已同步至云端，模块已重载。`;
                const btns = [[{ text: "🔙 返回", callback_data: "show_security" }]];
                await sendTelegram(BOT_TOKEN, CHAT_ID, info, { inline_keyboard: btns });
            } else {
                await sendTelegram(BOT_TOKEN, CHAT_ID, `❌ <b>进化失败: CF API 拒绝</b>\n<pre>${JSON.stringify(cfData.errors)}</pre>`);
            }
        } catch (e) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `❌ <b>进化失败: 致命错误</b>\n${e.message}`);
        }
        return new Response("OK");
    }

    if (cbData === "rotate_ssh") {
        const doc = await env.DB.prepare("SELECT id FROM nodes WHERE state = 'online' ORDER BY t DESC LIMIT 1").first();
        if (!doc) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, "❌ 错误: 无在线医生节点可执行轮换");
            return new Response("OK");
        }
        await env.DB.prepare("INSERT INTO commands (target_id, cmd, task_id) VALUES (?, ?, ?)").bind(doc.id, "--rotate-keys", Date.now()).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🔀 <b>密钥轮换任务已发派</b>\n执行官员: ${doc.id}\n正在进行"三步走"无缝切换...`);
        return new Response("OK");
    }

    if (cbData === "generate_pair") {
        try {
            let cfWorkerUrl = await getConfig(env, "CF_WORKER_URL");
            // [v1.18.52] 二次清理，确保配对码里的 URL 干净
            cfWorkerUrl = (cfWorkerUrl || "").replace(/[`'\s]/g, "").trim();
            const clusterToken = await getConfig(env, "CLUSTER_TOKEN") || CLUSTER_TOKEN;
            
            // 生成加密配对码（包含 URL + Token + 过期时间）
            const data = {
                url: cfWorkerUrl,
                token: clusterToken,
                expire: Date.now() + 300000 // 5 分钟
            };
            const code = encrypt(data, CLUSTER_TOKEN);
            
            const joinInfo = `🔗 <b>配对码已生成!</b>

配对码 (5 分钟有效):
<pre>${code}</pre>

📋 <b>使用方式:</b>

在新 VPS 执行:
<code>autovpn</code>
选择 8 - 2
粘贴上方配对码即可`;
            await sendTelegram(BOT_TOKEN, CHAT_ID, joinInfo);
        } catch (e) {
            await sendTelegram(BOT_TOKEN, CHAT_ID, `❌ 生成失败：${e.message}`);
        }
        return new Response("OK");
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
        const btns = [
            [{ text: "⚡ 服务控制", callback_data: `sub_svc_${nodeId}` }],
            [{ text: "🔍 诊断查询", callback_data: `sub_diag_${nodeId}` }],
            [{ text: "�️ 删除节点", callback_data: `delnode_${nodeId}` }],
            [{ text: "�� 返回", callback_data: "show_status" }]
        ];
        await sendTelegram(BOT_TOKEN, CHAT_ID, `🎮 <b>管理:</b> <code>${nodeId}</code>`, { inline_keyboard: btns }, update.callback_query.message.message_id);
    }

    if (cbData?.startsWith("delnode_")) {
        const nodeId = cbData.split("_")[1];
        await env.DB.prepare("DELETE FROM nodes WHERE id = ?").bind(nodeId).run();
        await sendTelegram(BOT_TOKEN, CHAT_ID, `✅ 节点 <code>${nodeId}</code> 已从集群中删除。`);
        return await handleTelegramUpdate({ callback_query: { data: "show_status", message: msg } }, env);
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
    // 自动清理 URL 中的反引号、引号和空白字符
    if (typeof val === 'string' && (key.includes('URL') || key.includes('DOMAIN'))) {
        return val.replace(/[`'\s]/g, "").trim();
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
