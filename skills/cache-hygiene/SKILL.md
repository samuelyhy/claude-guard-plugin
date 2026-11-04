---
name: cache-hygiene
description: Cache and session hygiene rules for Claude Code. Use when deciding whether to /clear or /compact, when choosing a model or effort level, or when discussing token and cache cost. The spec-first task startup gate is injected by the SessionStart hook, not carried here.
---

# 缓存卫生与会话卫生

## 任务启动（由 SessionStart hook 注入）

判据正文不再写在这里：每次会话开始时 `scripts/session-start-inject.sh` 会确定性注入
「任务启动（前置门禁）」，避免“skill 没触发 = 规则不存在”。这里只保留两条正文没覆盖的解释：

- **「无规格任务」是一句审计痕迹。** 主动写出来，事后能看到“这里主动跳过了”；
  不写就等于“悄悄没管”。一次性只读分析不是违规，隐瞒才是。
- **过期的 `active.md` 比没有更糟。** 留着一份上个任务的规格，会拿旧文件面去管新任务，
  产生最严重的一类误报（合法改动被拦）。规格用完就删掉或改回模板状态。

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
