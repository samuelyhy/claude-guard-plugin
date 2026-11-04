#!/bin/sh
# Claude Code SessionStart hook — inject the task-start gate deterministically.
#
# 为什么是 hook 而不是 skill / 插件根 CLAUDE.md：
#   · 插件根目录的 CLAUDE.md 不会被加载（`claude plugin validate --strict` 会告警）；
#   · skill 依赖模型主动触发，触发失败时规则等于不存在；
#   · SessionStart 的 stdout 会被 Claude Code 原样追加进上下文，加载是确定的。
#
# 依赖基线：仅 POSIX sh 内建与标准 Unix 工具（cat / printf / test / pwd）。
#   不使用 node / python / jq。
#
# 降级原则（fail-open，无噪声）：
#   · 任何变量为空、目录不存在、路径不可读 → 只跳过对应段落，绝不写 stderr；
#   · 静态「任务启动」规则始终注入 —— 它与项目路径无关，不存在“读不到项目”就失效的问题；
#   · 永远 exit 0，绝不阻塞会话。
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"

# 没有 CLAUDE_PROJECT_DIR 时，只在当前目录确实像项目根时才回退到 pwd。
# 否则会在任意 cwd（例如插件源码目录、$HOME）误报“缺少模板”。
if [ -z "$PROJECT_DIR" ]; then
  if [ -d ./.git ] || [ -d ./.claude ]; then
    PROJECT_DIR=$(pwd 2>/dev/null || printf '')
  fi
fi

# 1) 新项目引导：只在“项目根已知但模板缺失”时输出。
#    不静默失败 —— 全新项目第一轮就能看到该建什么文件。
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  if [ ! -f "$PROJECT_DIR/.claude/specs/TEMPLATE.md" ]; then
    cat <<'EOF'
## 规格模板初始化提示
当前项目尚未配置 `.claude/specs/TEMPLATE.md`。
请先创建该文件，并至少包含：
- `## 涉及文件`
- `## 验证命令`
- `## 验收标准`（表格：编号 | 行为 | 测试文件 | 测试名）
随后从 `.claude/specs/TEMPLATE.md` 复制出 `.claude/specs/active.md`，按本次任务填写。
EOF
  fi
fi

# 2) 静态前置门禁：与具体项目无关，始终注入。
cat <<'EOF'
## 任务启动（前置门禁）
收到任何涉及代码修改的任务时，先检查 `.claude/specs/active.md`。
不存在则从 `.claude/specs/TEMPLATE.md` 创建，至少填写“涉及文件”和“验证命令”，再开始编辑。
一次性只读分析在回复开头注明“无规格任务”。
EOF

exit 0
