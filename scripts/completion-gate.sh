#!/usr/bin/env bash
# Stop 门禁：会话声称「做完了」之前，做三类机械检查：
#   1) 规格「验证命令」（旧名「完成检查」）里列的命令，是否真的执行过；
#   2) 执行过的话，transcript 里是否留下了**非空的输出**（= 你是否看到过结果）；
#   3) 规格「验收标准」表里声明的测试文件，是否被创建或修改过。
#
# 它不判断「做得好不好」——只抓三种最常见的漂移形态：
#   · 声称完成，但连验证命令都没跑；
#   · 跑了但没看输出（或输出为空），却声称通过；
#   · 声称某条验收标准做到了，但对应的测试落点根本没动。
#
# 明确边界（不要声称它解决了）：机械门禁**不判断输出内容**。
# 「命令执行了、输出是失败的，但代理声称通过」这种形态这里会放行 —— 那是审查层的活。
# 「把实现和测试一起改成自洽但违背规格」同理。见 .claude/optimization-v3-2026-11-04.md。
#
# fail-open：无规格 / 无相关节 / 解析异常 → 放行。
# 防死锁**交给 harness**：连续阻断的硬上限是 harness 的 8 次（`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`
#        可覆盖，≤0 关闭）。本脚本**不自行放行** —— 自己的阈值比 harness 松，等于把门禁削弱成
#        「第 4 次就放弃」。计数只用于告警，不参与放行判定。
# stop_hook_active=true（已因本门禁继续过一次）→ 轻量补救分支：不再做 mtime 这类文件系统推断，
#        只保留直接证据（文件存在 / transcript 里碰过 / 验证命令跑过且有输出）。
# 依赖基线：node（transcript / 规格解析）。node 不可用 → exit 0 放行，
#   即 fail-open：门禁失效但不锁死会话。不使用 jq / python。
# 降级纪律：stdout 为空（除阻断决策外）、stderr 静默、永远 exit 0。
set -u
command -v node >/dev/null 2>&1 || exit 0

exec node -e "$(cat <<'JS'
const fs = require('fs');
const os = require('os');
const path = require('path');

// 只用于告警，**不用于放行**：放行由 harness 的阻断上限决定。
const WARN_AFTER = 3;
// 仅用于把告警文案写准；真正执行覆盖的是 harness，不是这里。
// 未设置 / 非数字 → 默认 8；≤0 → harness 关闭上限。
const HARNESS_CAP = (() => {
  const raw = process.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP;
  if (raw == null || raw === '') return 8;
  const n = Number(raw);
  if (!Number.isFinite(n)) return 8;
  return n > 0 ? n : 0;
})();
const TAIL_BYTES = 16 * 1024 * 1024;
// 被权限拒绝 / 被 hook 拦下的调用不是「验证过」。transcript 里它也是一条 tool_result，
// 不排掉就会把「命令根本没跑起来」当成证据。
const DENIED = /(permission (to use )?[^\n]*denied|Permission to use Bash|was blocked|已阻断|用户拒绝|User rejected|请求被拒绝)/i;

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  try { run(JSON.parse(raw || '{}')); } catch (e) { process.exit(0); }
});

function run(j) {
  const root = process.env.CLAUDE_PROJECT_DIR || j.cwd || process.cwd();
  const spec = findSpec(root);
  if (!spec) return allow();

  const text = fs.readFileSync(spec, 'utf8');
  const transcript = tail(j.transcript_path, TAIL_BYTES);
  if (transcript === null) return allow(); // 读不到 transcript 不阻断

  const entries = parseEntries(transcript);

  // stop_hook_active=true 表示「已经因为本门禁继续过一次」。此时只做轻量补救复查：
  // 唯一被跳过的判断是「文件 mtime 晚于会话开始」这类文件系统推断（也省掉一次读起始标记）。
  // 直接证据 —— 文件是否存在、transcript 里是否碰过、验证命令是否跑过且有输出 —— 一条不少。
  const lightweight = j.stop_hook_active === true;

  // 1) 验收标准的测试落点
  const touched = touchedPaths(root, entries);
  const startedAt = lightweight ? null : sessionStartMs(j.session_id);
  const acLines = section(text, '验收标准');
  const declared = acLines ? testFiles(acLines) : [];
  const missingTests = declared.map((d) => {
    const abs = path.resolve(root, d.file);
    if (!fs.existsSync(abs)) return `${d.id} 声明的测试文件不存在：${d.file}`;
    if (d.existing) return null;
    if (touched.has(normPath(root, d.file))) return null;
    // 子代理的 Edit/Write 不进主 transcript，所以补一条同级的机械判据：
    // 文件 mtime 晚于会话开始时间，也说明它在本次会话里被创建或改过。
    // 拿不到会话开始时间时不猜，按放行处理（fail-open）。
    if (startedAt === null) return null;
    try {
      if (fs.statSync(abs).mtimeMs >= startedAt - 60 * 1000) return null;
    } catch (_) { return null; }
    return `${d.id} 声明的测试文件本次会话未被创建或修改：${d.file}`;
  }).filter(Boolean);

  // 2) 验证命令：执行过 + 看得到非空输出
  const vLines = section(text, '验证命令') || section(text, '完成检查');
  const checks = vLines ? commands(vLines) : [];
  const runs = bashRuns(entries);
  const missingCmds = [];
  for (const c of checks) {
    const hits = runs.filter((r) => r.command.includes(c));
    if (hits.length === 0) { missingCmds.push(`未执行的验证命令：${c}`); continue; }
    const evidenced = hits.some((r) => r.output !== null && r.output.trim() !== '' && !DENIED.test(r.output));
    if (evidenced) continue;
    let why;
    if (hits.some((r) => r.output !== null && DENIED.test(r.output))) why = '调用被拒绝，不算执行过';
    else if (hits.every((r) => r.output === null)) why = 'transcript 里没有它的输出，说明没等到结果';
    else why = '输出为空';
    missingCmds.push(`没有输出证据的验证命令：${c}（${why}）`);
  }

  if (missingTests.length === 0 && missingCmds.length === 0) return allow();

  const missing = [...missingTests, ...missingCmds];
  const session = String(j.session_id || 'unknown').replace(/[^A-Za-z0-9_-]/g, '');
  const count = bump(root, session, missing.join('\n'));

  // 计数只影响文案，**不影响 decision**：这里永远不放行。
  // 连续阻断的硬上限由 harness 执行（默认 8 次），到点后它会覆盖 hook 并结束回合。
  let warn = '';
  if (count > WARN_AFTER) {
    warn =
      `\n\n[completion-gate] 同一组缺失已连续阻断 ${count} 次（告警阈值 ${WARN_AFTER}）。` +
      `本脚本不会因此放行：` +
      (HARNESS_CAP > 0
        ? `harness 会在连续第 ${HARNESS_CAP} 次后强制结束本回合（CLAUDE_CODE_STOP_HOOK_BLOCK_CAP 可调）。`
        : `harness 的阻断上限已被 CLAUDE_CODE_STOP_HOOK_BLOCK_CAP<=0 关闭。`) +
      `请检查是否存在无法补救的缺失；若条目本身不成立，把它从规格里删掉并写明理由。`;
  }

  process.stdout.write(JSON.stringify({
    decision: 'block',
    reason:
      `规格要求的东西没有落点：\n- ${missing.join('\n- ')}\n` +
      `规格：${path.relative(root, spec)}\n` +
      `要么补上测试 / 把验证命令真的跑一遍并看输出，要么把那一行从规格里删掉（删要给理由）。` +
      `不要在不满足的情况下声称完成。注意：门禁只检查「跑过且看得到输出」，不判断输出内容是成功还是失败。` +
      (lightweight ? `\n（本次为 stop_hook_active 轻量复查：已跳过 mtime 兜底。）` : '') +
      warn,
  }));
  process.exit(0);
}

function allow() { process.exit(0); }

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

// 「验收标准」是表格：| AC-1 | 行为 | 测试文件 | 测试名 |
// 只取第 3 列里像路径的东西。单元格写了 [已有] 时，只要求文件存在，不要求本次被改。
function testFiles(lines) {
  const out = [];
  for (const line of lines) {
    const s = line.trim();
    if (!s.startsWith('|')) continue;
    if (/^\|[\s:|-]+\|$/.test(s)) continue; // 分隔行
    const cells = s.split('|').map((c) => c.trim());
    if (cells.length < 4) continue;
    const id = cells[1].replace(/[^A-Za-z0-9-]/g, '');
    const cell = cells[3];
    if (!id || /^AC-?$/i.test(id)) continue;
    if (/^(对应测试文件|测试文件|test)$/i.test(cells[3])) continue;
    const existing = /\[已有\]/.test(cell);
    const m = cell.replace('[已有]', '').match(/[`"']?([\w./\\-]+\.(?:ts|tsx|js|jsx|py|mjs|cjs))[`"']?/);
    if (!m) continue;
    out.push({ id, file: m[1], existing });
  }
  return out;
}

// 「验证命令」可以是表格（取第 1 列），也可以是列表（一行一条）。
// 表格形式：| 命令 | 预期输出特征 |
function commands(lines) {
  const out = [];
  for (const line of lines) {
    let s = line.trim();
    if (!s || s.startsWith('#')) continue;

    if (s.startsWith('|')) {
      if (/^\|[\s:|-]+\|$/.test(s)) continue;            // 分隔行
      const cells = s.split('|').map((c) => c.trim());
      const cmd = unquote(cells[1] || '');
      if (!cmd || /^[-:]+$/.test(cmd)) continue;
      if (/^(命令|command)$/i.test(cmd)) continue;        // 表头
      out.push(cmd);
      continue;
    }

    s = s.replace(/^[-*+]\s*/, '').replace(/^\d+\.\s*/, '');
    s = s.replace(/^\[[ xX]\]\s*/, '');
    s = unquote(s);
    if (!s) continue;
    if (/^https?:/i.test(s)) continue;
    out.push(s);
  }
  return out;
}

function unquote(s) {
  return String(s).replace(/^[`"']+/, '').replace(/[`"']+$/, '').trim();
}

function tail(p, bytes) {
  if (!p) return null;
  try {
    const st = fs.statSync(p);
    const start = Math.max(0, st.size - bytes);
    const fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    return buf.toString('utf8');
  } catch (_) { return null; }
}

function parseEntries(data) {
  const out = [];
  for (const line of data.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch (_) { /* 单行解析失败不影响其他行 */ }
  }
  return out;
}

// 本次会话真正执行过的 Bash 调用，带它们的输出。
// 输出用 tool_use_id 关联到 tool_use；没有对应 tool_result 的就是 output === null。
function bashRuns(entries) {
  const cmds = new Map();
  const results = new Map();
  for (const e of entries) {
    const content = e && e.message && e.message.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (!c) continue;
      if (c.type === 'tool_use' && c.name === 'Bash' && c.input && typeof c.input.command === 'string') {
        cmds.set(c.id, c.input.command);
      } else if (c.type === 'tool_result' && c.tool_use_id) {
        results.set(c.tool_use_id, resultText(c.content));
      }
    }
  }
  const runs = [];
  for (const [id, command] of cmds) {
    runs.push({ command, output: results.has(id) ? results.get(id) : null });
  }
  return runs;
}

function resultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((b) => {
      if (!b) return '';
      if (typeof b === 'string') return b;
      if (typeof b.text === 'string') return b.text;
      if (b.type === 'image') return '[image]';
      return '';
    }).join('\n');
  }
  if (content == null) return '';
  return String(content);
}

// 本次会话真正被 Edit / Write / NotebookEdit 碰过的项目内文件（归一化路径集合）。
function touchedPaths(root, entries) {
  const set = new Set();
  const tools = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
  for (const e of entries) {
    const content = e && e.message && e.message.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (!c || c.type !== 'tool_use' || !tools.includes(c.name)) continue;
      const inp = c.input || {};
      const p = inp.file_path || inp.notebook_path || inp.path;
      if (p) set.add(normPath(root, p));
    }
  }
  return set;
}

function normPath(root, p) {
  return path.resolve(root, p).replace(/\\/g, '/').toLowerCase();
}

// SessionStart 钩子写的会话起点标记；拿不到就返回 null（调用方按放行处理）。
function sessionStartMs(session) {
  if (!session) return null;
  try {
    const p = path.join(os.homedir(), '.claude', 'state', 'context', `${session}.start.json`);
    const n = Number(JSON.parse(fs.readFileSync(p, 'utf8')).started_at);
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch (_) { return null; }
}

// 计数按「缺失集合」分组：缺失变了就重新计数，避免长会话在第 3 次无关阻断后永久失效。
function bump(root, session, signature) {
  const dir = path.join(root, '.claude', 'state', 'stop-gate');
  const file = path.join(dir, `${session || 'unknown'}.count`);
  let state = { count: 0, sig: '' };
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const t = JSON.parse(raw);
    if (t && typeof t === 'object') state = { count: Number(t.count) || 0, sig: String(t.sig || '') };
  } catch (_) { /* 老格式 / 不存在：从 0 开始 */ }
  if (state.sig !== signature) state = { count: 0, sig: signature };
  state.count += 1;
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, JSON.stringify(state));
  } catch (_) { return 1; }
  return state.count;
}
JS
)" 2>/dev/null
