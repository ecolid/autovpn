/**
 * Cloudflare Worker for AutoVPN Guardian Cluster
 * Acts as an asynchronous message bus between Telegram and VPS nodes.
 * 部署说明：
 * 1. 在 CF Workers 后台创建一个新 Worker。
 * 2. 将此脚本粘贴进去。
 * 3. 在设置中添加一个名为 "STATUS_KV" 的 KV 命名空间绑定。
 * 4. 修改下方的 CLUSTER_TOKEN 为你的私有密钥。
 */

const CLUSTER_TOKEN = "your_private_token_here";

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const token = request.headers.get("X-Cluster-Token");

        if (token !== CLUSTER_TOKEN) {
            return new Response("Unauthorized", { status: 403 });
        }

        // 1. 节点上报状态: POST /report
        if (url.pathname === "/report") {
            if (request.method === "POST") {
                const data = await request.json();
                const nodeId = data.id;
                // 存储节点动态状态，有效期 60s
                await env.STATUS_KV.put(`status_${nodeId}`, JSON.stringify(data), { expirationTtl: 60 });

                // 检查该节点是否有待执行指令
                const command = await env.STATUS_KV.get(`cmd_${nodeId}`);
                if (command) {
                    await env.STATUS_KV.delete(`cmd_${nodeId}`);
                    return new Response(command, { headers: { "Content-Type": "application/json" } });
                }
                return new Response(JSON.stringify({ ok: true }), { status: 200 });
            }

            // 节点获取状态指令也可以通过 GET /report
            if (request.method === "GET") {
                const nodeId = url.searchParams.get("id");
                const command = await env.STATUS_KV.get(`cmd_${nodeId}`);
                if (command) {
                    await env.STATUS_KV.delete(`cmd_${nodeId}`);
                    return new Response(command, { headers: { "Content-Type": "application/json" } });
                }
                return new Response(JSON.stringify({ ok: true }), { status: 200 });
            }
        }

        // 2. 指令下发: POST /command
        if (url.pathname === "/command" && request.method === "POST") {
            const { target_id, cmd, task_id } = await request.json();
            await env.STATUS_KV.put(`cmd_${target_id}`, JSON.stringify({ cmd, task_id }), { expirationTtl: 300 });
            return new Response("Command Queued", { status: 200 });
        }

        // 3. 结果回传: POST /result
        if (url.pathname === "/result" && request.method === "POST") {
            const { task_id, result } = await request.json();
            await env.STATUS_KV.put(`res_${task_id}`, result, { expirationTtl: 600 });
            return new Response("Result Saved", { status: 200 });
        }

        // 4. 全局状态查询: GET /all_status
        if (url.pathname === "/all_status") {
            const list = await env.STATUS_KV.list({ prefix: "status_" });
            const results = {};
            for (const key of list.keys) {
                const val = await env.STATUS_KV.get(key.name);
                results[key.name.replace("status_", "")] = JSON.parse(val);
            }
            return new Response(JSON.stringify(results), { status: 200 });
        }

        return new Response("AutoVPN Cluster Relay Online", { status: 200 });
    }
};
