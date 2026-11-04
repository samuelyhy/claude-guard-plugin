# 发布前准备清单

## 清单元数据

| 字段 | 状态 | 值 |
|---|---|---|
| `name` | ✅ | `coding-guard`（kebab-case） |
| `displayName` | ✅ | `Coding Guard` |
| `version` | ✅ 显式设置 | `1.0.0` |
| `description` | ✅（100 字符） | `Cross-project guard hooks, review agents, and cache hygiene rules extracted from v1-v8 optimization.` |
| `author.name` | ✅ | `SamuelYhy` |
| `author.email` / `author.url` | ⚠️ 未提供（非必需） | — |
| `license` | ✅ | `MIT`（本轮按“发布/分享”场景选择） |
| `homepage` | ✅ | `https://github.com/samuelyhy/claude-guard-plugin` |
| `repository` | ✅ | `https://github.com/samuelyhy/claude-guard-plugin` |
| `keywords` | ✅（4 个） | `guard`, `hooks`, `review`, `cache-hygiene` |
| `defaultEnabled` | ✅ | `true` |

`plugin.json` 未声明 `hooks` / `skills` / `agents` 路径，组件均位于标准目录，符合 v2.1+ 自动加载约定。

## 文件

| 文件 | 状态 |
|---|---|
| `README.md` | ✅ 已补 `License`、`配置`、显式版本维护说明 |
| `LICENSE` | ✅ MIT，2026，SamuelYhy |
| `CHANGELOG.md` | ✅ 含 `1.0.0` 与版本策略提醒 |
| `.claude-plugin/plugin.json` | ✅ |
| `.claude-plugin/marketplace.json` | ✅（路径：`.claude-plugin/marketplace.json`） |

## 校验结果

- `claude plugin validate . --strict`：**✔ Validation passed**，exit 0。
  - 唯一剩余提示：插件目录检查的 `ICON_MISSING`（缺少图标），不改变 strict 结果。
- `claude plugin validate .`（marketplace）：**✔ Validation passed**，exit 0。
- 本地 marketplace 模拟安装：**通过**。
  - 在 `/tmp/release-test` 执行 `plugin install coding-guard@coding-guard --scope local`；
  - `plugin list` 显示 `Scope: local`、`enabled: true`；
  - 测试后已 `uninstall` 并删除临时目录，未影响已有的两个 local 安装（`ai-create-content`、`dify-ai-sync-cli`）。
- 临时项目 hook 触发：**通过**。
  - `.claude/specs/active.md` 只声明 `allowed.txt`；
  - 会话内 Write `blocked.txt` 被 `spec-conflict-guard` 阻断，文件未创建；
  - `.claude/state/audit.jsonl` 有 `phase:"pre"`、`hook_decision:"deny"` 记录；
  - hook 调试日志显示 `spec-conflict-guard` 与 `completion-gate` 均 status 0。
- 回归探针：**通过**。
  - `sh -n scripts/*.sh` 全部通过；
  - 三个 JSON 清单解析通过；
  - `spec-conflict-guard` allow/deny、`bash-write-guard` redirect deny、`audit-post` 正常路径与 node 缺失降级、SessionStart 注入均符合预期；
  - 所有探针 stdout/stderr 无异常噪声。
- `plugin details`（`claude --plugin-dir D:/workSpace/claude-guard-plugin plugin details coding-guard`）：
  - Skills (1)、Agents (0)、Hooks (5: SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop)、MCP (0)。

## 版本策略（二选一，明确记录）

- [x] **显式 version**：每次发布必须递增 `.claude-plugin/plugin.json` 的 `version`，否则 `claude plugin update` 不会拉取新版本。当前为 `1.0.0`。
- [ ] 省略 version：依赖 Git commit SHA。

## 发布前仍需人工完成的事项

- [ ] 手动 `git commit` / `git push`（本轮未执行任何 `git add` / `git commit` / `git tag` / `git push`）。
- [ ] 确认 LICENSE 选择：本轮填入 MIT；若本意是内部使用，请改为 `UNLICENSED` 并同步 README。
- [ ] 补充插件图标：`ICON_MISSING` 仍在。需要 512–2048 px 的 PNG（`.claude-plugin/icon.png` 或 `plugin.json` 的 `icon` 字段）。
- [ ] 确认 `description` 准确性：当前写 “review agents”，但组件清单 Agents (0)；按“不覆盖已有值”的要求本轮未改。
- [ ] 确认 marketplace 结构：当前 `.claude-plugin/` 同时含 `plugin.json` 与 `marketplace.json`，`source` 为 `"./"`，已通过 validate。若要分离 marketplace 根与插件目录，需把插件移到 `plugins/coding-guard` 并更新已有安装记录。
- [ ] 官方目录提交前，在 claude.ai 开发者门户运行 Validate，处理 Blocking 项（本地 validate 不检查 README/LICENSE/名称占用）。
- [ ] 手动删除误建目录 `D:\Users\84111\AppData\Local\Temp\release-test`（只含一个误写的 `.claude/specs/active.md`；内置安全策略阻止了自动删除）。

## 备注

- 本轮未修改任何 hook / skill 行为逻辑。
- 变更文件：`.claude-plugin/plugin.json`（新增 `license` / `homepage` / `repository` / `defaultEnabled`）、`README.md`（License / 配置 / 版本维护）、新增 `LICENSE`、`CHANGELOG.md`、`backup-2026-11-04-release/`。
- marketplace 的 name 是 `coding-guard`，所以安装命令是 `coding-guard@coding-guard`（任务模板中的 `coding-guard-marketplace` 是示例名）。
- 当前插件目录即 marketplace 根目录，`source: "./"` 是刻意保留的、已验证的用法；没有在插件内部另外创建 marketplace 根。
