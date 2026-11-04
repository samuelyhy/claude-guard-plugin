# HANDOFF

基线：HEAD `c3ed834`
更新时间：2026-11-04

## 目标

完成 claude-guard-plugin 的加固：SessionStart 确定性注入、本地作用域安装规范、缓存更新机制、
新项目模板向导、零依赖审计、fail-open 无噪声、本地集成验证。

## 已完成（含 commit）

- 本轮未执行 `git add` / `git reset` / `git commit`。插件根在 17:25 由外部进程出现
  `c3ed834 first commit`（含 `backup-2026-11-04-hardening/`），并已有部分改动处于暂存区；
  这不是本轮操作，本轮不对其做任何修正。
- 新增 `scripts/session-start-inject.sh`；`hooks/hooks.json` 追加 SessionStart 条目。
- 精简 `skills/cache-hygiene/SKILL.md`，任务启动判据改由 hook 注入。
- 新增 `scripts/dev-update.sh`（按 CLI 2.1.318 实测重设计）。
- `scripts/audit-post.sh` 增加无 node 降级与分组重定向；其余 4 个 Node 脚本记录依赖基线并静默 stderr。
- 重写 `README.md`；新增 `hardening-report-2026-11-04.md`。
- 备份：`backup-2026-11-04-hardening/`（11 个文件）。

## 进行中（文件:行）

- 无。所有改动已落盘并通过最终机械校验。

## 下一步（可执行）

- 在业务项目 `D:\workSpace\ai-create-content` 开新会话，确认 SessionStart 注入生效
  （该项目为 local scope 安装，目录型市场原地加载源码）。
- 作者决定是否添加 `LICENSE` 与插件图标（`validate` 的插件目录提交检查项）。
- 如需验证缓存型安装：用 Git/URL 市场安装，修改源码后运行 `./scripts/dev-update.sh`，
  确认 `installPath` 快照内容变化。

## 未决与坑

- CLI 2.1.318：`plugin update` 按版本号判断，同版本返回 `up_to_date` 且不刷新缓存；
  `--all-scopes` 不存在（unknown option）。
- 目录型 marketplace 原地加载 `readFromFolder`，源码改动下一次会话生效，不需要重装。
- 4 个门禁与 token-watcher 仍依赖 Node；全 POSIX 化需要单独立项重写。
- 插件根 17:25 出现 `.git/` 与 `c3ed834 first commit`，部分改动已被外部进程暂存；
  本轮未执行任何 git 写操作。提交包含 `backup-2026-11-04-hardening/`，如需清理历史须另行授权。
- `validate --strict` 通过，但插件目录提交检查缺 LICENSE / icon。
- 集成测试用 headless `claude -p`，未测交互式 TUI。

## 验证状态

- `sh -n` 全部通过；三个 manifest JSON 解析通过；`claude plugin validate . --strict` exit 0。
- 真实 headless 会话：模型逐字引用两个注入标题与规格查找顺序；无规格 Write 放行
  （审计 `allow` / `no-spec`）。
- fail-open 直测：stdout/stderr 0 字节；`audit-post` 无 node 时写最小审计行。
- 未验证：真实 Git/URL 市场的缓存同步、交互式 TUI、LICENSE / icon。
