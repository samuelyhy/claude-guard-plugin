# coding-guard

Claude Code 的跨项目防护插件：规格（spec）优先的文件面门禁、完成门禁、审计记录、
任务启动规则注入，以及缓存 / 会话卫生规则。

## 包含什么

| 组件 | 作用 |
| --- | --- |
| `scripts/session-start-inject.sh` | **SessionStart hook**。每次会话开始确定性注入「任务启动（前置门禁）」；新项目缺少 `.claude/specs/TEMPLATE.md` 时输出初始化指引。 |
| `scripts/spec-conflict-guard.sh` | **PreToolUse**。编辑落盘前检查目标文件是否在规格「涉及文件」范围内。 |
| `scripts/bash-write-guard.sh` | **PreToolUse（Bash）**。把同一份路径判据延伸到 `rm` / `sed -i` / `tee` / 重定向等 shell 写操作。 |
| `scripts/completion-gate.sh` | **Stop**。声称完成前检查规格「验证命令」是否执行过并有输出、「验收标准」声明的测试落点是否动过。 |
| `scripts/audit-post.sh` | **PostToolUse**。把工具执行记录追加到 `.claude/state/audit.jsonl`。 |
| `scripts/token-watcher-ensure.sh` | **SessionStart / UserPromptSubmit**。保持 `cctokens` watcher 存活（项目无 `.cctokens/config.json` 时 no-op）。 |
| `skills/cache-hygiene/SKILL.md` | 缓存与会话卫生规则，以及任务启动门禁的补充说明。 |
| `scripts/dev-update.sh` | 开发辅助脚本（不是 hook）：判定真实加载路径，必要时同步缓存快照。 |

## 安装（项目本地作用域）

先把本仓库注册为插件市场，再**只为当前项目**安装：

```bash
# 1. 注册市场（路径或 URL 指向包含 .claude-plugin/marketplace.json 的目录）
claude plugin marketplace add <插件市场路径或URL>

# 2. 只安装到当前项目（--scope local）
claude plugin install coding-guard@coding-guard --scope local
```

`--scope local` 会把启用项写进当前项目的 `.claude/settings.local.json`。
目录型市场会**原地加载**源码目录，同时在
`~/.claude/plugins/cache/coding-guard/coding-guard/<version>/` 保留一份缓存快照
（两者的区别见「版本维护纪律」）。

> **严禁使用 `--scope user`。**
> user scope 会让所有项目（包括尚未准备好规格与门禁的业务项目）自动加载本插件，
> 造成跨项目污染。每个项目应单独安装、单独确认、必要时单独卸载：

```bash
claude plugin uninstall coding-guard --scope local
```

不安装、只想试用时：

```bash
claude --plugin-dir <本仓库路径>
```

## 规则如何进入上下文

插件根目录的 `CLAUDE.md` **不会被加载**（`claude plugin validate --strict` 会对它告警），
而 skill 依赖模型主动触发，触发失败时规则等于不存在。因此「任务启动」规则改由
`SessionStart` hook 的 stdout 注入——Claude Code 会把这段纯文本确定性追加进上下文。

新项目第一次启动时，若缺少 `.claude/specs/TEMPLATE.md`，hook 会输出初始化提示，
要求模板至少包含：

- `## 涉及文件`
- `## 验证命令`
- `## 验收标准`（表格：编号 | 行为 | 测试文件 | 测试名）

## 版本维护纪律（先判定加载路径，再决定是否刷新）

`claude plugin list --json` 里的 `readFromFolder` 决定运行时到底读哪棵树：

- **目录型 marketplace（本仓库当前用法）**：安装会**原地加载** `readFromFolder`
  指向的源码目录。改完 `scripts/`、`hooks/`、`skills/` 后，下一次会话（或
  `/reload-plugins`）即生效，**不需要重装，也不需要刷新缓存**。
- **缓存型安装（Git/URL 市场，或没有 `readFromFolder`）**：运行时读 `installPath`
  下的缓存快照。注意 `claude plugin update` 是**按版本号**判断的：源码改了但
  `plugin.json` 的 `version` 没变时，它会返回 "already at the latest version"，
  缓存一个字节都不会变（CLI 2.1.318 实测）。此时要么提升 `version`，要么用
  `dev-update.sh` 直接同步快照。

每次改完源码后执行：

```bash
./scripts/dev-update.sh coding-guard
```

它会先读 `claude plugin list --json`：

- 原地加载且指向本仓库 → 明确告知无需刷新，exit 0；
- 原地加载但指向别处 → 拒绝改动，exit 1；
- 缓存安装 → 把源码快照同步进 `installPath`（排除 `.git`、`.claude`、`backup-*`、
  `hardening-report-*`），exit 0；
- 未安装 / 路径异常 → exit 1 并说明原因。

脚本依次从 PATH 上的 `claude`、`CLAUDE_CODE_EXECPATH`（VSCode 扩展环境通常只设后者）
寻找 CLI；两者都没有时直接失败，不会静默跳过。

当前使用显式语义化版本（`1.0.0`）：每次发布前递增 `.claude-plugin/plugin.json` 的
`version`，否则缓存型安装的 `plugin update` 不会拉取新内容。

## 依赖基线

- `session-start-inject.sh`、`dev-update.sh`：仅 **POSIX sh** 与标准 Unix 工具
  （`cat` / `printf` / `sed` / `grep` / `head` / `cut` / `date` / `cp` / `rm` / `mkdir`），
  **不依赖 Node.js 或 Python**。
- 四个执行门禁（`spec-conflict-guard` / `bash-write-guard` / `completion-gate` /
  `audit-post`）与 `token-watcher-ensure`：以 bash 包装内嵌 Node.js 程序运行，
  需要 **`bash` + `node`**。**不需要 `jq` / `python3`。**
- `node` 缺失时的降级：所有 hook **fail-open**（exit 0 放行，会话不阻塞）；
  `audit-post.sh` 额外用 `sed` 提取 `tool_name` 写一条最小审计行，stdout 为空、stderr 静默。

## 失败行为（Fail-open，无噪声）

所有 hook 在任何异常下都遵守同一纪律：

- 没有规格文件 / 规格缺少相关小节 / 解析失败 → 放行；
- 变量为空、目录不存在、文件不可读 → 跳过对应检查，**不向 stdout 输出垃圾**；
- stdout 为空（门禁的显式决策除外）、stderr 静默、`exit 0`；
- 不修改业务代码，不执行 `git add` / `git commit`。

## 开发与本地验证

```bash
# 插件结构与 manifest 校验（需要 Claude Code CLI）
claude plugin validate . --strict

# 注入内容自测（不会写任何文件）
CLAUDE_PROJECT_DIR=/tmp/test ./scripts/session-start-inject.sh

# 直接试用，不安装
claude --plugin-dir "$(pwd)"
```

## 配置

本插件不管理用户级 `~/.claude/settings.json` 中的 `ANTHROPIC_*` 模型配置、
`subagentPromptCacheTtl` 或项目特定的 permission denies；这些留在 user / project 层。

## 刻意不打包的内容

模型路由（`ANTHROPIC_*`）、`subagentPromptCacheTtl`、项目特定的 permission denies，
以及任何会 stage / commit 改动的 hook，都留在 user 或 project 层配置中，不放进插件。

## License

MIT — see [LICENSE](LICENSE).
