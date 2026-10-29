# Agent 会话操作：官方接口清单与 lightty 的用法

当前实现的接口边界见下表；初次调研基于 Codex 0.153.4 / Claude 2.1.266，后续后台路由已实现。
实际通过检查的 CLI 与 SDK 版本以 [兼容验证报告](../agent-compatibility.md) 为准。元数据写入测试使用临时配置根；活会话查询只读本机状态。

这份文档回答一个问题：**lightty 想对一段会话做某件事时，官方给了什么，我们用了什么，为什么剩下的没用。**
新增功能前先查这张表，不要先自己解析目录或者往终端里敲命令。

## 一句话结论

会话的**列表、删除、改名、占用**都只走官方接口：CLI 命令、官方开发包、`codex app-server`、钩子。
会话元数据与占用不读操作系统进程表 / 文件表反推。终端身份路由是独立职责：Codex 以进程事实关联 pane，见 [hooks 文档](../hooks.md#codex-共享后台进程)。

自己动手的只剩一处：**Claude 少数会话读不出工作目录**——开发包只看转录文件的头 64KB，
贴图开头的会话会漏掉，helper 往后多读一段。见「三、已知的接口坑」。

官方给不出答案的地方一律停在「问不出来」：codex 没有占用接口，它的会话就不标「在别处打开」，
删除时由 codex 自己的写锁把关。

## 一、lightty 已经在用的

| 要做的事 | Codex | Claude |
| --- | --- | --- |
| 列出会话 | 常驻 `codex app-server` 的 `thread/list`，设 `useStateDbOnly: true` 读取官方索引（`CodexSessionProvider` → `CodexAppServer`） | 开发包的 `listSessions`（`scripts/claude-session-helper/list-sessions.mjs`） |
| 读列表不列的会话（只给 pane 补标题） | 没有，列表就是全部 | 开发包的 `getSessionInfo`（`list-sessions.mjs --id <uuid>`，`ClaudeSessionProvider.unlistedSession`）：← 转后台换了会话 ID 之后，`listSessions` 把被接替的旧会话藏起来，pane 却可能还关联着它 |
| pane 正显示哪段后台会话 | `CodexSessionRouter` 旁听共享后台广播并匹配终端进程；见 hooks 文档 | `claude agents --json` + 终端标题（`ClaudeAgentView`，见 hooks 文档） |
| 删除会话 | `codex delete --force <id>`（`SessionDeletion`） | 开发包的 `deleteSession`（`delete-session.mjs`） |
| 改名（会话没开） | `thread/name/set`（`SessionRename`） | 开发包的 `renameSession`（`rename-session.mjs`） |
| 改名（会话开着） | 把 `/rename` 敲进那个终端（`AgentCommand.rename`） | 同左 |
| 恢复会话 / 打开选择器 | `codex resume [<id>]` | `claude --resume [<id>]` |
| 连上后台托管的会话（重启恢复、从侧栏打开） | 不适用 | `claude attach <短 ID>`（`SessionAttachPlan`）：`claude agents --json` 里是 `background` 行的会话；对它 `--resume` 会被拒绝 |
| 状态（思考中 / 工具 / 等你 / 完成） | 钩子（`HookInstaller`） | 钩子 |
| 判断会话是否已在别处打开 | 没有官方接口，一律不判断（`CodexSessionProvider.occupancy` 恒为「问不出来」） | `claude agents --json`（`ClaudeSessionProvider.occupancy`） |

### 目录查询与历史修复

日常目录查询设置 `useStateDbOnly: true`，分页、来源筛选、归档与标题字段保持相同。
该参数由本机 `ThreadListParams` schema 声明：默认查询会扫描 JSONL 并修复元数据；大历史目录
下可能超过请求超时，重建进程再次扫描，导致目录与依赖目录的 pane 标题持续不可用。
索引模式读取 Codex 已登记的会话；手工拷入但尚未被 Codex 索引的日志需先由 Codex 导入或修复，
lightty 不自行解析或修改其数据库。兼容检查同时核对参数并实际读取本机普通与归档目录的首页。

### 改名为什么分两条路

会话正开着的时候只能敲 `/rename`：从外面写进记录文件，那个**已经跑起来的进程不会重读**，它屏幕上还是旧标题。
会话没开就走接口，于是关着的会话第一次也能改名——以前必须先把会话开起来、还得等它空闲。

唯一给不了改名的情况是「开着、而且 agent 正在跑」：那一刻 PTY 前台是它的输出流，塞不进命令。

Codex 共享后台连接已订阅 `thread/name/updated`，自动命名与 `/rename` 都触发重读；
两家的终端标题变化也可触发刷新，并在 Stop 与开始下一轮提问时补查。标题真值来自官方目录，
不为会话操作监听私有记录文件。输出速度独立读取日志，不参与会话元数据操作。

**敲命令必须分两步**：先送文本，再单独按一次回车键（`TerminalSurfaceView.sendReturn()`）。
`sendText` 在 core 里走的是 `completeClipboardPaste`——它是粘贴，不是打字（`vendor/ghostty/src/apprt/embedded.zig` 的 `ghostty_surface_text` 注释写着这句）。
agent 的 TUI 开着括号粘贴模式，**粘进去的回车只是插入一个换行，不提交**，命令会原样停在输入框里。
换成 `\r` 也没用——问题不在换行符是 LF 还是 CR，在于整段走的是粘贴。
提交只能是一次真的按键，走 `ghostty_surface_key`，和用户自己按回车同一条路（所以用户配在回车上的绑定照样生效）。

### 状态为什么继续用钩子

钩子提供工具粒度的事件和 Handoff 上下文注入。Codex 已接入共享后台广播，用来补充等待用户、
回合完成与中断等事实；广播与钩子共同驱动状态，不意味着钩子可以整体移除。

### 占用检测为什么两家不一样

- Claude 自己维护着一张活会话表，`claude agents --json` 就是给脚本读的（帮助里写着 `for scripting; does not require a TTY`）。它直接给出 pid 与 sessionId 的对应，是这个问题的正面答案。核对过：lightty 自己 pane 里跑的 claude 也在这张表里。
- Codex 当前 provider 的占用接口仍返回「问不出来」，删除交给 CLI 写锁。虽然 Router 已旁听共享后台，已加载或 active 的 thread 不等于「哪个终端正在打开它」，不能直接当成外部占用的证明。

只用官方接口，不读操作系统的进程表 / 文件表反推（那要按进程名认 agent，而进程名随安装方式变）。
问不出来就是「问不出来」，绝不能当成「没人用」。

## 二、还没用、但以后要做相关功能时应该先看的

### Codex：从外面给一段会话排一条消息

`thread/queue/add`，命令行是 `codex queue --thread <UUID或会话名> --message <文本>`。
这是「handoff 派任务」那类功能的正经接口——不用再往终端里敲字。

当前 `CodexDaemonChannel` 已经通过 `codex app-server proxy` 连到原生 CLI 使用的共享后台，
`CodexSessionRouter` 使用会话生命周期、状态、完成及改名广播。它与列目录所用的独立
`CodexAppServer` 是两条连接；独立 app-server 的内存状态不能替代终端后台的状态。

消息排队、`turn/interrupt`、`turn/steer` 尚未作为 lightty 的控制路径接入；已有旁听连接不代表
这些写操作已验收。采用前仍需核对本机协议、目标会话归属与原生 TUI 行为，不能据历史调研
推断现在一定要修改启动方式。lightty 不负责起停用户共享后台。

### Claude：会话的其他操作

开发包里除了已经在用的三个，还有：

| 函数 | 作用 |
| --- | --- |
| `tagSession(id, tag)` | 给会话打一个标签，传 `null` 清掉 |
| `forkSession(id, { upToMessageId, title })` | 分叉出一段新会话，可以只截到某条消息为止 |
| `getSessionInfo(id)` | 单独读一段会话的元数据（标题、首条提问、目录、分支、时间）。已用于列表不列的会话，见上表 |

要做「给会话打标签 / 分叉」的时候直接用，不用自己写。都在已经打包的那个版本里，不新增依赖。

### 契约检查

用到的官方接口逐项写在 `Tests/LighttyTests/AgentContractTests.swift` 的表里：Codex 的 app-server 方法、
广播、字段、枚举值（对着本机 `codex app-server generate-json-schema` 的输出核），以及 `claude agents --json`
能否解码。升级后运行 [完整兼容检查](../agent-compatibility.md)；只核 schema 时可单跑 `swift test --filter AgentContractTests`。代码里新用到一项就加进表。
Claude 开发包的行为（含被接替的会话按 ID 仍读得到）由 `ClaudeSessionCatalogTests` 用合成转录核对。

### 生成协议定义

codex 的接口定义可以自己导出，不要照着网页硬编码字段：

```
codex app-server generate-ts --out <目录> --experimental
codex app-server generate-json-schema --out <目录> --experimental
```

导出的是**本机这个版本**的定义。升级 codex 后重新导一次，比对再改解码。

## 三、已知的接口坑

### `listSessions` 的工作目录只在文件头 64KB 里找

开发包给会话列表时，对每个转录文件只取**头 64KB 和末尾 64KB**两段来抽元数据
（`sdk.mjs` 里的 `Un = 65536`）：工作目录从头段里找 `cwd`，搬家记录从尾段里找
`relocated`。

用户第一句话里贴了图片时，第一条用户记录能有几百 KB，而 `cwd` 写在这条记录的
**末尾**——落在 64KB 窗口之外。这条会话于是拿不到工作目录，点开会弹「原会话目录
不存在」，把「没读出来」说成了「目录没了」。

实测（2026-09-09，本机 34 条会话）：

| 会话 | 文件大小 | 第一条带 `cwd` 的记录 | `cwd` 的绝对位置 | 结果 |
| --- | --- | --- | --- | --- |
| 贴图开头的两条 | 1.4MB / 63MB | 485KB / 623KB | 486191 | 读不到 |
| 其余 32 条 | 3KB ~ 141MB | ≤ 8KB | < 65536 | 正常 |

注意文件大小无关：141MB 的那条照样正常，因为它的 `cwd` 就在开头。

**lightty 的做法**（`scripts/claude-session-helper/list-sessions.mjs`）：开发包给不出
工作目录时，按会话号找到转录文件，往后多读一段，取第一条带 `cwd` 的记录。读到的是
CLI 自己写下的原值。

- **绝不从项目目录名反解**。`-Users-florian-project-ai-lightty` 这种编码不可逆——
  路径里本来就带连字符时还原不回去，猜出来的路径比留空更糟。
- 读取有上限：单个文件 8MB，整页 64MB。读坏了就当没有，列表照常出。
- 已知局限：会话中途搬过目录时，这里读到的是最初那个。那个目录若已不在，上层仍会
  让用户重新选，不会拿着错目录直接跑。

顺带：`getSessionInfo(id, { dir })` 的 `dir` 只是个**兜底值**——开发包读不到 `cwd`
时会把你传进去的 `dir` 原样回填。所以它不能用来「问出」目录，只会把你猜错的目录
确认一遍。

## 四、边界

- 会话目录接口只处理列表、标题、删除与占用，不加载会话或启动 agent；原生恢复与 attach 由启动流程负责，旁听连接由 Router 负责。
- 配置根一律显式传（`CODEX_HOME` / `CLAUDE_CONFIG_DIR`），不依赖默认值——用户可能配了自己的目录。
- 起的子进程一律去掉 `LIGHTTY_` 开头的环境变量：那是 pane 的钩子路由，工具进程不是 pane，绝不能继承。
- Codex app-server 区分稳定接口与 `experimentalApi` 门控接口；按本机导出的 schema 核对所用能力。字段存在性不能证明业务语义与时序不变，仍需行为验证。认不出的输出不能当成空表。

## 参考

- [Codex App Server](https://developers.openai.com/codex/app-server)
- [openai/codex：v2 协议里的 thread 定义](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs)
- [Claude Agent SDK：会话](https://platform.claude.com/docs/en/agent-sdk/sessions)
- 相邻文档：[会话来源调研](session-provider-research.md)、[开发包分发调研](claude-sdk-distribution-research.md)、[会话删除调研](../session-deletion-research.md)、[钩子](../hooks.md)
