#!/bin/sh
# 开发辅助脚本：让已安装的 Claude Code 用上本仓库的源码改动。
# 不是 hook；失败必须显式（非 0 退出 + stderr）。
#
# 用法：
#   ./scripts/dev-update.sh                 # 默认 coding-guard
#   ./scripts/dev-update.sh <plugin-name>
#
# 为什么不能只写 `claude plugin update`（实测 CLI 2.1.318）：
#   1) `--all-scopes` 不是有效选项（unknown option）；
#   2) `plugin update` 是**按版本号**判断的：源码改了但 plugin.json 的 version 没变，
#      它会返回 "already at the latest version"，缓存目录一个字节都不会变；
#   3) 目录型 marketplace（source: directory）的安装会**原地加载** readFromFolder
#      指向的源码目录 —— 此时根本不存在“旧缓存副本”问题，源码改动下一次会话即生效。
#   所以本脚本先查 `claude plugin list --json` 的真实加载路径，再决定：
#     · 原地加载且指向本仓库 → no-op，明确告知无需刷新；
#     · 原地加载但指向别处     → 拒绝改动，说明它加载的不是这棵树；
#     · 缓存安装（无 readFromFolder）→ 直接把源码快照同步进 installPath；
#     · 未安装                 → 报错并给出安装命令。
#
# 依赖基线：POSIX sh + grep/sed/cut/head + cp/rm/mkdir，不使用 node/python/jq。
set -u

PLUGIN_NAME="${1:-coding-guard}"

# 解析 CLI：优先 PATH 上的 `claude`；VSCode 扩展环境通常只有
# CLAUDE_CODE_EXECPATH（原生二进制），不导出到 PATH，这里作为第二来源。
CLI_BIN=""
if command -v claude >/dev/null 2>&1; then
  CLI_BIN="claude"
elif [ -n "${CLAUDE_CODE_EXECPATH:-}" ] && [ -x "${CLAUDE_CODE_EXECPATH}" ]; then
  CLI_BIN="${CLAUDE_CODE_EXECPATH}"
else
  echo "dev-update: 'claude' CLI not found on PATH (and CLAUDE_CODE_EXECPATH is unset)." >&2
  echo "dev-update: 请在 PATH 中加入 Claude Code CLI，或先设置 CLAUDE_CODE_EXECPATH。" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || {
  echo "dev-update: cannot resolve script directory." >&2; exit 1;
}
SRC_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || {
  echo "dev-update: cannot resolve plugin root." >&2; exit 1;
}
if [ ! -f "$SRC_DIR/.claude-plugin/plugin.json" ]; then
  echo "dev-update: $SRC_DIR does not look like the plugin root (missing .claude-plugin/plugin.json)." >&2
  exit 1
fi

LIST_JSON=$("$CLI_BIN" plugin list --json 2>/dev/null) || {
  echo "dev-update: '$CLI_BIN plugin list --json' failed." >&2
  exit 1
}

# 同一插件可能在多个 scope / 项目下各装一份，全部处理。
STARTS=$(printf '%s\n' "$LIST_JSON" | grep -n -F "\"id\": \"${PLUGIN_NAME}@" | cut -d: -f1)
if [ -z "$STARTS" ]; then
  echo "dev-update: plugin '$PLUGIN_NAME' is not installed." >&2
  echo "dev-update: 先安装：claude plugin install ${PLUGIN_NAME}@<marketplace> --scope local" >&2
  exit 1
fi

# 从 JSON 对象里取一个字符串字段（CLI 输出为每个字段一行、两个空格缩进的稳定格式）。
json_field() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*\"$2\": \"\\(.*\\)\",\{0,1\}[[:space:]]*$/\\1/p" | head -n 1
}
# JSON 路径里的反斜杠是成对转义的；比较/操作前还原成单个。
unescape_path() {
  printf '%s' "$1" | sed 's/\\\\/\\/g'
}

RC=0
for START in $STARTS; do
  ENTRY=$(printf '%s\n' "$LIST_JSON" | sed -n "${START},/^  }/p")
  if [ -z "$ENTRY" ]; then
    echo "dev-update: cannot parse plugin list entry at line $START." >&2
    RC=1
    continue
  fi

  SCOPE=$(json_field "$ENTRY" scope)
  READ_FROM=$(unescape_path "$(json_field "$ENTRY" readFromFolder)")
  INSTALL_PATH=$(unescape_path "$(json_field "$ENTRY" installPath)")

  # 1) 原地加载：运行时直接读这个目录，缓存快照不参与。
  if [ -n "$READ_FROM" ] && [ -d "$READ_FROM" ]; then
    READ_ABS=$(CDPATH= cd -- "$READ_FROM" 2>/dev/null && pwd -P) || READ_ABS=""
    if [ "$READ_ABS" = "$SRC_DIR" ]; then
      echo "[$SCOPE] $PLUGIN_NAME loads in place from $READ_ABS."
      echo "          Source edits take effect at the next session start (or /reload-plugins); no cache refresh needed."
      continue
    fi
    echo "[$SCOPE] $PLUGIN_NAME loads in place from $READ_ABS, which is NOT this source tree ($SRC_DIR)." >&2
    echo "[$SCOPE] Refusing to touch it: syncing the cache cannot change what this install loads." >&2
    RC=1
    continue
  fi

  # 2) 缓存安装：把源码快照同步进去。官方 update 在同版本下不会做这件事。
  case "$(printf '%s' "$INSTALL_PATH" | sed 's#\\#/#g')" in
    */.claude/plugins/*) ;;
    *)
      echo "[$SCOPE] Refusing unexpected installPath: '$INSTALL_PATH'." >&2
      RC=1
      continue
      ;;
  esac
  if ! mkdir -p "$INSTALL_PATH" 2>/dev/null; then
    echo "[$SCOPE] Cannot create installPath: $INSTALL_PATH" >&2
    RC=1
    continue
  fi

  COPY_OK=1
  # 复制除 .git / backup-* 外的全部顶层条目；先删目标同名项，避免源码里已删除的文件残留。
  for ITEM in "$SRC_DIR"/* "$SRC_DIR"/.[!.]*; do
    [ -e "$ITEM" ] || continue
    BASE=${ITEM##*/}
    case "$BASE" in .git|.claude|backup-*|hardening-report-*) continue ;; esac
    rm -rf "$INSTALL_PATH/$BASE" 2>/dev/null || { COPY_OK=0; break; }
    cp -R "$ITEM" "$INSTALL_PATH/" 2>/dev/null || { COPY_OK=0; break; }
  done
  if [ "$COPY_OK" -ne 1 ]; then
    echo "[$SCOPE] Failed to sync cache snapshot at $INSTALL_PATH." >&2
    RC=1
    continue
  fi
  echo "[$SCOPE] Cache snapshot refreshed at $INSTALL_PATH (direct copy; same-version 'plugin update' is a no-op)."
  echo "          Restart the session (or /reload-plugins) to apply."
done

if [ "$RC" -eq 0 ]; then
  echo "Plugin $PLUGIN_NAME checked at $(date '+%Y-%m-%d %H:%M:%S')."
else
  echo "dev-update: finished with errors." >&2
fi
exit "$RC"
