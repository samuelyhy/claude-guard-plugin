# Changelog

All notable changes to this project will be documented in this file.

版本策略：显式语义化版本。每次发布必须递增 `.claude-plugin/plugin.json` 的 `version`；
`claude plugin update` 按版本号判断，同版本不会拉取新内容。

## [1.0.0] - 2026-11-04

### Added

- `spec-conflict-guard`：编辑规格外文件时阻断
- `bash-write-guard`：Bash 写入规格外路径时阻断
- `completion-gate`：Stop 时检查验证命令是否执行并有输出
- `audit-post`：Pre/Post 双侧审计记录
- `cache-hygiene` skill：缓存与会话卫生规则
- SessionStart 规则注入：任务启动门禁 + 新项目模板初始化提示
- `dev-update`：判定插件真实加载路径并在必要时同步缓存快照
