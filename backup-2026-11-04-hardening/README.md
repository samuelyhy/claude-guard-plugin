# coding-guard

Cross-project guard hooks and cache-hygiene rules for Claude Code.

This plugin packages the v1–v8 optimisation work into a reusable bundle:

- **PreToolUse guards** — `spec-conflict-guard.sh` blocks edits outside the file
  surface declared in `.claude/specs/active.md`; `bash-write-guard.sh` extends the
  same path judgement to shell write operations (`rm`, `sed -i`, `tee`, redirects).
- **Stop gate** — `completion-gate.sh` checks that the spec's verification commands
  ran and produced output before a session claims completion.
- **Audit trail** — `audit-post.sh` appends one line per executed tool call to
  `.claude/state/audit.jsonl`.
- **Token watcher liveness** — `token-watcher-ensure.sh` keeps the `cctokens`
  watcher alive (no-op when a project has no `.cctokens/config.json`).
- **Cache hygiene skill** — `skills/cache-hygiene/SKILL.md` carries the cache and
  session hygiene rules plus the spec-first task startup gate.

All hooks are fail-open: with no spec file, no `.claude/` directory, or any parse
error they exit 0 silently. They never modify business code and never stage or
commit anything.

## Install (project-local)

```bash
claude plugin install coding-guard@coding-guard --scope local
```

The marketplace is this directory itself (`.claude-plugin/marketplace.json`).
`--scope local` writes `enabledPlugins` to `.claude/settings.local.json`; the
plugin content is cached under `~/.claude/plugins/`.

To try it without installing, start a session with:

```bash
claude --plugin-dir <path-to-this-directory>
```

## Requirements

- `bash` and `node` on `PATH` (the hook scripts are bash wrappers around embedded
  Node programs).
- Either `spec.md`, `docs/plans/*.md`, or `.claude/specs/active.md` in the target
  project if you want the guards to enforce file scope. Without one they allow
  everything.

## What is deliberately not bundled

Model routing (`ANTHROPIC_*`), `subagentPromptCacheTtl`, project-specific
permission denies, and any hook that stages or commits changes stay at user or
project level. See the migration record in the source project for details.
