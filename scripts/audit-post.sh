#!/usr/bin/env bash
# PostToolUse 审计：把「工具真的执行了」这件事按 tool_use_id 记一行。
#
# 为什么存在：PreToolUse 的 `ask` 决策（permissionDecisionReason）在交互模式下只展示给用户，
# 不进常规 transcript；`allow` / `defer` 只写 debug log。于是「ask 被允许还是被拒绝」
# 无法从 transcript 机器读取，误报率只能人工补录。这里用 PostToolUse 补一条可关联的记录：
#   - PostToolUse 只在工具**真的执行**之后触发 → 「有记录」= 允许并执行；
#   - 「无记录，但 transcript 里有这次 tool_use」= 被拒绝 / 未被选择执行。
# 两者对照即可复算 ask 的误报与阻断。
#
# 边界（不要声称它解决了）：如果 `ask` 被静默解析成 allow（Issue #95970 描述的那类行为），
# 这里会记到一条「没有对应 PreToolUse ask 记录的执行」。它本身就是一个可审计的异常信号；
# 纠正它属于 Claude Code 的行为，不在 hook 的可控范围内 —— 本脚本只记录，不纠正。
#
# 不做任何阻断、不改任何 payload：只追加一行，永远 exit 0。
# 落盘位置 `.claude/state/audit.jsonl`（`.claude/state/` 已在 .gitignore 里）。
#
# 依赖基线：首选 node（结构化解析 payload）；node 不可用时降级为 POSIX sed/grep
#   写一条最小审计行，仍然静默、仍然 exit 0。不依赖 jq / python。
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd 2>/dev/null || printf '.')}"
STATE_DIR="$ROOT/.claude/state"
# 兜底：目录不存在也要先把落点建出来；失败静默，绝不阻断工具链。
mkdir -p "$STATE_DIR" 2>/dev/null || true

# 零依赖降级：没有 node 时，用 POSIX 工具尽量留下一条最小审计行。
# stdout 为空、stderr 静默、exit 0 —— hook 的失败不能让工具调用失败。
if ! command -v node >/dev/null 2>&1; then
  TOOL=$(sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n 1)
  if [ -n "$TOOL" ]; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
    printf '{"ts":"%s","phase":"post","tool_name":"%s","fallback":"node-unavailable"}\n' \
      "$TS" "$TOOL" >> "$STATE_DIR/audit.jsonl" 2>/dev/null || true
  fi
  exit 0
fi

exec node -e "$(cat <<'JS'
const fs = require('fs');
const path = require('path');

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  try { run(JSON.parse(raw || '{}')); } catch (e) { /* 审计失败不影响工具结果 */ }
  process.exit(0);
});

function run(j) {
  const name = j.tool_name || '';
  if (!['Bash', 'Edit', 'Write', 'MultiEdit'].includes(name)) return;

  const root = process.env.CLAUDE_PROJECT_DIR || j.cwd || process.cwd();
  const resp = j.tool_response;

  const line = {
    ts: new Date().toISOString(),
    phase: 'post',
    tool_use_id: j.tool_use_id || '',
    tool_name: name,
    // 决策字段在 PostToolUse 的 payload 里通常没有 —— 有就写上，没有就如实写 unknown。
    decision: decisionOf(j),
    executed: executedOf(resp),
    error: !executedOf(resp),
    input: summarize(name, j.tool_input || {}),
  };

  try {
    const dir = path.join(root, '.claude', 'state');
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'audit.jsonl'), JSON.stringify(line) + '\n');
  } catch (_) { /* 记不下来也不能因此打断工具链 */ }
}

function decisionOf(j) {
  const hso = j.hookSpecificOutput || {};
  const tr = j.tool_response && typeof j.tool_response === 'object' ? j.tool_response : {};
  return j.permission_decision || j.decision || hso.permissionDecision
    || tr.permissionDecision || 'unknown';
}

// 「执行了」≠「成功了」。只有 payload 明确表示出错 / 被打断才算没执行成功。
function executedOf(resp) {
  if (resp == null) return false;
  if (typeof resp !== 'object') return true;
  if (resp.is_error === true || resp.isError === true) return false;
  if (resp.interrupted === true) return false;
  if (typeof resp.success === 'boolean') return resp.success;
  if (resp.error) return false;
  return true;
}

// 只留能关联到「这条命令/这个文件」的最短信息，避免把整段输出写进审计。
function summarize(name, inp) {
  const s = name === 'Bash' ? inp.command : (inp.file_path || inp.notebook_path || inp.path);
  return typeof s === 'string' ? s.slice(0, 200) : '';
}
JS
)" 2>/dev/null
