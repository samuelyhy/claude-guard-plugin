---
name: cache-hygiene
description: Cache and session hygiene rules for Claude Code, plus the spec-first task startup gate. Use when starting any code-modification task, when deciding whether to /clear or /compact, when choosing a model or effort level, or when discussing token and cache cost.
---

# 缓存卫生与会话卫生

## 任务启动（每轮开工先过这一关）

如果项目里有 `.claude/specs/`（或规格门禁 hooks），收到任何**涉及代码修改**的任务时：

- 先看 `.claude/specs/active.md` 在不在。
- 不在 → 从 `.claude/specs/TEMPLATE.md` 复制一份，**至少填「涉及文件」和「验收标准」两节**，
  然后再开始编辑。没填完就动手 = 门禁等于不存在。
- 任务确实是一次性探索 / 只读分析 → **在回复开头写「无规格任务」**，门禁按 fail-open 放行。
  这句话是审计痕迹：事后能看到「这里主动跳过了」，而不是「这里悄悄没管」。
- 规格用完了就删掉或改回模板状态。留着一份过期的 `active.md` 会拿上一个任务的文件面
  去管下一个任务 —— 那是最糟糕的一种误报。

## 缓存卫生（Cache Hygiene）

缓存读（`cache_read`）是便宜层，不是敌人；真正的浪费是把**本可留在缓存里的前缀推去重建**。
所以下面几条是硬约束，不是建议：

- **模型与 effort 在会话开始时定死。** 会话中途不切 `model` / `effortLevel` / thinking ——
  这些渲染在 prompt 前缀里，中途改一次等于把整个前缀重新计费一次。
  要换档就开新会话（换档本身就是任务边界）。
- **离开前先 `/compact`。** 缓存 TTL 是 1 小时；超过 TTL 再 compact，会以**未缓存**的输入
  重新处理全部历史。趁缓存还热时压缩，比冷着压缩便宜一个量级。
- **任务边界才 `/clear`。** `/clear` 在任务之间是安全的（下一个任务本来就不共享前缀）；
  但在**同一任务中途**用别的方式「重置上下文」只会制造新的 cache 写入。
- **不要中途改 CLAUDE.md。** 它在会话开始就被加载进前缀；编辑它对**当前**会话不生效
  （也救不了缓存），只影响下一个会话。改它 = 开新会话再改。

## 会话卫生

- **不同任务之间 `/clear`。** 上一个任务的无关上下文不该随新任务继续发送。
- **引用文件用 @-mention（`@path/to/file`），别让 agent 自己搜。** 少一次 Read，
  而且 Read 进来的内容会在会话剩余每一轮里被反复 cache_read —— 这才是它的真实成本。
- **测试/构建/日志命令加 quiet 参数**（`pytest -q`、`vitest --reporter=dot`、`pnpm -s`），
  大输出交给子代理。命令输出进入对话后会一直留到会话结束。
- **子代理只收「目标 + 精确路径:行 + 验收命令 + 禁止事项」。** 不要往委派消息里贴整份文件、
  也不要贴「之前我们讨论了什么」。
- **子代理的输出越短越好，但不能短到让父代理重新读文件。** 判断标准不是字数，
  是父代理有没有因为缺信息而二次 Read —— 有的话这次压缩是净亏损。
