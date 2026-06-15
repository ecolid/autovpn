#!/usr/bin/env bash
set -e

echo ""
echo "########################################################"
echo "#  AutoVPN 服务器安全检查脚本"
echo "#  执行时间: $(date)"
echo "#  主机: $(hostname)"
echo "#  IP: $(curl -s ifconfig.me 2>/dev/null || echo 'unknown')"
echo "########################################################"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

PASS="${GREEN}[PASS]${PLAIN}"
WARN="${YELLOW}[WARN]${PLAIN}"
FAIL="${RED}[FAIL]${PLAIN}"

check_count=0
warn_count=0
fail_count=0

echo "=== 1. SSH 安全检查 ==="
echo ""

# 1.1 SSH 密码登录
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  $PASS SSH 密码登录已禁用"
else
    echo "  $FAIL SSH 密码登录未禁用！建议: sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart sshd"
    fail_count=$((fail_count + 1))
fi
check_count=$((check_count + 1))

# 1.2 root 登录
if grep -qE "^PermitRootLogin (no|prohibit-password)" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  $PASS root 直接登录已禁用"
else
    echo "  $WARN root 允许直接登录，建议改为 prohibit-password"
    warn_count=$((warn_count + 1))
fi
check_count=$((check_count + 1))

# 1.3 SSH 密钥文件权限
if [ -f ~/.ssh/id_rsa ]; then
    perms=$(stat -c %a ~/.ssh/id_rsa 2>/dev/null)
    if [ "$perms" = "600" ]; then
        echo "  $PASS SSH 私钥权限正确 (600)"
    else
        echo "  $FAIL SSH 私钥权限不对 ($perms)！应为 600"
        fail_count=$((fail_count + 1))
    fi
fi
check_count=$((check_count + 1))

# 1.4 authorized_keys 数量
if [ -f ~/.ssh/authorized_keys ]; then
    key_count=$(wc -l < ~/.ssh/authorized_keys)
    if [ "$key_count" -le 3 ]; then
        echo "  $PASS authorized_keys 有 $key_count 个公钥"
    else
        echo "  $WARN authorized_keys 有 $key_count 个公钥，请确认是否都在使用"
        echo "       内容:"
        cat ~/.ssh/authorized_keys | sed 's/^/         /'
        warn_count=$((warn_count + 1))
    fi
fi
check_count=$((check_count + 1))

# 1.5 SSH 登录失败日志
echo ""
echo "=== 2. SSH 登录日志检查 ==="
failed_count=$(grep "Failed password" /var/log/auth.log 2>/dev/null | wc -l || echo 0)
if [ "$failed_count" -gt 0 ]; then
    echo "  $WARN 检测到 $failed_count 次 SSH 登录失败尝试"
    echo "       最近 20 条:"
    grep "Failed password" /var/log/auth.log 2>/dev/null | tail -20 | sed 's/^/         /'
    warn_count=$((warn_count + 1))
else
    echo "  $PASS 未检测到 SSH 登录失败尝试"
fi

# 2.1 检查成功登录
success_logins=$(grep "Accepted" /var/log/auth.log 2>/dev/null | tail -10 | wc -l || echo 0)
if [ "$success_logins" -gt 0 ]; then
    echo ""
    echo "  $WARN 最近 10 次成功登录:"
    grep "Accepted" /var/log/auth.log 2>/dev/null | tail -10 | sed 's/^/         /'
fi
check_count=$((check_count + 1))

echo ""
echo "=== 3. 进程和后门检查 ==="

# 3.1 挖矿进程
miner_found=0
for p in xmrig minerd cpuminer kinsing sustes; do
    if pgrep -f "$p" > /dev/null 2>&1; then
        echo "  $FAIL 发现可疑进程: $p"
        miner_found=1
        fail_count=$((fail_count + 1))
    fi
done
if [ "$miner_found" -eq 0 ]; then
    echo "  $PASS 未发现挖矿进程"
fi
check_count=$((check_count + 1))

# 3.2 异常高 CPU 进程
echo ""
echo "  前 5 个高 CPU 进程:"
ps aux --sort=-%cpu | head -6 | sed 's/^/         /'

# 3.3 crontab 检查
echo ""
echo "  root crontab:"
crontab -l 2>/dev/null || echo "         (空)"
if [ -d /etc/cron.d ]; then
    echo ""
    echo "  /etc/cron.d/ 内容:"
    for f in /etc/cron.d/*; do
        [ -f "$f" ] && echo "         --- $f ---" && cat "$f" | sed 's/^/         /'
    done
fi

echo ""
echo "=== 4. 网络和端口检查 ==="

# 4.1 开放端口
echo "  对外监听的端口:"
if command -v ss > /dev/null; then
    ss -tlnp 2>/dev/null | grep -v "127.0.0.1\|::1" | sed 's/^/         /'
elif command -v netstat > /dev/null; then
    netstat -tlnp 2>/dev/null | grep -v "127.0.0.1\|::1" | sed 's/^/         /'
fi

# 4.2 防火墙状态
echo ""
if command -v ufw > /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "  $PASS UFW 防火墙已启用"
else
    echo "  $WARN 未检测到启用的防火墙，建议: ufw enable"
    warn_count=$((warn_count + 1))
fi
check_count=$((check_count + 1))

# 4.3 Xray 配置检查
if [ -f /usr/local/etc/xray/config.json ]; then
    echo ""
    echo "  Xray 配置 API 监听检查:"
    api_listen=$(grep -o '"listen".*"[^"]*"' /usr/local/etc/xray/config.json 2>/dev/null | head -3 || true)
    if echo "$api_listen" | grep -q "127.0.0.1\|localhost"; then
        echo "  $PASS Xray API 仅监听本地"
    elif echo "$api_listen" | grep -q "0.0.0.0"; then
        echo "  $FAIL Xray API 监听 0.0.0.0！对外暴露，高危！"
        fail_count=$((fail_count + 1))
    else
        echo "  $WARN Xray API 监听配置: $api_listen"
    fi
fi
check_count=$((check_count + 1))

echo ""
echo "=== 5. 文件完整性检查 ==="

# 5.1 最近修改的敏感文件
echo "  最近 7 天修改的 /etc 下文件:"
find /etc -mtime -7 -type f 2>/dev/null | head -20 | sed 's/^/         /'

# 5.2 /tmp 下的可疑文件
if [ -d /tmp ]; then
    tmp_count=$(find /tmp -mtime -7 -type f 2>/dev/null | wc -l)
    if [ "$tmp_count" -gt 10 ]; then
        echo ""
        echo "  $WARN /tmp 下有 $tmp_count 个最近 7 天修改的文件:"
        find /tmp -mtime -7 -type f 2>/dev/null | head -20 | sed 's/^/         /'
        warn_count=$((warn_count + 1))
    fi
fi

echo ""
echo "=== 6. 检查 VPS 上是否留存敏感信息 ==="

# 6.1 检查是否有 token/key 留在文件中
found_sensitive=0
for f in /usr/local/etc/xray/config.json /root/.bash_history /etc/environment; do
    if [ -f "$f" ]; then
        sensitive=$(grep -iE "Bearer|xox[baprs]-|ghp_[A-Za-z0-9]|CF_TOKEN|TELEGRAM|BOT_TOKEN" "$f" 2>/dev/null | head -5 || true)
        if [ -n "$sensitive" ]; then
            echo "  $FAIL 在 $f 中发现敏感信息:"
            echo "$sensitive" | sed 's/^/         /'
            found_sensitive=1
            fail_count=$((fail_count + 1))
        fi
    fi
done
if [ "$found_sensitive" -eq 0 ]; then
    echo "  $PASS 未在关键配置文件中发现敏感信息"
fi
check_count=$((check_count + 1))

echo ""
echo "=== 7. 系统版本检查 ==="
echo "  系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  需要重启: $(if [ -f /var/run/reboot-required ]; then echo '是'; else echo '否'; fi)"

echo ""
echo "########################################################"
echo "#  检查汇总"
echo "########################################################"
echo "  总检查项: $check_count"
echo "  $GREEN 通过: $((check_count - warn_count - fail_count))$PLAIN"
echo "  $YELLOW 警告: $warn_count$PLAIN"
echo "  $RED 失败: $fail_count$PLAIN"

if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "  ${RED}⚠️  发现严重安全问题，请立即处理！${PLAIN}"
fi

if [ "$warn_count" -gt 3 ]; then
    echo ""
    echo -e "  ${YELLOW}⚠️  有多个警告项，建议逐一排查${PLAIN}"
fi

echo ""
