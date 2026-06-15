#!/bin/bash
# 添加新公钥到 authorized_keys 并去重

NEW_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID8d/EI7Aov+7wawRJco1GhEbSN74KG/Q18q6bYITG55 landi@MacBook-Air-new"

echo "当前公钥数量: $(wc -l < ~/.ssh/authorized_keys)"
echo ""
echo "添加新公钥..."

echo "$NEW_KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 去重
sort -u ~/.ssh/authorized_keys > /tmp/ak_unique
cp /tmp/ak_unique ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo "完成。当前公钥数量: $(wc -l < ~/.ssh/authorized_keys)"
echo ""
echo "公钥列表:"
cat ~/.ssh/authorized_keys
echo ""

# 验证新公钥是否已添加
if grep -q "MacBook-Air-new" ~/.ssh/authorized_keys; then
    echo "✓ 新公钥已成功添加"
else
    echo "✗ 错误: 新公钥未添加!"
fi
