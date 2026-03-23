# OpenCode Context Window 优化策略分析

本文档深入分析 OpenCode 项目在 Context Window / Context Engine 方面的优化策略和实现细节。

## 目录

1. [架构概览](#1-架构概览)
2. [Token 预算管理](#2-token-预算管理)
3. [自动 Compaction（上下文压缩）](#3-自动-compaction上下文压缩)
4. [Tool Output Pruning（工具输出裁剪）](#4-tool-output-pruning工具输出裁剪)
5. [Tool Output Truncation（工具输出截断）](#5-tool-output-truncation工具输出截断)
6. [文件读取的上下文控制](#6-文件读取的上下文控制)
7. [Provider 级别的 Prompt Caching](#7-provider-级别的-prompt-caching)
8. [子任务委托（Task Tool）](#8-子任务委托task-tool)
9. [消息过滤与转换](#9-消息过滤与转换)
10. [Instruction Prompt 去重](#10-instruction-prompt-去重)
11. [Provider 特定适配](#11-provider-特定适配)
12. [Doom Loop 检测](#12-doom-loop-检测)
13. [配置项](#13-配置项)

---

## 1. 架构概览

OpenCode 的 Context Window 管理采用多层防御策略，从输入端到输出端层层控制 token 消耗：

```
用户输入
  │
  ├─ System Prompt（provider 特定 + 环境信息 + AGENTS.md 指令）
  │
  ├─ 消息历史 ← filterCompacted() 过滤已压缩的消息
  │     │
  │     ├─ 已压缩的 tool output → "[Old tool result content cleared]"
  │     └─ compaction 断点之前的消息被丢弃
  │
  ├─ Tool 输出 ← Truncate.output() 截断（2000行/50KB）
  │
  └─ LLM 调用
       │
       ├─ maxOutputTokens 限制（默认 32K）
       ├─ Prompt Caching（Anthropic/Bedrock）
       └─ 溢出检测 → 触发 Compaction
```

核心文件：
- `src/session/compaction.ts` — 上下文压缩
- `src/session/prompt.ts` — 主循环与上下文构建
- `src/session/processor.ts` — 流处理与溢出检测
- `src/session/message-v2.ts` — 消息过滤与模型消息转换
- `src/tool/truncation.ts` — 工具输出截断
- `src/provider/transform.ts` — Provider 适配与缓存
- `src/session/llm.ts` — LLM 调用层
- `src/util/token.ts` — Token 估算

## 2. Token 预算管理

### 2.1 Token 估算

OpenCode 使用轻量级的字符比率估算，而非精确的 tokenizer：

```ts
// src/util/token.ts
const CHARS_PER_TOKEN = 4
export function estimate(input: string) {
  return Math.max(0, Math.round((input || "").length / CHARS_PER_TOKEN))
}
```

这种方式牺牲了精度换取速度，避免了加载 tokenizer 的开销。

### 2.2 溢出检测

`SessionCompaction.isOverflow()` 在每个 step 完成后检查是否超出上下文窗口：

```ts
// src/session/compaction.ts
export async function isOverflow(input) {
  const context = input.model.limit.context   // 模型总上下文窗口
  const count = input.tokens.input + input.tokens.cache.read + input.tokens.output
  const output = Math.min(input.model.limit.output, OUTPUT_TOKEN_MAX) || OUTPUT_TOKEN_MAX
  const usable = input.model.limit.input || context - output
  return count > usable
}
```

关键逻辑：
- 可用上下文 = `model.limit.input`（如果有）或 `context - output`
- 输出 token 上限默认 32,000（可通过 `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` 调整）
- 当 `input + cache_read + output > usable` 时触发 compaction

### 2.3 Token 分桶追踪

每次 LLM 调用后，token 被分为 5 个桶独立追踪：

```ts
tokens = {
  input,           // 实际输入 token
  output,          // 输出 token
  reasoning,       // 推理 token（如 Claude thinking）
  cache: {
    read,          // 缓存命中的 token
    write,         // 写入缓存的 token
  }
}
```

成本计算支持 200K+ token 的差异化定价：

```ts
const costInfo = tokens.input + tokens.cache.read > 200_000
  ? input.model.cost.experimentalOver200K
  : input.model.cost
```

## 3. 自动 Compaction（上下文压缩）

当检测到上下文溢出时，OpenCode 会自动触发 compaction 流程。

### 3.1 触发时机

在 `processor.ts` 的 `finish-step` 事件中：

```ts
if (await SessionCompaction.isOverflow({ tokens: usage.tokens, model })) {
  needsCompaction = true
}
```

以及在 `prompt.ts` 的主循环中：

```ts
if (lastFinished && !lastFinished.summary &&
    await SessionCompaction.isOverflow({ tokens: lastFinished.tokens, model })) {
  await SessionCompaction.create({ sessionID, agent, model, auto: true })
}
```

### 3.2 Compaction 流程

1. 创建一个特殊的 user message，包含 `compaction` part
2. 使用专用的 "compaction" agent 生成摘要
3. 摘要 prompt 要求 LLM 提供：
   - 已完成的工作
   - 当前正在进行的工作
   - 正在修改的文件
   - 下一步计划
   - 关键用户偏好和技术决策
4. 生成的摘要作为 `summary: true` 的 assistant message 存储
5. 后续请求通过 `filterCompacted()` 过滤掉 compaction 断点之前的消息

### 3.3 消息过滤

`filterCompacted()` 从最新消息向前遍历，遇到 compaction 断点就停止：

```ts
export async function filterCompacted(stream) {
  const result = []
  const completed = new Set()
  for await (const msg of stream) {
    result.push(msg)
    // 如果遇到已完成 compaction 的 user message，停止
    if (msg.info.role === "user" && completed.has(msg.info.id) &&
        msg.parts.some(part => part.type === "compaction"))
      break
    if (msg.info.role === "assistant" && msg.info.summary && msg.info.finish)
      completed.add(msg.info.parentID)
  }
  result.reverse()
  return result
}
```

### 3.4 Plugin 扩展

Compaction 支持通过 plugin 自定义：

```ts
const compacting = await Plugin.trigger(
  "experimental.session.compacting",
  { sessionID },
  { context: [], prompt: undefined },
)
```

插件可以注入额外上下文或完全替换 compaction prompt。

## 4. Tool Output Pruning（工具输出裁剪）

Pruning 是一种更细粒度的上下文优化，在 compaction 之外独立运行。

### 4.1 策略

```ts
// src/session/compaction.ts
export const PRUNE_MINIMUM = 20_000   // 至少裁剪 20K token 才执行
export const PRUNE_PROTECT = 40_000   // 保护最近 40K token 的工具输出
```

从最新消息向前遍历，跳过最近 2 轮对话，累计 tool output 的 token 数：
- 前 40K token 的工具输出受保护
- 超过 40K 的部分标记为可裁剪
- 只有可裁剪总量超过 20K 时才执行

### 4.2 裁剪方式

被裁剪的 tool output 不会被删除，而是标记 `time.compacted` 时间戳。在构建模型消息时：

```ts
// src/session/message-v2.ts toModelMessages()
const outputText = part.state.time.compacted
  ? "[Old tool result content cleared]"
  : part.state.output
```

### 4.3 保护机制

- 最近 2 轮对话的工具输出不会被裁剪
- `skill` 类型的工具输出受保护（`PRUNE_PROTECTED_TOOLS`）
- 已有 `summary` 标记的消息之前的内容不会被处理

### 4.4 执行时机

在主循环结束后执行：

```ts
// src/session/prompt.ts loop() 末尾
SessionCompaction.prune({ sessionID })
```

## 5. Tool Output Truncation（工具输出截断）

所有工具的输出都经过统一的截断处理。

### 5.1 限制参数

```ts
// src/tool/truncation.ts
export const MAX_LINES = 2000    // 最大行数
export const MAX_BYTES = 50 * 1024  // 最大 50KB
```

### 5.2 截断流程

1. 检查输出是否超过行数或字节限制
2. 如果超过，按行截取（支持 head/tail 两种方向）
3. 将完整输出保存到磁盘（`~/.local/share/opencode/tool-output/`）
4. 返回截断后的内容 + 提示信息

### 5.3 智能提示

截断后的提示会根据 agent 是否有 Task tool 权限而不同：

```ts
// 有 Task tool 权限时
"Use the Task tool to have explore agent process this file with Grep and Read.
 Do NOT read the full file yourself - delegate to save context."

// 没有 Task tool 权限时
"Use Grep to search the full content or Read with offset/limit to view specific sections."
```

### 5.4 自动清理

截断文件有 7 天的保留期，通过 Scheduler 每小时清理：

```ts
Scheduler.register({
  id: "tool.truncation.cleanup",
  interval: HOUR_MS,
  run: cleanup,
  scope: "global",
})
```

### 5.5 Tool 级别的自动截断

`Tool.define()` 包装器自动对所有工具输出应用截断：

```ts
// src/tool/tool.ts
const truncated = await Truncate.output(result.output, {}, initCtx?.agent)
return {
  ...result,
  output: truncated.content,
  metadata: { ...result.metadata, truncated: truncated.truncated },
}
```

工具可以通过在 metadata 中设置 `truncated` 字段来跳过自动截断。

## 6. 文件读取的上下文控制

`ReadTool` 实现了多层上下文控制。

### 6.1 分页读取

```ts
const DEFAULT_READ_LIMIT = 2000   // 默认读取 2000 行
const MAX_LINE_LENGTH = 2000      // 单行最大 2000 字符
const MAX_BYTES = 50 * 1024       // 最大 50KB
```

支持 `offset` 和 `limit` 参数进行分页读取，避免一次性加载大文件。

### 6.2 行号标注

输出带有行号前缀，方便 LLM 精确引用：

```
00001| import { foo } from "./bar"
00002| ...
```

### 6.3 二进制文件检测

通过扩展名和内容分析（>30% 非打印字符）检测二进制文件，避免无意义的上下文消耗。

### 6.4 图片/PDF 处理

图片和 PDF 文件转为 base64 附件，而非文本内容，利用模型的多模态能力。

## 7. Provider 级别的 Prompt Caching

### 7.1 缓存标记策略

`applyCaching()` 对 system prompt 和最近 2 条消息添加缓存标记：

```ts
function applyCaching(msgs, providerID) {
  const system = msgs.filter(msg => msg.role === "system").slice(0, 2)
  const final = msgs.filter(msg => msg.role !== "system").slice(-2)

  // 对这些消息添加 cacheControl/cachePoint 标记
  for (const msg of unique([...system, ...final])) {
    msg.providerOptions = mergeDeep(msg.providerOptions, providerOptions)
  }
}
```

### 7.2 多 Provider 支持

缓存标记适配不同 provider 的格式：

| Provider | 缓存字段 |
|----------|---------|
| Anthropic | `cacheControl: { type: "ephemeral" }` |
| Bedrock | `cachePoint: { type: "default" }` |
| OpenRouter | `cacheControl: { type: "ephemeral" }` |
| OpenAI Compatible | `cache_control: { type: "ephemeral" }` |
| Copilot | `copilot_cache_control: { type: "ephemeral" }` |

### 7.3 System Prompt 结构优化

System prompt 被分为 2 部分以最大化缓存命中率：

```ts
// src/session/llm.ts
// 如果 header 未变，保持 2 部分结构以利用缓存
if (system.length > 2 && system[0] === header) {
  const rest = system.slice(1)
  system.length = 0
  system.push(header, rest.join("\n"))
}
```

第一部分（provider prompt）相对稳定，第二部分（环境信息 + 指令）可能变化。这样第一部分可以持续命中缓存。

## 8. 子任务委托（Task Tool）

Task Tool 是 OpenCode 最重要的上下文优化手段之一。

### 8.1 核心思想

将复杂任务委托给子 agent，子 agent 在独立的 session 中运行，拥有自己的上下文窗口。主 agent 只接收最终的文本摘要，而非完整的工具调用历史。

### 8.2 上下文隔离

```ts
// src/tool/task.ts
const session = await Session.create({
  parentID: ctx.sessionID,  // 关联父 session
  title: params.description + ` (@${agent.name} subagent)`,
})
```

子 session 有独立的消息历史和上下文窗口，不会污染主 session。

### 8.3 结果压缩

子任务完成后，只返回最终文本和元数据摘要：

```ts
const output = text + "\n\n" + [
  "<task_metadata>",
  `session_id: ${session.id}`,
  "</task_metadata>"
].join("\n")
```

工具调用的详细输出被压缩为简短的摘要列表。

### 8.4 截断提示中的委托建议

当工具输出被截断时，系统会建议使用 Task tool 委托处理：

```
"Use the Task tool to have explore agent process this file with Grep and Read.
 Do NOT read the full file yourself - delegate to save context."
```

## 9. 消息过滤与转换

### 9.1 错误消息过滤

有错误的 assistant 消息会被跳过，除非它们包含有意义的内容：

```ts
if (msg.info.error && !(
  MessageV2.AbortedError.isInstance(msg.info.error) &&
  msg.parts.some(part => part.type !== "step-start" && part.type !== "reasoning")
)) {
  continue  // 跳过纯错误消息
}
```

### 9.2 中断的工具调用处理

pending/running 状态的工具调用被转换为错误结果，避免 API 报错（特别是 Anthropic 要求每个 tool_use 必须有对应的 tool_result）：

```ts
if (part.state.status === "pending" || part.state.status === "running")
  assistantMessage.parts.push({
    state: "output-error",
    errorText: "[Tool execution was interrupted]",
  })
```

### 9.3 队列消息包装

当用户在 agent 处理过程中发送新消息时，这些消息会被包装在 `<system-reminder>` 标签中：

```ts
if (step > 1 && lastFinished) {
  part.text = [
    "<system-reminder>",
    "The user sent the following message:",
    part.text,
    "Please address this message and continue with your tasks.",
    "</system-reminder>",
  ].join("\n")
}
```

## 10. Instruction Prompt 去重

### 10.1 层级化指令加载

指令文件（AGENTS.md、CLAUDE.md 等）按层级加载：
- 全局级：`~/.config/opencode/AGENTS.md`
- 项目级：项目根目录的 AGENTS.md
- 目录级：当文件被读取时，加载该文件所在目录链上的 AGENTS.md

### 10.2 去重机制

`InstructionPrompt` 使用 claim 机制避免重复加载：

```ts
// 每个 messageID 维护一个已加载文件的 Set
function claim(messageID, filepath) {
  let claimed = current.claims.get(messageID)
  if (!claimed) { claimed = new Set(); current.claims.set(messageID, claimed) }
  claimed.add(filepath)
}
```

同时追踪已通过 Read tool 加载的指令文件：

```ts
export function loaded(messages) {
  // 遍历所有 read tool 的结果，收集已加载的指令文件路径
  for (const msg of messages) {
    for (const part of msg.parts) {
      if (part.type === "tool" && part.tool === "read" && part.state.status === "completed") {
        if (part.state.time.compacted) continue  // 跳过已裁剪的
        const loaded = part.state.metadata?.loaded
        // ...
      }
    }
  }
}
```

## 11. Provider 特定适配

### 11.1 消息格式标准化

`ProviderTransform.normalizeMessages()` 针对不同 provider 做适配：

| Provider | 适配内容 |
|----------|---------|
| Anthropic | 过滤空内容消息、清理 tool call ID 中的特殊字符 |
| Mistral | tool call ID 标准化为 9 位字母数字、tool 消息后插入 assistant 消息 |
| 支持 interleaved 的模型 | 将 reasoning 部分提取到 providerOptions 中 |

### 11.2 不支持的模态处理

当模型不支持某种输入模态（图片、音频等）时，自动替换为错误提示文本：

```ts
return {
  type: "text",
  text: `ERROR: Cannot read ${name} (this model does not support ${modality} input). Inform the user.`,
}
```

### 11.3 输出 Token 限制

`maxOutputTokens()` 根据 provider 和模型配置动态计算：

```ts
// Anthropic thinking 模式下的特殊处理
if (enabled && budgetTokens > 0) {
  // text + thinking <= model cap
  if (budgetTokens + standardLimit <= modelCap) return standardLimit
  return modelCap - budgetTokens
}
```

## 12. Doom Loop 检测

防止 LLM 陷入重复调用同一工具的死循环：

```ts
// src/session/processor.ts
const DOOM_LOOP_THRESHOLD = 3

const lastThree = parts.slice(-DOOM_LOOP_THRESHOLD)
if (lastThree.length === DOOM_LOOP_THRESHOLD &&
    lastThree.every(p =>
      p.type === "tool" &&
      p.tool === value.toolName &&
      p.state.status !== "pending" &&
      JSON.stringify(p.state.input) === JSON.stringify(value.input)
    )) {
  // 触发 doom_loop 权限检查
  await PermissionNext.ask({ permission: "doom_loop", ... })
}
```

当连续 3 次使用相同参数调用同一工具时，触发权限检查，避免无意义地消耗上下文。

## 13. 配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `compaction.auto` | `true` | 是否启用自动 compaction |
| `compaction.prune` | `true` | 是否启用 tool output pruning |
| `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` | `32000` | 最大输出 token 数 |
| `snapshot` | `true` | 是否启用 git snapshot 追踪 |
| `experimental.continue_loop_on_deny` | `false` | 权限拒绝后是否继续循环 |

---

## 总结

OpenCode 的 Context Window 优化是一个多层协作的系统：

1. **预防层**：Tool output truncation（50KB/2000行）、文件分页读取、二进制检测
2. **运行时层**：Prompt caching（减少重复计算）、子任务委托（隔离上下文）
3. **事后层**：Tool output pruning（清理旧工具输出）、自动 compaction（生成摘要替代完整历史）
4. **适配层**：Provider 特定的消息格式化、缓存策略、输出限制

这些策略共同确保了在长对话中 LLM 始终能获得最相关的上下文，同时控制 token 消耗和成本。
