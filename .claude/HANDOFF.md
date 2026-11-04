# HANDOFF

基线：HEAD `9bd6a96`
更新时间：2026-11-04

## 目标

完成 claude-guard-plugin 的加固与发布前准备：SessionStart 注入、本地作用域安装规范、
缓存更新机制、零依赖审计、fail-open、发布元数据/文档/marketplace 与模拟安装验证。

## 已完成（含 commit）

- 加固批次（见 `hardening-report-2026-11-04.md`）：SessionStart 注入、skill 精简、
  `dev-update.sh`、`audit-post.sh` 降级、README 重写；备份 `backup-2026-11-04-hardening/`。
- 发布前准备（见 `release-readiness-2026-11-04.md`）：
  - `plugin.json` 新增 `license=MIT`、`homepage` / `repository`、`defaultEnabled=true`；
  - 新增 `LICENSE`（MIT）、`CHANGELOG.md`；
  - README 增加 License / 配置 / 显式版本维护说明；
  - marketplace 清单沿用 `.claude-plugin/marketplace.json`（`source: "./"`），validate 通过；
  - 备份 `backup-2026-11-04-release/`。
- 本轮未执行任何 `git add` / `commit` / `tag` / `push`。外部进程已将工作区推进到 `9bd6a96`。

## 进行中（文件:行）

- 无。发布前准备文件已落盘。

## 下一步（可执行）

- 手动 `git commit` / `git push`（用户执行）。
- 确认许可证：当前 MIT；若内部使用改为 `UNLICENSED` 并同步 README。
- 补插件图标：512–2048 px PNG 到 `.claude-plugin/icon.png` 或 `plugin.json` 的 `icon`。
- 确认 `description`：当前含 “review agents”，但组件清单 Agents (0)；未擅自改写。
- 手动删除误建目录 `D:\Users\84111\AppData\Local\Temp\release-test`
  （安全策略阻止自动删除）。
- 官方目录提交前在 claude.ai 开发者门户运行 Validate。

## 未决与坑

- CLI 2.1.318：`plugin update` 按版本号判断，同版本 `up_to_date` 不刷新；`--all-scopes` 不存在。
- 目录型 marketplace 原地加载 `readFromFolder`，源码改动下一次会话生效。
- 4 个门禁与 token-watcher 仍依赖 Node；全 POSIX 化需单独立项。
- 插件目录即 marketplace 根（`source: "./"`）；若分离需移动插件并更新安装记录。
- `validate --strict` 通过；唯一剩余提示是 `ICON_MISSING`。
- 发布前集成测试用 headless `claude -p`，未测交互式 TUI。
- 误建 `D:\Users\...\release-test` 目录（只含 `.claude/specs/active.md`），待用户删除。

## 验证状态

- `sh -n` 全部通过；三个 JSON 解析通过；`plugin validate . --strict` exit 0。
- 本地 marketplace 模拟安装：`/tmp/release-test` 安装 local 成功；hook 触发 Write 阻断，
  audit `pre` deny 记录存在；测试后已卸载并删除临时项目。
- 回归探针：spec allow/deny、bash redirect deny、audit-post 正常与无 node 降级、
  SessionStart 注入均通过；stdout/stderr 无异常。
- `plugin details`（`--plugin-dir`）：Hooks 5、Skills 1、Agents 0。
