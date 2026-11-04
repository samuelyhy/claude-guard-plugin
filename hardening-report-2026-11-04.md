# 插件加固执行记录（2026-11-04）

## 执行环境

- 工作目录：`<plugin-root>`（含 `.claude-plugin/plugin.json`，确认是插件根目录）。
- 工具：Claude Code CLI `2.1.318`（经 `CLAUDE_CODE_EXECPATH` 直接调用，未加入 PATH）；Node.js `v22.16.0`；Git Bash / POSIX sh。
- 备份：`./backup-2026-11-04-hardening/`（11 个文件，覆盖全部被修改文件）。
- 未执行任何 `git add` / `git reset` / `git commit`。
- **异常但非本轮所为**：插件源码目录在 17:25 出现 `.git/` 与 `c3ed834 first commit`
  （提交内容包含 `backup-2026-11-04-hardening/`），随后部分改动处于暂存区（`git status` 只读确认）。
  本轮未执行任何 git 写操作，也未修正该状态；如需清理历史或暂存区，需另行授权。
- 未修改任何业务项目代码；未改动 `<business-project>` 的插件安装记录与缓存。

## 已完成项

| 阶段 | 状态 | 关键证据 |
|---|---|---|
| 1. SessionStart 注入 | 完成 | 临时项目真实会话中，模型逐字引用了 `## 规格模板初始化提示`、`## 任务启动（前置门禁）` 与规格查找顺序行；hook 调试日志显示 `session-start-inject.sh` `finished with status 0`。 |
| 2. 多项目分发 | 完成 | `README.md` 使用 `marketplace add` + `plugin install coding-guard@coding-guard --scope local`，并显式禁止 `--scope user`；`plugin.json` 无 scope 字段（scope 是安装期参数，不存在冲突）。`claude plugin validate . --strict` → `✔ Validation passed`，exit 0。 |
| 3. 缓存更新 | 完成（重设计，见偏差 1） | `dev-update.sh` 可执行，五种路径（原地/异地原地/缓存同步/未安装/异常路径）均按预期退出；真实 CLI 下识别为原地加载并 exit 0，未写缓存。 |
| 4. 新项目初始化向导 | 完成 | 空项目 `CLAUDE_PROJECT_DIR=/tmp/.../empty-proj` 输出完整模板指引；已有 `TEMPLATE.md` 的项目只输出任务启动规则；真实会话引用了该提示。 |
| 5. 零依赖审计 | 完成（基线已记录，见偏差 2） | 新脚本 `session-start-inject.sh`、`dev-update.sh` 无 `[[`/数组/`local` 等 bashism，仅用 POSIX sh + grep/sed/cut/head/cp/rm/mkdir；4 个门禁与 token-watcher 仍依赖 Node，但有显式 `command -v node || exit 0` fail-open，并在文件头与 README 记录。 |
| 6. Fail-Open 无噪声 | 完成 | 无规格时 `spec-conflict-guard`/`bash-write-guard`/`completion-gate` 均 exit 0、stdout 0 字节、stderr 0 字节；`audit-post` 在 node 缺失、空 stdin、目标不可写三种情况下均 exit 0 且 stdout/stderr 0 字节；真实会话 stderr 只有 CLI 自身的 `unrecognized_model` 标题生成告警，不是 hook 输出。 |
| 7. 本地集成测试 | 完成（无交互式 TUI，见边界） | `validate --strict` 通过；临时空 git 仓库 + `--plugin-dir` 的真实 headless 会话中，SessionStart 注入、UserPromptSubmit、Stop 均执行；无 `active.md` 时 Write 成功，审计记录 `hook_decision:"allow", reason:"no-spec"`。 |

## 实际改动文件

- 新增 `scripts/session-start-inject.sh`：SessionStart 注入任务启动门禁；新项目缺模板时输出初始化指引。
- 修改 `hooks/hooks.json`：在 `SessionStart` 数组追加注入 hook（保留原有 token-watcher 条目）。
- 精简 `skills/cache-hygiene/SKILL.md`：移除与注入重复的「任务启动」判据正文，保留两条非重复解释（审计痕迹、过期 active.md 的危害）。
- 新增 `scripts/dev-update.sh`：判定真实加载路径并同步缓存。
- 修改 `scripts/audit-post.sh`：增加 shell 层 `mkdir -p` 兜底、无 node 时的 POSIX sed 降级、分组重定向保证 stderr 静默。
- 修改 `scripts/spec-conflict-guard.sh` / `bash-write-guard.sh` / `completion-gate.sh` / `token-watcher-ensure.sh`：补充依赖基线与 fail-open 说明，`exec node` 的 stderr 静默。
- 重写 `README.md`：安装作用域、加载路径/缓存维护纪律、依赖基线、fail-open 规则。

## 与原始指令的偏差（显式说明）

### 1. `dev-update.sh` 不能只调用 `claude plugin update`（最重要）

原始指令给的脚本是：

```sh
claude plugin update "$PLUGIN_NAME" --all-scopes || claude plugin update "$PLUGIN_NAME"
echo "Plugin ... cache updated ..."
```

在 CLI 2.1.318 上实测：

- `--all-scopes` 是无效选项：`error: unknown option '--all-scopes'`；
- `plugin update` **按版本号判断**。隔离市场中把源码内容改成 `v2-source`、版本仍为 `0.0.1`，
  执行 update 返回 `"updateOutcome":"up_to_date"`，缓存 marker 仍是 `v1`；
- **目录型 marketplace 安装是原地加载**：`plugin list --json` 的 `readFromFolder` 指向源码目录；
  只在源码加了一个 cache 中不存在的 skill，已安装项目仍能调用并返回源码标记。
  `plugin install` 自己也提示：`it loads in place from ... so edits there take effect at the next session start`。

因此，原始脚本会打印“cache updated”但实际什么都没更新 —— 恰好是本次要消除的假成功。
重写后的 `dev-update.sh`：

- 读 `claude plugin list --json`，按 `readFromFolder` / `installPath` 判断真实加载路径；
- 原地加载且指向本仓库 → 明确报告“无需刷新”，exit 0；
- 原地加载但指向别处 → 拒绝改动，exit 1；
- 缓存安装 → 直接同步源码快照到 `installPath`（排除 `.git`、`.claude`、`backup-*`、`hardening-report-*`）；
- 未安装 / 路径异常 → exit 1，给安装命令。
- 同时兼容 PATH 上的 `claude` 与 VSCode 扩展的 `CLAUDE_CODE_EXECPATH`。

**这对“循环重装”的结论**：在当前目录型市场下，根本不需要重装或刷新缓存；源码改动下一次会话即生效。
只有缓存型安装（Git/URL 市场）才涉及版本号与缓存快照，且同版本 update 不会刷新。

### 2. “脚本仅依赖 POSIX sh，不依赖 Node.js”无法如实成立

4 个门禁（`spec-conflict-guard`、`bash-write-guard`、`completion-gate`、`audit-post`）与
`token-watcher-ensure` 是 bash 包装的内嵌 Node 程序（含 shell 词法分析、glob 判定、transcript 解析）。
把它们改写成 awk/sed 属于高风险重写，且会降低门禁质量；本轮**没有**做这种降级。
处理方式是：

- 文档如实写成：新脚本纯 POSIX；门禁需要 `bash + node`；**不需要 jq/python3**；
- 每个 Node 脚本开头记录依赖基线与 fail-open 行为；
- `audit-post.sh` 增加了无 node 时的 sed 降级（写最小审计行），并有测试证据。

若要求“所有脚本都不依赖 node”，需要单独立项重写门禁，不能靠改一行 README 达成。

### 3. `file` 显示 UTF-8 而非 ASCII

7.1 的通过标准写的是 `ASCII text`。现有脚本与本次新增脚本都含中文注释，`file` 输出为
`Unicode text, UTF-8 text`。这是内容语言决定的；为了过检查而删除中文注释会损失可维护性。
本轮改为验证**无 CRLF**：所有 `.sh`、`hooks.json`、`README.md`、`SKILL.md` 的 `\r` 计数均为 0；
`.gitattributes` 保持 `*.sh text eol=lf`。

### 4. hooks 注册命令用 `sh "<path>"` 而非裸路径

原始片段是 `"${CLAUDE_PLUGIN_ROOT}"/scripts/session-start-inject.sh`。在 Windows / 非 bash
shell 下裸执行依赖可执行位与 shebang 解析；与现有 hook 的 `bash "..."` 风格保持一致，
注册为 `sh "${CLAUDE_PLUGIN_ROOT}/scripts/session-start-inject.sh"`。
真实会话的 hook 日志确认该命令执行成功（status 0）。

### 5. 注入文本补充了规格查找顺序

原始注入只提 `.claude/specs/active.md`，但现有门禁的查找顺序是
`spec.md` → `docs/plans/*.md` → `.claude/specs/active.md`。若项目已有 `spec.md`，
只让代理看 `active.md` 会把它引到门禁实际不读的文件。注入文本增加了一句查找顺序，
并在真实会话中验证模型能逐字引用。原始要求的两条判据（先检查、缺失则从模板创建、
只读分析注明“无规格任务”）保持不变。

### 6. `validate --strict` 的插件目录检查

`claude plugin validate . --strict` 输出 `✔ Validation passed`（exit 0），但同时报告
插件目录提交检查的 1 个 problem 与 1 个 warning：

- `LICENSE_MISSING`：仓库没有 LICENSE，`plugin.json` 也没有 `license`；
- `ICON_MISSING`：没有图标。

这两项只影响“提交到官方插件目录”，不影响本地安装与运行；LICENSE 是授权决策，
本轮未擅自添加。需要作者决定。

## 验证明细

### 7.1 机械校验

| 检查项 | 命令 | 结果 |
|---|---|---|
| JSON 语法 | `node -e 'JSON.parse(...)'` 三个 manifest | `JSON OK` |
| 插件校验 | `claude plugin validate . --strict` | `✔ Validation passed`，exit 0 |
| 脚本可执行 | `ls -l scripts/*.sh` | 7 个脚本全部 `-rwxr-xr-x` |
| 行尾规范 | `grep -c $'\r'` | 全部 0（无 CRLF）；`file` 显示 UTF-8 |
| 零依赖 | `grep -nE 'jq\|node\|python' scripts/*.sh` | 命中 5 个 Node 依赖脚本；均有显式 fail-open，已记录（见偏差 2） |
| 注入输出 | `CLAUDE_PROJECT_DIR=/tmp/test ./scripts/session-start-inject.sh` | 含“任务启动”，exit 0，stderr 0 字节 |

### 7.2 临时项目集成

临时目录：`/tmp/test-plugin-proj`（空白 git 仓库，测试后已删除）。

1. 真实 headless 会话（`claude -p --plugin-dir ...`）：
   - 调试日志：`SessionStart:startup [sh ".../session-start-inject.sh"] (plugin coding-guard@inline) finished with status 0`；
   - 模型逐字返回两个注入标题与规格查找顺序行；
   - `Stop` 门禁执行 status 0。
2. 无 `active.md` 时 Write `hello.txt`：
   - 文件成功创建，内容 `hi`；
   - `.claude/state/audit.jsonl` 记录：
     `{"phase":"pre","hook":"spec-conflict-guard","tool_name":"Write","hook_decision":"allow","reason":"no-spec"}`；
   - PostToolUse 也记录了对应 `tool_use_id`。
3. 噪声：stderr 仅 `[claude-code:unrecognized_model] ... generate_session_title`（CLI 的模型标题生成告警），
   不是插件 hook 输出；hook 自身的直测 stderr 均为 0 字节。

### 6.1/6.2 Fail-open 直测

| 场景 | 结果 |
|---|---|
| 无规格 + Edit | exit 0，stdout 0，stderr 0 |
| 无规格 + `rm -f <显式路径>` | exit 0，stdout 0，stderr 0 |
| 无规格 + `rm -rf *` | 按设计 deny（破坏性 glob 无法确认范围），exit 0 |
| 无规格 + Stop | exit 0，stdout 0，stderr 0 |
| `audit-post` 正常（node） | 追加结构化 JSONL，stdout/stderr 0 |
| `audit-post` 无 node | 追加 `{"fallback":"node-unavailable",...}`，stdout/stderr 0，exit 0 |
| `audit-post` 空 stdin | 不追加，stdout/stderr 0，exit 0 |
| `audit-post` 目标不可写 | stdout/stderr 0，exit 0（分组重定向修复了重定向报错泄漏） |

## 未验证 / 边界

- **没有在真实业务项目中开会话验证**；只验证了插件源码与临时项目。
  该项目的插件安装记录（local scope，缓存 `1.0.0`）保持原样，未被本轮修改。
- **缓存型安装的直接同步路径只用 fake CLI 模拟过**（写入了 `/tmp` 下的假 installPath），
  没有对一个真实的 Git/URL 市场缓存做端到端验证。目录型市场的原地加载已用真实会话证实。
- **交互式 TUI 会话未测**；验证使用 `claude -p` headless 会话 + hook 调试日志。
- **LICENSE / 图标**未添加，需作者决定。
- `plugin.json` 版本保持 `1.0.0`（本轮未变更）。若走缓存型发布，建议提升版本后再 `plugin update`。
- 临时目录中 `/tmp/cg-live`、`/tmp/cg-test`、`/tmp/cg-proj-*` 早于本轮（16:31 创建），
  不是本轮产物，未删除；本轮创建的临时目录已全部清理。
- 插件根的 git 仓库与暂存区由外部进程创建，本轮未做任何修正；`.claude/HANDOFF.md` 的
  基线 `c3ed834` 仅用于交接新鲜度比对，不代表本轮提交。
- `audit-post.sh` 的 Node 路径 stderr 已静默，因此 Node 真崩溃时不会留终端告警；
  这是“无噪声 fail-open”的取舍，必要时可改为写本地日志文件（当前未实现）。

## 已确认的边界

- 插件根 `CLAUDE.md` 不会被加载；任务启动规则改由 SessionStart hook 的 stdout 确定性注入。
- 目录型 marketplace 是**原地加载**，源码修改下一次会话生效，不需要重装/刷新缓存。
- 缓存型安装下，`claude plugin update` 同版本不会刷新；需要升版本或用 `dev-update.sh` 直接同步。
- 所有 hook 在缺规格、变量为空、目录不存在、解析失败时 fail-open：stdout 为空（显式决策除外）、
  stderr 静默、exit 0。

## 回滚

```bash
# 恢复本轮修改的全部文件（不涉及 git）
cp -a backup-2026-11-04-hardening/. .
# 删除本轮新增文件
rm -f scripts/session-start-inject.sh scripts/dev-update.sh hardening-report-2026-11-04.md
```
