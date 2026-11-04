#!/bin/sh
# 开发辅助脚本：把本地插件源码的改动同步进 Claude Code 的插件缓存。
#
# 背景：`claude plugin install ... --scope local` 会把插件内容复制到
#   ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
# 之后业务项目用的是**缓存副本**，不是源码目录。改了 scripts/ hooks/ agents/ skills/
# 却不刷新缓存，已安装项目继续跑旧代码 —— 这就是“循环重装”的根源。
#
# 用法：
#   ./scripts/dev-update.sh                 # 默认 coding-guard
#   ./scripts/dev-update.sh <plugin-name>
#
# 这是开发者工具，不是 hook：失败必须显式（退出码非 0 + stderr），
# 不能像 hook 那样 fail-open 后还打印“已更新”。
set -u

PLUGIN_NAME="${1:-coding-guard}"

if ! command -v claude >/dev/null 2>&1; then
  echo "dev-update: 'claude' CLI not found on PATH." >&2
  echo "dev-update: 请在 PATH 中加入 Claude Code CLI，或用完整路径调用本脚本前先导出 PATH。" >&2
  exit 1
fi

# --all-scopes 在旧版本可能不存在；第一段静默尝试，失败后回退到不带 scope 的更新，
# 并让回退那次的输出可见（失败原因不能被吞掉）。
if claude plugin update "$PLUGIN_NAME" --all-scopes >/dev/null 2>&1; then
  :
elif claude plugin update "$PLUGIN_NAME"; then
  :
else
  echo "dev-update: failed to update plugin '$PLUGIN_NAME'." >&2
  echo "dev-update: 检查插件是否已安装：claude plugin list" >&2
  exit 1
fi

echo "Plugin $PLUGIN_NAME cache updated at $(date)"
