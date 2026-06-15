#!/bin/bash
# 修复 x-ui 面板：只监听 127.0.0.1

echo "=== 1. 停止 x-ui 服务:"
systemctl stop x-ui 2>/dev/null
sleep 3
echo ""

echo "=== 2. 修改面板监听 IP 为 127.0.0.1:"
cd /usr/local/x-ui
./x-ui setting -ip 127.0.0.1 2>&1
echo ""

echo "=== 3. 修改订阅服务也只监听 127.0.0.1:"
# x-ui 的 sub port 也是公网监听的
./x-ui setting -subhost 127.0.0.1 2>&1
echo ""

echo "=== 4. 启动 x-ui 服务:"
systemctl start x-ui 2>/dev/null
sleep 3
echo ""

echo "=== 5. 验证监听情况:"
ss -tlnp 2>/dev/null | grep -E "x-ui|54321|2096"
echo ""

echo "完成"
echo ""
echo "⚠️  注意：如果面板只监听 127.0.0.1，需要通过 SSH 隧道访问:"
echo "     ssh -L 54321:127.0.0.1:54321 root@43.133.1.16"
echo "     然后浏览器打开 http://127.0.0.1:54321"
