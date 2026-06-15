#!/bin/bash
# 清理 CD 的 admin 用户

echo "=== 1. 当前 admin authorized_keys:"
cat /home/admin/.ssh/authorized_keys 2>/dev/null
echo ""

echo "=== 2. 检查 admin 权限:"
groups admin 2>/dev/null
grep -r "admin" /etc/sudoers* 2>/dev/null | head -5
echo ""

echo "=== 3. 清空 admin authorized_keys:"
> /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown admin:admin /home/admin/.ssh/authorized_keys
echo "已清空"
echo ""

echo "=== 4. 把 admin 的 shell 改为 nologin:"
if [ -f /usr/sbin/nologin ]; then
    usermod -s /usr/sbin/nologin admin
    echo "已改为 nologin"
else
    echo "/usr/sbin/nologin 不存在"
fi
echo ""

echo "=== 5. 验证 admin 新 shell:"
grep "^admin:" /etc/passwd
echo ""

echo "=== 6. 最终 /home/admin/.ssh/:"
ls -la /home/admin/.ssh/
cat /home/admin/.ssh/authorized_keys || echo "(空)"
echo ""
echo "完成"
