#!/bin/bash
# 清理 gary 入侵者公钥 + 添加新公钥

NEW_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8d/EI7Aov+7wawRJco1GhEbSN74KG/Q18q6bYITG55 landi@MacBook-Air-new"

echo "=== 清理前状态:"
echo "当前公钥数量: $(wc -l < ~/.ssh/authorized_keys)"
echo "含 gary 的行:"
grep "gary" ~/.ssh/authorized_keys 2>/dev/null
echo ""

# 删除所有含 gary 的行
echo "=== 删除 gary 公钥..."
grep -v "gary" ~/.ssh/authorized_keys > /tmp/ak_clean
mv /tmp/ak_clean ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo ""

# 添加新公钥
echo "=== 添加新公钥..."
echo "$NEW_KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 去重
sort -u ~/.ssh/authorized_keys > /tmp/ak_unique
cp /tmp/ak_unique ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "=== 清理后状态:"
echo "公钥数量: $(wc -l < ~/.ssh/authorized_keys)"
echo ""
echo "=== 公钥列表:"
cat ~/.ssh/authorized_keys
echo ""

# 验证 gary 已被清除
if grep -q "gary" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "✗ 错误: gary 公钥还在!"
else
    echo "✓ gary 公钥已删除"
fi

# 验证新公钥已添加
if grep -q "MacBook-Air-new" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "✓ 新公钥已添加"
else
    echo "✗ 错误: 新公钥未找到!"
fi
echo ""
echo "完成"
