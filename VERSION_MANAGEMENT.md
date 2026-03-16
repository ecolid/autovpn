# AutoVPN 版本管理规范

## 📋 自动版本号递增机制

### ✅ 已配置

项目已启用**Git Hook 自动版本号递增**机制，确保每次 commit 时版本号都会自动更新。

### 🎯 工作原理

1. **Git Hook 触发**：每次执行 `git commit` 时
2. **自动检测**：`.githooks/pre-commit` 脚本自动运行
3. **版本递增**：读取 `cf_worker_relay.js` 中的 `VERSION` 常量
4. **语义化版本**：自动递增 patch 版本号（v1.19.8 → v1.19.9）
5. **自动暂存**：将更新后的文件自动添加到 git 暂存区

### 📊 版本号规则

采用**语义化版本**（Semantic Versioning）：

```
v主版本号。次版本号。修订号
  ↑      ↑        ↑
 Major  Minor    Patch
```

**自动递增规则**：
- ✅ 每次 commit 自动 +1 Patch 版本
- 📝 手动修改 Major/Minor 版本（重大更新时）

**示例**：
```
v1.19.8  →  v1.19.9  →  v1.19.10  →  v1.19.11
         (小修复)    (功能改进)     (Bug 修复)
```

### 🔧 配置说明

#### 1. Git Hook 配置

```bash
# 已配置（只需执行一次）
git config core.hooksPath .githooks
```

#### 2. 脚本位置

- **Hook 脚本**: `.githooks/pre-commit`
- **版本文件**: `cf_worker_relay.js` (第 30 行)

#### 3. 工作流程

```bash
# 开发者修改代码
git add .

# 提交时自动递增版本号
git commit -m "feat: 新功能"
# 📌 版本号已更新：v1.19.9 -> v1.19.10

# 推送到远程
git push
```

### 🎨 示例输出

```bash
$ git commit -m "fix: 修复问题"
📌 版本号已更新：v1.19.9 -> v1.19.10
[main abc1234] fix: 修复问题
 2 files changed, 5 insertions(+), 2 deletions(-)
```

### 📝 最佳实践

#### ✅ 推荐做法

1. **小步提交**：每次修复/改进都提交
2. **描述清晰**：commit message 说明变更内容
3. **自动递增**：依赖 Git Hook 管理版本
4. **定期同步**：及时 push 到远程仓库

#### ❌ 避免做法

1. ~~手动修改版本号~~（会被 Git Hook 覆盖）
2. ~~跳过版本号~~（每次 commit 必须递增）
3. ~~版本号回退~~（语义化版本不可逆）

### 🛠️ 特殊情况处理

#### 场景 1：修改 Major 版本（重大更新）

```bash
# 1. 先提交当前更改
git commit -m "feat: 重大更新准备"

# 2. 手动修改 cf_worker_relay.js
# 将 const VERSION = "v1.19.9"; 改为 "v2.0.0";

# 3. 提交重大更新
git add cf_worker_relay.js
git commit -m "feat(v2.0.0): 重大版本更新"
# 📌 版本号已更新：v2.0.0 -> v2.0.1（自动递增）
```

#### 场景 2：临时禁用自动递增

```bash
# 使用 --no-verify 跳过 Git Hook
git commit --no-verify -m "docs: 文档更新（不递增版本）"
```

#### 场景 3：查看当前版本

```bash
# 方法 1: 查看文件
grep "^const VERSION" cf_worker_relay.js

# 方法 2: 查看最新 tag
git describe --tags --always

# 方法 3: 查看提交历史
git log --oneline -n 10
```

### 📦 版本发布流程

#### 常规发布（Patch）

```bash
# 1. 开发并测试功能
git add .

# 2. 提交（自动递增版本）
git commit -m "fix: 修复某某问题"
# 📌 版本号已更新：v1.19.9 -> v1.19.10

# 3. 推送到远程
git push

# 4. 更新 Worker（在 Telegram Bot 中）
# 发送 /security → 点击 "🔄 升级指挥部"
```

#### 重大发布（Major/Minor）

```bash
# 1. 完成重大功能开发
git add .
git commit -m "feat: 新功能开发完成"

# 2. 手动修改版本号为 Major/Minor 版本
# 编辑 cf_worker_relay.js: const VERSION = "v2.0.0";

# 3. 提交重大更新
git add cf_worker_relay.js
git commit -m "release(v2.0.0): 重大版本发布"
# 📌 版本号已更新：v2.0.0 -> v2.0.1

# 4. 创建 Git Tag
git tag v2.0.1
git push origin v2.0.1

# 5. 推送到远程
git push
```

### 🔍 故障排查

#### 问题 1：Git Hook 未生效

```bash
# 检查配置
git config core.hooksPath

# 如果没有输出，重新配置
git config core.hooksPath .githooks
```

#### 问题 2：版本号未递增

```bash
# 检查脚本权限
ls -la .githooks/pre-commit
# 应该是 -rwxr-xr-x

# 如果没有执行权限，添加
chmod +x .githooks/pre-commit
```

#### 问题 3：VERSION 常量未找到

```bash
# 检查文件格式
grep "^const VERSION" cf_worker_relay.js

# 如果格式不对，手动修复
# 确保是：const VERSION = "v1.19.9";
```

### 📚 相关文件

- `.githooks/pre-commit` - Git Hook 脚本
- `cf_worker_relay.js` - Worker 主文件（包含 VERSION 常量）
- `VERSION_MANAGEMENT.md` - 本文档

### 🎯 总结

**核心优势**：
- ✅ 自动化：无需手动管理版本号
- ✅ 规范化：确保每次提交都有唯一版本
- ✅ 可追溯：通过版本号追踪代码变更
- ✅ 易维护：减少人为错误

**使用口诀**：
```
代码改完就提交，
版本号会自动跳。
重大更新手动改，
日常开发不用操。
```

---

*最后更新：2026-03-16 | 当前版本：v1.19.10*
