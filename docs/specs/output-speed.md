# 输出速度与侧栏小精灵

## 目标与边界

在第二侧栏底部固定的一行中，显示当前聚焦终端里 Agent 最近几次模型请求的输出速度，帮助用户发现
模型变慢。数字有明确含义：**输出 token 数 ÷ 从发出请求到这次响应写完的时间**，包含首 token
等待与网络，不是纯解码速度，也不是服务器评分。悬停说明写明这一点，并给出最近一次请求的
token 数与用时。

数据只来自 Agent 自己写在本机的会话日志，不改 Agent 的命令、环境、配置或网络请求，不起代理。
两家都在一次请求结束后才写出完整用量，所以数值**按请求更新**，同一次请求生成过程中不跳动；
一次请求很长（一次写几千 token）时，中间数字不变。要逐 token 的实时值只能截流，不在本方案内。

## 日志从哪来

hook 载荷的官方字段 `transcript_path` 随状态报文发给 app（`PaneStatus.transcriptPath`，
超过 1KB 不发）。`PaneStatusStore` 按 pane 记住最近一次报的路径，pane 换了会话就不再给。
不扫描 `~/.claude/projects`、`~/.codex/sessions` 去猜哪个文件。hook 没装、旧版 hook 不发这个字段时，
速度计不显示。

## 计算

格式按家写在 `AgentSpec.transcriptFormat`，解析在 `TranscriptSpeedParser`。认不出的行跳过，
缺起点的请求不出样本。

- **Claude transcript**：请求发出时立即写一条 `api-request`（只认 `querySource` 为空或
  `repl_main_thread`，标题生成等旁路请求不算）。一条消息写完时，各内容块各写一行，带各自的完成时间
  与同一份 `usage.output_tokens`。起点取最近的 `api-request` 或 `user` 行，终点取同一消息 id 的
  最后一块。`isSidechain` 的行、`<synthetic>` 消息不算。依据：2.1.310 实测，所有块在消息完成时
  一起落盘，`api-request` 落盘晚于发出约 0.1 秒。
- **Codex rollout**（0.164.0 实测）：推理、回复、工具调用逐项写出，每次请求结束写一条 `token_usage_record`
  （`usage.output_tokens`）。起点取最近的 `task_started`、用户消息、`*_output` 工具输出或上一条
  `token_usage_record` 中最晚的一个。Codex 会在响应收尾前就执行工具，响应已写出推理 / 回复 /
  工具调用之后、用量记录之前落盘的工具输出不算新起点，否则用时被砍短、速度虚高（本机现有日志
  尚未出现这种顺序，属防御）。只认 `token_usage_record`，旧版只有 `token_count` 时不显示。
- **思考不漏算**：Claude 的 `output_tokens` 已含思考，明细在 `output_tokens_details.thinking_tokens`；
  Codex 766 条记录全部满足 `total = input + output`，`reasoning_output_tokens` 是 `output_tokens` 的一部分。
  两家都按 `output_tokens` 计，思考单列在悬停说明里。
- **正文字符**：Claude 累加同一消息的 `text` 块，Codex 累加这次请求的 assistant 消息文字；
  不含思考与工具调用参数。字符/秒只算写了正文的请求。同一段中文两家分词器切出的 token 数相差
  可达 2 倍以上（2026-10-26 实测：Claude 1904 字符 1826 token 含思考 165，Codex 1205 字符 788 token），
  跨 Agent 比较看字符/秒，tok/s 只适合看同一模型有没有变慢。
- **窗口**：最近 5 次请求合计输出 ÷ 合计用时，长请求权重大。少于 32 个 token 的请求几乎全是
  首 token 等待，不计入。同一消息的多行按 id 去重。

Codex 的 OTel 指标 `codex.responses_api_engine_service_tbt.duration_ms` 能给出服务端解码间隔，
但要用户在 Codex 配置里开 OTLP 导出、lightty 起接收端，数据也是每次响应一个值，暂不采用。

## 读取与性能

- `TranscriptTail` 只读、增量跟随一个文件：首次只读末尾 1MB 并从下一行开始，之后只读新追加的
  完整行。文件变短（被重写）或一次追加超过 8MB 时，从末尾 1MB 重新起步，宁可丢样本也不阻塞；
  单行超过 16MB 丢弃。行先按 `type` 键和值做字节预筛（容忍冒号两侧的 JSON 空白），再解码只含所需字段的结构；序列化器加空格不会改变读数。
- `AgentOutputMeterView` 在 key 窗口可见、第二侧栏可见、聚焦终端有 hook 绑定的 Agent 会话且有路径时，
  每秒轮询一次；读取与解析在专用 utility 队列上，主线程只渲染。
- 2026-10-26 本机 release 构建：2.0MB 的 Claude transcript 全量解析约 12ms，8.7MB 的 Codex rollout
  约 29ms；首次读取末尾 1MB 约 4ms。

## 展示

沿用侧栏颜色和字体，不加卡片、边框或工具栏，不改变终端内容尺寸。显示 `N tok/s`，等宽数字。
悬停说明另给正文字符/秒，以及最近一次请求的 token（含思考多少）、正文字符数与用时。
读到了日志但还没有够长的请求时显示 `– tok/s`，悬停说明原因（短回复不计入）；没有日志路径时只显示静止的小精灵；普通 shell 不显示。小精灵按 Agent 取形象（`AgentSpec.sprite` 像素点阵，逐格画方块）：Claude 是橙色像素小生物，Codex 是蓝色小机器人，都是致敬各家风格的原创图案，不复刻官方吉祥物轮廓；认不出的 Agent 用中性小团子。小精灵只在 Agent 处于 thinking 且有读数时轻微起伏、两组小脚交替踩步，
速度不驱动动画频率；尊重系统「减少动态效果」。窗口失焦、被遮挡、侧栏关闭时停止轮询及动画。
位置固定在第二侧栏底部，不随第一侧栏开合移动（顶部在第一侧栏收起后归窗口三键）。

## 验收与已验证范围

1. `TranscriptSpeedTests`：两家的行形状（照本机日志裁剪）、旁路请求与子 Agent、中段起读、窗口去重与
   容量、增量读取、截断重读、大文件起读。
2. 本机真实日志（2026-10-26）：Claude Code 2.1.310 本会话 65 次请求，单次中位数约 73 tok/s；
   Codex 0.164.0 最近一个会话 269 次请求，中位数约 16 tok/s。Codex 单次输出多在 100 token 上下，
   首 token 等待占了大部分时间，所以显著偏低。这是如实测量的结果，不做校正。
3. 侧栏截图走 `LIGHTTY_UI_SNAPSHOT_DIR`，检查最窄侧栏、深浅外观和无读数状态。

局限：日志格式是两家的私有实现，见[依赖清单](../agent-dependencies.md#输出速度)。没有和服务端
计量做过对照。
