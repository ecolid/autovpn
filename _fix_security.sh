#!/bin/bash
set -e

echo "=== 1. 删除入侵者公钥 gary@gary ==="
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak.$(date +%s)
grep -v "gary@gary" ~/.ssh/authorized_keys.bak.* > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "已删除 gary@gary 的公钥"
echo ""

echo "=== 2. 剩余 authorized_keys 内容 ==="
cat ~/.ssh/authorized_keys
echo ""

echo "=== 3. 搜索所有 authorized_keys 文件 ==="
find / -name "authorized_keys*" 2>/dev/null | grep -v "proc\|sys" | head -20
echo ""

echo "=== 4. 搜索 gary 相关的文件 ==="
grep -rl "gary@gary\|gary@\|IMMDxNliLAR1lLp5kox" /root /etc /home 2>/dev/null | head -20
echo ""

echo "=== 5. 修改 SSH 配置 - 禁用密码登录 ==="
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
echo "PasswordAuthentication: $(grep ^PasswordAuthentication /etc/ssh/sshd_config)"
echo "PermitRootLogin: $(grep ^PermitRootLogin /etc/ssh/sshd_config)"
echo ""

echo "=== 6. 检查 /etc/ssh/sshd_config.d/ ==="
ls -la /etc/ssh/sshd_config.d/ 2>/dev/null || echo "(空目录)"
for f in /etc/ssh/sshd_config.d/*.conf 2>/dev/null; do
    [ -f "$f" ] && echo "--- $f ---" && cat "$f"
done
echo ""

echo "=== 7. 检查是否有其他可疑用户 ==="
awk -F: '$3 == 0 && $1 != "root" {print "警告 UID=0: " $0}' /etc/passwd 2>/dev/null
echo "所有可登录用户:"
awk -F: '$7 ~ /bash|sh|zsh|fish/ && $3 >= 500 {print $1, $3, $6}' /etc/passwd
echo ""

echo "=== 8. 检查 ~/.ssh/known_hosts2 ==="
cat ~/.ssh/known_hosts2 2>/dev/null || echo "(空)"
echo ""

echo "=== 9. 检查所有 ~/.ssh/ 目录 ==="
for d in /home/*/.ssh /root/.ssh; do
    if [ -d "$d" ]; then
        echo "--- $d ---"
        ls -la "$d" 2>/dev/null
    fi
done
echo ""

echo "=== 10. 重启 SSH 服务 ==="
if systemctl restart sshd 2>/dev/null; then
    echo "sshd 重启成功 (systemctl)"
elif service ssh restart 2>/dev/null; then
    echo "ssh 重启成功 (service)"
elif service sshd restart 2>/dev/null; then
    echo "sshd 重启成功 (service)"
else
    echo "⚠️  SSH 重启失败，请手动执行"
fi
echo ""

echo "=== 11. 验证 SSH 服务状态 ==="
if systemctl is-active sshd 2>/dev/null; then
    systemctl status sshd --no-pager 2>/dev/null | head -10
elif service ssh status 2>/dev/null; then
    service ssh status 2>/dev/null | head -10
fi
echo ""

echo "=== 修复完成 ==="
