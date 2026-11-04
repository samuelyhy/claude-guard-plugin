#!/usr/bin/env bash
# PreToolUse 门禁：编辑落盘前，检查目标文件是否在当前规格声明的「涉及文件」范围内。
#
# 设计取舍（刻意为之）：
#   - 只做机械匹配，不做语义理解。误报是成本，漏报是风险，这里偏向宁可误报。
#   - 没有规格文件、规格里没有「涉及文件」节 → 一律放行（fail-open）。
#     「没写规格」不该变成「什么都不能改」。
#   - 任何解析异常 → 放行并 exit 0。门禁脚本自己坏掉不能把仓库锁死。
#
# 规格查找顺序：spec.md → docs/plans/ 下最新的 .md → .claude/specs/active.md
set -u
command -v node >/dev/null 2>&1 || exit 0

exec node -e "$(cat <<'JS'
const fs = require('fs');
const path = require('path');

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  try {
    run(JSON.parse(raw || '{}'));
  } catch (e) {
    process.exit(0); // fail-open
  }
});

// 审计行要记真实工具名（Edit / Write / MultiEdit / NotebookEdit），
// 而不是在出口处猜一个 —— 出口函数拿不到 j。
let CURRENT_TOOL = '';

function run(j) {
  const tool = j.tool_name || '';
  if (!['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(tool)) return process.exit(0);
  CURRENT_TOOL = tool;

  const inp = j.tool_input || {};
  const target = inp.file_path || inp.notebook_path || inp.path || '';
  const tid = j.tool_use_id || '';
  const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  if (!target) return exitAllow(root, tid, 'no-target');

  const norm = (s) => path.resolve(root, s).replace(/\\/g, '/').toLowerCase();
  const t = norm(target);
  const r = norm(root);
  if (!t.startsWith(r + '/')) return exitAllow(root, tid, 'outside-project'); // 项目外不归它管

  // 规格本身永远可改：契约修订必须留下 diff，而不是逼人去用 Bash 绕过门禁。
  if (t.startsWith(norm(path.join(root, '.claude', 'specs')) + '/')) return exitAllow(root, tid, 'spec-file');

  const spec = findSpec(root);
  if (!spec) return exitAllow(root, tid, 'no-spec');

  let text;
  try { text = fs.readFileSync(spec, 'utf8'); } catch (_) { return exitAllow(root, tid, 'spec-read-fail'); }
  const listed = section(text, '涉及文件');
  if (listed === null) return exitAllow(root, tid, 'no-file-scope'); // 规格没声明文件面 → 放行
  const allowed = pathTokens(listed);
  if (allowed.length === 0) return exitAllow(root, tid, 'empty-file-scope');

  const excluded = pathTokens(section(text, '不做什么') || []);
  const hitExcl = excluded.find((p) => matches(t, norm(p)));
  if (hitExcl) return block(
    `目标文件命中规格「不做什么」里的排除项：${hitExcl}\n` +
    `规格：${path.relative(root, spec)}\n` +
    `请先确认这次改动是否要扩展规格（删掉该排除项并写明理由），否则不要改这个文件。`,
    root, tid
  );

  const hitAllow = allowed.some((p) => matches(t, norm(p)));
  if (!hitAllow) return block(
    `目标文件不在规格「涉及文件」范围内，已阻断落盘。\n` +
    `规格：${path.relative(root, spec)}\n` +
    `目标：${path.relative(root, target)}\n` +
    `允许的路径：${allowed.join(', ')}\n` +
    `若这次改动确属本任务，先把该路径加进规格的「涉及文件」节；否则说明发生了规格外改动。`,
    root, tid
  );

  return exitAllow(root, tid, 'in-scope');
}

// PreToolUse 侧记账：与 bash-write-guard 写同一个文件、同一套字段，
// 两行靠 tool_use_id 和 PostToolUse 的 phase:"post" 关联。
function auditPre(root, tid, decision, reason) {
  try {
    const dir = path.join(root, '.claude', 'state');
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'audit.jsonl'), JSON.stringify({
      ts: new Date().toISOString(),
      phase: 'pre',
      hook: 'spec-conflict-guard',
      tool_use_id: tid || '',
      tool_name: CURRENT_TOOL,
      hook_decision: decision,
      reason: String(reason || '').slice(0, 200),
    }) + '\n');
  } catch (_) { /* 审计失败不能改变决策 */ }
}

function exitAllow(root, tid, reason) {
  auditPre(root, tid, 'allow', reason);
  process.exit(0);
}

function block(reason, root, tid) {
  auditPre(root, tid, 'deny', reason);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

function findSpec(root) {
  const direct = path.join(root, 'spec.md');
  if (fs.existsSync(direct)) return direct;

  const plans = path.join(root, 'docs', 'plans');
  try {
    const files = fs.readdirSync(plans).filter((f) => f.endsWith('.md'));
    if (files.length) {
      files.sort((a, b) =>
        fs.statSync(path.join(plans, b)).mtimeMs - fs.statSync(path.join(plans, a)).mtimeMs);
      return path.join(plans, files[0]);
    }
  } catch (_) { /* 目录不存在就跳过 */ }

  const active = path.join(root, '.claude', 'specs', 'active.md');
  if (fs.existsSync(active)) return active;
  return null;
}

// 取某个标题下的正文行；标题用 includes 匹配（允许「## 5. 涉及文件」这类编号）。
function section(text, title) {
  const lines = text.split(/\r?\n/);
  let start = -1; let level = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(#{1,6})\s*(.+)$/);
    if (m && m[2].includes(title)) { start = i; level = m[1].length; break; }
  }
  if (start < 0) return null;
  const out = [];
  for (let i = start + 1; i < lines.length; i++) {
    const m = lines[i].match(/^(#{1,6})\s/);
    if (m && m[1].length <= level) break;
    out.push(lines[i]);
  }
  return out;
}

// 从列表行里抠出路径 token。只认含 / 或 . 的第一段，忽略 URL 与纯说明词。
function pathTokens(lines) {
  const res = [];
  for (const line of lines) {
    let s = line.trim();
    if (!s || s.startsWith('#')) continue;
    s = s.replace(/^[-*+]\s*/, '').replace(/^\d+\.\s*/, '').replace(/^\[[ xX]\]\s*/, '');
    s = s.split(/\s+/)[0];
    s = s.replace(/^[`"'(（]+/, '').replace(/[`"',，。；;：:)）]+$/, '');
    if (!s || /^https?:/i.test(s)) continue;
    if (/[\/.]/.test(s)) res.push(s);
  }
  return res;
}

// 精确匹配，或目标落在某个目录入口之下。`dir/**` 视作目录前缀。
function matches(target, entry) {
  const e = entry.replace(/\/\*\*?$/, '');
  if (target === e) return true;
  if (target.startsWith(e + '/')) return true;
  return false;
}
JS
)"
