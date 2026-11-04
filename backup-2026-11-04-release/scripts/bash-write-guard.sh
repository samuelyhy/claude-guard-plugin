#!/usr/bin/env bash
# PreToolUse 门禁（Bash）：有规格时，拦截可能改写文件的 shell 命令。
#
# 为什么存在：PreToolUse 原来只匹配 Edit|Write|MultiEdit|NotebookEdit，于是
# rm / sed -i / cat > / tee 可以完全绕过「涉及文件」检查。这个钩子把同一份
# 路径判据延伸到 shell 写操作上。
#
# 判据（v4 起）：三条同时成立才 deny ——
#   1) 路径条件：能从命令里可靠提取**具体的、非通配符**的目标路径；
#   2) 语义条件：该 token 在 shell 语义上确实是「写入」（引号内 / heredoc 正文里的
#      `>` 是文本，不是重定向 —— 先遮蔽 heredoc 正文再词法分析）；
#   3) 范围条件：该路径不在规格「涉及文件」内。
# 任一条**无法可靠判定**（glob、未展开变量）→ 放行，并记进
# `.claude/state/bash-guard-undecided.log` 供人工抽查。
# 这条是 v3 误报的来源：旧判据只看「有没有 >」，把文本当成了写入。
#
# 例外（v5）：**破坏性命令**（rm/rmdir/shred/unlink/mv/truncate/dd/find -delete、写重定向）
# 的目标带**未加引号的** glob 或**空/未定义**变量 → 阻断（v5 起是 ask，v7 起默认 deny），不静默放行。
# 只读命令（ls/find 不带 -delete/grep/cat）的 glob 仍然 fail-open —— `ls *.env*` 不该弹框。
# 引号内的字面值不算展开（`rm -f "*.log"` 仍然放行）。
#
# 收窄（v6）：破坏性 + glob 不再**一律** ask，只在「展开面可能触及规格外」时 ask：
#   · 展开范围能静态界定（`*.log` 在仓库根、`src/*` 在 src/ 下）→ 由规格覆盖情况判定；
#   · 范围不可静态界定（裸 `*`、`**`、`*/*` 这类首段通配）→ 仍然 ask；
#   · 经过管道 / 命令替换 / xargs 后目标不明 → fail-open，但**必须**记「glob 未判定」。
#   · 没有规格时**不要放宽**：破坏性 glob 与不可提取目标一律 ask。
# 破坏性表新增 `sed -i`（就地改写）与 `tee`（写文件）；`/dev/null` 不算写入目标。
# `cp` 仍不在表内（通常是新文件）；`cp -f` 覆盖已有文件当前不检测 —— 记为 KNOWN GAP，看见就记账。
#
# 决策档位（v7）：`ask` 在 **VS Code 扩展默认权限模式**下是**静默 no-op**（Issue #86754：
# deny-tier 生效，ask-tier 不弹框、按 allow 处理）。所以本钩子原本的两处 ask
# （破坏性 + 判不出范围的 glob / 完全提取不到写入目标）**默认升级为 deny**。
# 这是安全修复不是功能降级：改造之前，这两处在 VS Code 里等于**完全放行**。
# 只有在 headless CLI（那里 ask 会 fail closed）才把 `BASH_GUARD_ASK=1` 设回去 —— 一行环境变量，不新增门禁。
#
# 设计取舍（刻意为之）：
#   - 不是沙箱。`python -c "...open(...,'w')"`、`node -e "fs.writeFileSync(...)"` 抓不到。
#   - 没有规格 / 规格里没有「涉及文件」节 / 解析异常 → 一律放行（fail-open）。
#   - 「命令确实会写，但连一个目标 word 都没有」（`find -delete`、`sed -i` 无文件参数）
#     仍然 ask，不改成放行：这类命令的破坏面无法从命令行界定，ask 不是 deny，
#     不产生 v3 那类误报，但把 ask 去掉就等于让 `find -delete` 静默通过。
#   - .claude/specs/ 与 .claude/state/ 永久放行（契约必须能修订；日志与计数不承载内容）。
#   - `2>&1` / `/dev/null` / heredoc 分隔符不算写入目标。
# 依赖基线：node（shell 词法分析 / glob 判定）。node 不可用 → exit 0 放行，
#   即 fail-open：规则失效但不锁死仓库。不使用 jq / python。
# 降级纪律：stdout 为空、stderr 静默、永远 exit 0，绝不阻断工具调用。
set -u
command -v node >/dev/null 2>&1 || exit 0

exec node -e "$(cat <<'JS'
const fs = require('fs');
const path = require('path');

// 决策档位：见文件头「决策档位（v7）」。
// 默认 deny —— 因为在 VS Code 扩展里 ask 等于 allow。headless CLI 想恢复 ask，设 BASH_GUARD_ASK=1。
const BLOCK_TIER = process.env.BASH_GUARD_ASK === '1' ? 'ask' : 'deny';
const TIER_NOTE = BLOCK_TIER === 'deny'
  ? '（当前环境把 ask 档升级为 deny：VS Code 扩展里 ask 不弹框、会被静默当成 allow。）\n'
  : '';

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  try { run(JSON.parse(raw || '{}')); } catch (e) { process.exit(0); }
});

function run(j) {
  if ((j.tool_name || '') !== 'Bash') return process.exit(0);
  const cmd = (j.tool_input || {}).command;
  const tid = j.tool_use_id || '';
  const root = process.env.CLAUDE_PROJECT_DIR || j.cwd || process.cwd();
  if (typeof cmd !== 'string' || !cmd.trim()) return exitAllow(root, tid, 'empty-command');

  // 规格可能不存在。v6 起「没有规格」不再等于「破坏性 glob 静默放行」：
  // 显式路径仍然 fail-open（没有文件面可比对），但破坏性 + 展开风险一律 ask。
  const spec = findSpec(root);
  let allowed = null;
  if (spec) {
    let text;
    try { text = fs.readFileSync(spec, 'utf8'); } catch (_) { return exitAllow(root, tid, 'spec-read-fail'); }
    const listed = section(text, '涉及文件');
    if (listed !== null) {
      const toks = pathTokens(listed);
      if (toks.length) allowed = toks;
    }
  }

  const ops = analyze(cmd, 0);
  if (ops.length === 0) {
    // `find … | xargs rm -f` 这种：破坏性动作不是命令行上的第一条命令，分类器抓不到。
    // 不放行得悄无声息 —— 记一条「glob 未判定」供人工抽查，决策仍是 fail-open。
    if (hasIndirection(cmd) && /\b(rm|rmdir|mv|truncate|dd|tee)\b|\bsed\s+-[a-zA-Z]*i/.test(cmd)) {
      recordUndecided(root, [`glob 未判定（xargs/命令替换）: ${cmd.slice(0, 140)}`]);
    }
    return exitAllow(root, tid, 'no-write-op');
  }

  const norm = (s) => path.resolve(root, s).replace(/\\/g, '/').toLowerCase();
  const r = norm(root);
  const rel = (p) => path.relative(root, path.resolve(root, p)).replace(/\\/g, '/');

  const indirect = hasIndirection(cmd);
  const violations = [];
  const unknown = [];
  const undecided = [];
  const risky = [];
  const notes = [];
  for (const op of ops) {
    if (!op.targets || op.targets.length === 0) { unknown.push(op.kind); continue; }
    for (const t of op.targets) {
      if (isDevNull(t.v)) continue;                             // `2>/dev/null`、`tee /dev/null` 不是写入目标
      // 条件 1：目标可不可靠提取。glob / 未展开变量 → 判不了，放行并记账。
      if (isUnextractable(t.v)) {
        undecided.push(`${op.kind} -> ${t.v}`);
        if (!op.destructive) continue;
        // 管道 / 命令替换 / xargs 之后目标由运行时决定：命令行上判不出来。
        // 按需求 fail-open，但必须留下「glob 未判定」，否则等于悄悄失效。
        if (indirect) { undecided.push(`glob 未判定（xargs/命令替换）: ${op.kind} -> ${t.v}`); continue; }
        if (!expandRisk(t)) continue;
        const info = globInfo(t.raw);
        if (!info) { risky.push(`${op.kind} -> ${t.v}（范围不可静态推断）`); continue; }
        if (allowed === null) { risky.push(`${op.kind} -> ${t.v}（无规格，无法确认范围）`); continue; }
        if (coveredBy(info, allowed, root)) {
          notes.push(`glob 部分在规格内: ${op.kind} -> ${t.v}`);
          continue;
        }
        risky.push(`${op.kind} -> ${t.v}（展开前缀 "${info.dir || '.'}" 不在规格内）`);
        continue;
      }
      if (allowed === null) continue;                           // 没有文件面可比对：显式路径 fail-open
      const n = norm(t.v);
      if (n !== r && !n.startsWith(r + '/')) continue;          // 项目外不归它管
      if (n === r) { violations.push(`${op.kind} -> .（整棵仓库）`); continue; }
      if (n.startsWith(r + '/.claude/specs/')) continue;        // 契约本身可修订
      if (n.startsWith(r + '/.claude/state/')) continue;        // 日志 / 计数
      if (allowed.some((a) => entryMatches(n, a, root))) continue;
      violations.push(`${op.kind} -> ${rel(t.v)}`);
    }
  }

  // cp 覆盖已有文件当前不检测 —— 这是显式缺口，不是遗漏。看见就记一行，不改变判据。
  for (const op of ops) {
    if (/^cp /.test(op.kind)) notes.push(`KNOWN GAP: cp 覆盖未检测 -> ${(op.targets[0] || {}).v || '(无目标)'}`);
  }

  if (undecided.length) recordUndecided(root, undecided);
  if (notes.length) recordNotes(root, notes);

  if (violations.length) {
    return decide('deny',
      'Bash 写操作命中了规格「涉及文件」之外的目标，已阻断。\n' +
      `规格：${path.relative(root, spec)}\n` +
      `问题：\n- ${violations.join('\n- ')}\n` +
      `允许的路径：${allowed.join(', ')}\n` +
      '改文件请用 Edit/Write（它们走同一份路径判据）；若确属本任务，把该路径加进规格的' +
      '「涉及文件」节（`.claude/specs/` 下的规格永远可改），再重试。',
      root, tid
    );
  }
  if (risky.length) {
    return decide(BLOCK_TIER,
      TIER_NOTE +
      '该命令属于破坏性操作，目标里包含未加引号的 glob 或空/未定义变量，' +
      `展开到哪些路径在命令行上判不出来：\n- ${[...new Set(risky)].join('\n- ')}\n` +
      (spec ? `规格：${path.relative(root, spec)}\n` : '（当前没有规格，无法确认范围。）\n') +
      '若要改文件，请改用 Edit/Write，或把目标写成显式路径；' +
      '若这批路径确属本任务，把目录写进规格的「涉及文件」节，再重试。',
      root, tid
    );
  }
  if (unknown.length) {
    return decide(BLOCK_TIER,
      TIER_NOTE +
      '这条 Bash 命令看起来会写文件，但无法可靠提取写入目标：' +
      `${[...new Set(unknown)].join(', ')}\n` +
      (spec ? `规格：${path.relative(root, spec)}\n` : '') +
      '若要改文件，请改用 Edit/Write，或把命令写成目标显式的形式' +
      '（例如重定向落到 `.claude/state/` 下）；只读命令请去掉会写的那一段。',
      root, tid
    );
  }
  return exitAllow(root, tid, 'in-scope');
}

// 目标里带 glob / 未展开变量 → 这条命令会写到哪里，命令行上判不出来。
function isUnextractable(t) {
  return /[*?[\]{}$]/.test(t) || /^~/.test(t);
}

// 「这个目标会不会展开到命令行字面值之外」。只看 token 的 raw 部分 ——
// 引号内、转义得到的字符不算展开（`rm -f "*.log"` 是字面文件名）。
function expandRisk(t) {
  if (/[*?[\]{}]/.test(t.raw)) return true;   // 未加引号的 glob / 花括号
  return unsetOrEmptyVar(t.raw);              // 空或未定义的 $VAR
}

// $VAR / ${VAR} 在 hook 执行环境里为空或未定义 → 展开结果不可预测（可能退化成空串或 `/`）。
function unsetOrEmptyVar(raw) {
  const re = /\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g;
  let m;
  while ((m = re.exec(raw))) {
    const v = process.env[m[1]];
    if (v === undefined || v === '') return true;
  }
  return false;
}

// 判不了就放行，但必须留下痕迹：没有记录的 fail-open 等于悄悄失效。
function recordUndecided(root, items) {
  try {
    const dir = path.join(root, '.claude', 'state');
    fs.mkdirSync(dir, { recursive: true });
    const line = `${new Date().toISOString()}\t${items.join(' | ')}\n`;
    fs.appendFileSync(path.join(dir, 'bash-guard-undecided.log'), line);
  } catch (_) { /* 记不下来也不能因此阻断 */ }
}

// 记账用：与 undecided.log 分开，避免把「在规格内所以放行」和「判不了所以放行」混在一起。
function recordNotes(root, items) {
  try {
    const dir = path.join(root, '.claude', 'state');
    fs.mkdirSync(dir, { recursive: true });
    const line = `${new Date().toISOString()}\t${items.join(' | ')}\n`;
    fs.appendFileSync(path.join(dir, 'bash-guard-notes.log'), line);
  } catch (_) { /* 同上 */ }
}

// `/dev/null`（以及 Windows 的 NUL）在任何方向上都不是「写入某个文件」。
function isDevNull(v) {
  const s = String(v).replace(/\\/g, '/').toLowerCase();
  return s === '/dev/null' || s === 'nul' || /(^|\/)dev\/null$/.test(s);
}

// 目标由运行时决定：管道交给 xargs、命令替换、反引号。
// 这种情况命令行上判不出破坏面，按需求 fail-open —— 但必须留下记录。
function hasIndirection(cmd) {
  return /\bxargs\b/.test(cmd) || /\$\(/.test(cmd) || /`[^`]*`/.test(cmd);
}

// 破坏性 glob 的展开范围能不能**静态**界定。
// 返回 null = 不可界定（裸 `*`、`**`、`**\/*`、首段含通配）；否则给出静态目录前缀。
function globInfo(raw) {
  const s = String(raw).replace(/\\/g, '/');
  if (!/[*?[\]{}]/.test(s)) return null;
  if (/\*\*/.test(s)) return null;                              // ** 跨目录，范围不可界定
  const segs = s.split('/');
  const last = segs[segs.length - 1];
  if (segs.length === 1 && /^\*+$/.test(last)) return null;      // 裸 *：仓库根全删
  if (segs.length > 1 && /[*?[\]{}]/.test(segs[0])) return null; // `*/*.log` 这类首段通配
  const w = s.search(/[*?[\]{}]/);
  const head = s.slice(0, w);
  const slash = head.lastIndexOf('/');
  const dir = slash < 0 ? '' : head.slice(0, slash).replace(/^\.\//, '');
  return { dir, pattern: s, wholeDir: /^\*+$/.test(last) };      // wholeDir：`src/*` 这种整目录删除
}

// glob → 正则：`*` 不跨 `/`，`**` 跨 `/`。
function globRe(g) {
  let out = '^';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') { out += '.*'; i += 1; } else out += '[^/]*';
    } else if (c === '?') out += '[^/]';
    else if ('\\^$.|+()[]{}'.includes(c)) out += '\\' + c;
    else out += c;
  }
  return new RegExp(out + '$', 'i');
}

// 规格条目能否匹配一个**显式**目标（节点条件 3）。
// 条目可以是字面路径、目录（`dir/`、`dir/**`）或 glob。
function entryMatches(n, entry, root) {
  const raw = String(entry).replace(/\\/g, '/');
  const base = raw.replace(/\/\*\*?$/, '').replace(/\/$/, '');
  const relp = path.relative(root, n).replace(/\\/g, '/');
  if (/[*?[\]]/.test(base)) return globRe(base).test(relp);
  const abs = path.resolve(root, base || '.').replace(/\\/g, '/').toLowerCase();
  const target = n.toLowerCase();
  if (abs === target) return true;
  if (abs === path.resolve(root, '.').replace(/\\/g, '/').toLowerCase()) return true;  // 规格写了 `.`
  return target.startsWith(abs + '/');
}

// 规格能否覆盖破坏性 glob 的**整个展开面**。
// 两种覆盖：(1) 目录入口（`dir/`、`dir/**`、整仓 `.`）包含 glob 的静态前缀；
//           (2) 规格里写了同一个 glob（`*.log` ↔ `*.log`）。
// 只列了目录里**某一个文件**不算覆盖 —— `rm -rf src/*` 会删掉没列进来的兄弟文件。
function coveredBy(info, allowed, root) {
  const groot = path.resolve(root, '.').replace(/\\/g, '/').toLowerCase();
  const gdir = path.resolve(root, info.dir || '.').replace(/\\/g, '/').toLowerCase();
  for (const a of allowed) {
    const raw = String(a).replace(/\\/g, '/');
    if (raw === '.' || raw === './') return true;              // 规格声明了整仓
    const dirEntry = /\/\*\*?$/.test(raw) || raw.endsWith('/');
    if (dirEntry) {
      const base = raw.replace(/\/\*\*?$/, '').replace(/\/$/, '');
      const d = path.resolve(root, base || '.').replace(/\\/g, '/').toLowerCase();
      if (d === groot && info.dir === '') return true;
      if (gdir === d || gdir.startsWith(d + '/')) return true;
    }
    if (!info.wholeDir && raw === info.pattern) return true;   // 同一个 glob 写在规格里
  }
  return false;
}

// PreToolUse 侧也要记账：没有 pre 行，审计里就分不清「hook 直接放行」
// 与「hook 问了、用户点了允许」。两行靠 tool_use_id 关联。
function auditPre(root, tid, decision, reason) {
  try {
    const dir = path.join(root, '.claude', 'state');
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'audit.jsonl'), JSON.stringify({
      ts: new Date().toISOString(),
      phase: 'pre',
      hook: 'bash-write-guard',
      tool_use_id: tid || '',
      tool_name: 'Bash',
      hook_decision: decision,
      reason: String(reason || '').slice(0, 200),
    }) + '\n');
  } catch (_) { /* 审计失败不能改变决策 */ }
}

function exitAllow(root, tid, reason) {
  auditPre(root, tid, 'allow', reason);
  process.exit(0);
}

function decide(decision, reason, root, tid) {
  auditPre(root, tid, decision, reason);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision,
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

// ---- 语义条件的第一步：把 heredoc 正文遮蔽掉 ----
// heredoc 正文是「喂给命令的数据」，里面的 > < | 不是 shell 语法。
// 不遮蔽就会把 `some text with > character` 读成「重定向到 character」——
// 这是 v3 记录在案的唯一一类真实误报。
function maskHeredocBodies(src) {
  const lines = src.split('\n');
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    out.push(line);
    const delims = heredocDelims(line);
    i += 1;
    for (const d of delims) {
      const strip = d.stripTabs ? (s) => s.replace(/^\t+/, '') : (s) => s;
      while (i < lines.length) {
        const body = lines[i];
        i += 1;
        if (strip(body) === d.word) break;   // 分隔符行结束正文
        out.push('');                        // 正文行整体丢弃
      }
    }
  }
  return out.join('\n');
}

// 找出这一行里的 heredoc 分隔符（引号外的 `<<` / `<<-`，不含 `<<<` herestring）。
function heredocDelims(line) {
  const res = [];
  let i = 0;
  while (i < line.length) {
    const c = line[i];
    if (c === '\\') { i += 2; continue; }
    if (c === "'" || c === '"') {
      const q = c; i += 1;
      while (i < line.length && line[i] !== q) {
        if (q === '"' && line[i] === '\\') i += 1;
        i += 1;
      }
      i += 1; continue;
    }
    if (c === '<' && line[i + 1] === '<' && line[i + 2] !== '<') {
      let j = i + 2;
      let stripTabs = false;
      if (line[j] === '-') { stripTabs = true; j += 1; }
      while (j < line.length && (line[j] === ' ' || line[j] === '\t')) j += 1;
      let word = '';
      while (j < line.length) {
        const d = line[j];
        if (d === "'" || d === '"') {
          const q = d; j += 1;
          while (j < line.length && line[j] !== q) { word += line[j]; j += 1; }
          j += 1; continue;
        }
        if (d === ' ' || d === '\t') break;
        if ('|&;<>()'.includes(d)) break;
        word += d; j += 1;
      }
      if (word) res.push({ word, stripTabs });
      i = j; continue;
    }
    i += 1;
  }
  return res;
}

// ---- 词法：把 shell 命令切成 word / 分隔符 / 重定向三类 token ----
// 目的不是完整实现 POSIX shell，而是「别把 2>&1 当成写文件」这一级别的够用。
function lex(s) {
  const toks = [];
  let cur = '';
  let raw = '';   // 只累积「未加引号、未被转义」的字符：判 glob / 变量是否真的会展开
  let has = false;
  let i = 0;
  const push = () => {
    if (has) { toks.push({ type: 'word', v: cur, raw }); cur = ''; raw = ''; has = false; }
  };

  while (i < s.length) {
    const c = s[i];
    if (c === '\\') {
      if (i + 1 < s.length) { cur += s[i + 1]; has = true; i += 2; continue; }
      i++; continue;
    }
    if (c === "'" || c === '"') {
      const q = c; i++;
      while (i < s.length && s[i] !== q) {
        if (q === '"' && s[i] === '\\' && i + 1 < s.length) { cur += s[i + 1]; i += 2; continue; }
        cur += s[i]; i++;
      }
      i++; has = true; continue;
    }
    if (c === ' ' || c === '\t') { push(); i++; continue; }
    if (c === '#' && !has) {                       // 词首注释：吃到行尾
      while (i < s.length && s[i] !== '\n') i++;
      continue;
    }
    if (c === '\n' || c === ';') { push(); toks.push({ type: 'sep' }); i++; continue; }
    if (c === '|') { push(); if (s[i + 1] === '|') i++; toks.push({ type: 'sep' }); i++; continue; }
    if (c === '&') {
      if (s[i + 1] === '&') { push(); toks.push({ type: 'sep' }); i += 2; continue; }
      if (s[i + 1] === '>') {
        push(); i += 2;
        let v = '&>';
        if (s[i] === '>') { v = '&>>'; i++; }
        toks.push({ type: 'redir', v: v });
        continue;
      }
      push(); toks.push({ type: 'sep' }); i++; continue;
    }
    if (c === '>') {
      let v = '>';
      if (has && /^[0-9]+$/.test(cur)) { v = cur + '>'; cur = ''; raw = ''; has = false; }  // 2> 的 fd 前缀
      push();
      if (s[i + 1] === '>') { v += '>'; i += 2; }
      else if (s[i + 1] === '&') { v += '&'; i += 2; }                           // 2>&1
      else i += 1;
      toks.push({ type: 'redir', v: v });
      continue;
    }
    if (c === '<') {
      let v = '<';
      if (has && /^[0-9]+$/.test(cur)) { v = cur + '<'; cur = ''; raw = ''; has = false; }
      push();
      if (s[i + 1] === '<') { v += '<'; i += 2; if (s[i] === '<') { v += '<'; i++; } }
      else i += 1;
      toks.push({ type: 'redir', v: v });
      continue;
    }
    cur += c; raw += c; has = true; i++;
  }
  push();
  return toks;
}

// 真正的「写文件」重定向：> >> 2> 2>> &> &>>。`>&`（fd 复制）与 `<` `<<` `<<<`（读入）不算。
function isWriteRedir(v) {
  return /^(?:[0-9]*>>?|&>>?)$/.test(v);
}

function analyze(cmd, depth) {
  if (depth > 2) return [];
  const toks = lex(maskHeredocBodies(cmd));
  const ops = [];
  let words = [];
  let i = 0;

  const flush = () => {
    if (!words.length) return;
    const op = classify(words);
    if (op) {
      if (op.nested) ops.push(...analyze(op.nested, depth + 1));
      else ops.push(op);
    }
    words = [];
  };

  while (i < toks.length) {
    const t = toks[i];
    if (t.type === 'sep') { flush(); i++; continue; }
    if (t.type === 'redir') {
      const nx = toks[i + 1];
      const hasTarget = !!nx && nx.type === 'word';
      if (isWriteRedir(t.v)) {
        if (hasTarget && !/^&/.test(nx.v) && nx.v !== '/dev/null') {
          ops.push({ kind: `重定向写入 (${t.v})`, targets: [nx], destructive: true });
        } else if (!hasTarget) {
          ops.push({ kind: `重定向写入 (${t.v})`, targets: [], destructive: true });
        }
      }
      i += hasTarget ? 2 : 1;
      continue;
    }
    words.push(t);
    i++;
  }
  flush();
  return ops;
}

// targets 是**词法 token**（{ v, raw }），不是字符串：`raw` 只含未加引号的字符，
// 用来区分 `rm -f *.log`（会展开）与 `rm -f "*.log"`（字面值）。
// destructive: true 的 op 在「目标判不出来」时走 ask，而不是静默放行。
function classify(toks) {
  const w = toks.map((t) => t.v);
  const base = path.basename(w[0]).toLowerCase();
  const args = toks.slice(1);
  const bare = args.filter((a) => !a.v.startsWith('-'));

  switch (base) {
    case 'rm': case 'rmdir': case 'shred': case 'unlink':
      return { kind: `${base} 删除`, targets: bare, destructive: true };
    case 'mv':
      return { kind: 'mv 移动', targets: bare, destructive: true };
    case 'cp':
      return { kind: 'cp 复制', targets: bare.length ? [bare[bare.length - 1]] : [] };
    case 'tee':
      return { kind: 'tee 写入', targets: bare, destructive: true };
    case 'truncate':
      return { kind: 'truncate 截断', targets: bare, destructive: true };
    case 'dd': {
      const of = args.filter((a) => a.v.startsWith('of=')).map((a) => ({
        v: a.v.slice(3),
        raw: a.raw.startsWith('of=') ? a.raw.slice(3) : '',
      }));
      return { kind: 'dd 写入', targets: of, destructive: true };
    }
    case 'sed': {
      const inPlace = args.some((a) => /^(?:-[a-zA-Z]*i[a-zA-Z.]*|--in-place(?:=.*)?)$/.test(a.v));
      if (!inPlace) return null;
      let sawScriptFlag = false;
      let scriptSeen = false;
      const files = [];
      for (let k = 0; k < args.length; k++) {
        const a = args[k];
        if (a.v === '-e' || a.v === '--expression' || a.v === '-f' || a.v === '--file') { sawScriptFlag = true; k++; continue; }
        if (a.v.startsWith('-') && a.v.length > 1) continue;
        if (!sawScriptFlag && !scriptSeen) { scriptSeen = true; continue; }   // 第一条裸参数是脚本
        files.push(a);
      }
      return { kind: 'sed -i 就地改写', targets: files, destructive: true };
    }
    case 'find':
      if (args.some((a) => a.v === '-delete' || a.v === '-exec')) {
        return { kind: 'find -delete/-exec', targets: [], destructive: true };
      }
      return null;
    case 'git': {
      const sub = bare[0] && bare[0].v;
      if (sub === 'restore') {
        const staged = args.some((a) => a.v === '--staged');
        const worktree = args.some((a) => a.v === '--worktree');
        if (staged && !worktree) return null;  // 只动索引
        return { kind: 'git restore', targets: bare.slice(1) };
      }
      if (sub === 'checkout') {
        const idx = args.findIndex((a) => a.v === '--');
        return idx >= 0 ? { kind: 'git checkout --', targets: args.slice(idx + 1) } : null;
      }
      return null;
    }
    case 'bash': case 'sh': case 'zsh': case 'dash': {
      const ci = args.findIndex((a) => a.v === '-c');
      if (ci >= 0 && args[ci + 1]) return { nested: args[ci + 1].v };
      return null;
    }
    default:
      return null;
  }
}
JS
)" 2>/dev/null
