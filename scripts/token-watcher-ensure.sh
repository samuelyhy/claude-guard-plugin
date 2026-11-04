#!/usr/bin/env bash
# 确保 cctokens 的扫描进程活着，并且**不会并发拉起多个**。
#
# 为什么需要它：`.cctokens/hook-start.cjs`（cctokens 自动生成的）每次 SessionStart
# 都无条件 spawn 一个 watcher。resume/clear/compact/fork 都会触发 SessionStart，
# 于是短时间内可能有多个 watcher 抢同一个 token-usage.jsonl 的临时文件，
# 在 Windows 上表现为连续 `EPERM: operation not permitted, rename`，直到进程退出。
# 进程一死，token 日志就开始静默缺行 —— 所有基于日志的验证都建在缺数据上。
#
# 做法：
#   · `cctokens start` 本身是幂等的（已在运行会直接返回「已在运行（pid …）」）；
#   · 这里再加一层节流：每 10 分钟最多碰一次，避免并发竞态与每条 prompt 都起 node；
#   · 挂在 SessionStart 与 UserPromptSubmit 上，所以会话中途死掉也能被拉回来。
#   · 全程 fail-open：任何异常都 exit 0，绝不阻塞对话。
# 依赖基线：node（读取 .cctokens/config.json）。node 不可用 → exit 0，
#   即 fail-open：watcher 不被拉起，但会话照常进行。不使用 jq / python。
# 降级纪律：stdout 为空、stderr 静默、永远 exit 0。
set -u
command -v node >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CFG="$ROOT/.cctokens/config.json"
[ -f "$CFG" ] || exit 0

BIN=$(node -e 'try{process.stdout.write(require(process.argv[1]).binPath||"")}catch(e){}' "$CFG" 2>/dev/null)
[ -n "$BIN" ] || exit 0
[ -f "$BIN" ] || exit 0

STATE="$ROOT/.claude/state"
mkdir -p "$STATE" 2>/dev/null || exit 0
STAMP="$STATE/token-watcher.last"

NOW=$(date +%s 2>/dev/null || echo 0)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|"") LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt 600 ] 2>/dev/null; then exit 0; fi
fi
printf '%s' "$NOW" > "$STAMP" 2>/dev/null || exit 0

node "$BIN" start >/dev/null 2>&1 &
exit 0
