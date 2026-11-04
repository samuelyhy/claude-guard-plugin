# Changelog

All notable changes to this project will be documented in this file.

版本策略：显式语义化版本。每次发布必须递增 `.claude-plugin/plugin.json` 的 `version`；
`claude plugin update` 按版本号判断，同版本不会拉取新内容。

## [1.0.2] - 2026-11-04

### Added

- 品牌 Logo：`assets/logo.svg`（矢量源）与 1024×1024 `.claude-plugin/icon.png`

### Changed

- README 顶部展示 Logo
- 版本说明更新为 1.0.2

## [1.0.1] - 2026-11-04

### Added

- `.claude-plugin/icon.png`：512×512 插件图标，清除 `ICON_MISSING` 警告

### Changed

- 从发布树中移除 `backup-2026-11-04-*` 目录（完整历史仍保留在 v1.0.0）
- 脱敏文档中的本地绝对路径与内部业务项目名
- README 增加公开仓库安装命令，版本说明更新为 1.0.1

## [1.0.0] - 2026-11-04

### Added

- `spec-conflict-guard`：编辑规格外文件时阻断
- `bash-write-guard`：Bash 写入规格外路径时阻断
- `completion-gate`：Stop 时检查验证命令是否执行并有输出
- `audit-post`：Pre/Post 双侧审计记录
- `cache-hygiene` skill：缓存与会话卫生规则
- SessionStart 规则注入：任务启动门禁 + 新项目模板初始化提示
- `dev-update`：判定插件真实加载路径并在必要时同步缓存快照
