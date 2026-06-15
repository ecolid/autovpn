echo "========== 安全检查报告 =========="
echo ""
echo "=== 主机信息 ==="
hostname && uname -a
echo ""
echo "=== 1. 最近成功登录 (last -30) ==="
last -30 2>/dev/null | head -30
echo ""
echo "=== 2. SSH 认证日志 - 失败登录 ==="
if [ -f /var/log/auth.log ]; then
  grep "Failed" /var/log/auth.log 2>/dev/null | tail -15
elif [ -f /var/log/secure ]; then
  grep "Failed" /var/log/secure 2>/dev/null | tail -15
else
  journalctl -u ssh 2>/dev/null | grep -i fail | tail -15 || echo "无失败日志"
fi
echo ""
echo "=== 3. SSH 认证日志 - 成功登录 ==="
if [ -f /var/log/auth.log ]; then
  grep "Accepted" /var/log/auth.log 2>/dev/null | tail -15
elif [ -f /var/log/secure ]; then
  grep "Accepted" /var/log/secure 2>/dev/null | tail -15
else
  journalctl -u ssh 2>/dev/null | grep -i accept | tail -15 || echo "无登录日志"
fi
echo ""
echo "=== 4. 当前在线用户 ==="
who && echo "---" && w 2>/dev/null
echo ""
echo "=== 5. SSH 配置 ==="
grep -E "PasswordAuthentication|PermitRootLogin|Port " /etc/ssh/sshd_config 2>/dev/null
echo ""
echo "=== 6. 定时任务 ==="
echo "-- root crontab --"
crontab -l 2>/dev/null || echo "(空)"
echo "-- /etc/cron.d/ --"
ls -la /etc/cron.d/ 2>/dev/null
for f in /etc/cron.d/*; do [ -f "$f" ] && echo "=== $f ===" && cat "$f"; done
echo ""
echo "=== 7. 高 CPU 进程 Top 10 ==="
ps aux --sort=-%cpu | head -11
echo ""
echo "=== 8. 监听端口 ==="
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | head -15
echo ""
echo "=== 9. /tmp 最近 7 天新文件 ==="
find /tmp -type f -mtime -7 2>/dev/null | head -20
echo ""
echo "=== 10. /etc 最近 3 天修改 ==="
find /etc -type f -mtime -3 2>/dev/null | head -20
echo ""
echo "=== 11. authorized_keys ==="
cat ~/.ssh/authorized_keys 2>/dev/null || echo "(空)"
echo ""
echo "=== 12. 是否需要重启 ==="
if [ -f /var/run/reboot-required ]; then echo "是 - 请尽快重启"; else echo "否"; fi
echo ""
echo "========== 检查结束 =========="
