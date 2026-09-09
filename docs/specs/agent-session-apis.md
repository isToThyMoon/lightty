# Agent 会话操作：官方接口清单与 lightty 的用法

日期：2026-09-09。证据来自本机安装的 `codex-cli 0.153.4`、`claude 2.1.266`，以及 lightty 已打包的官方开发包 `@anthropic-ai/claude-agent-sdk 0.3.263`。
所有验证都在临时的配置根里做，没有改动用户自己的会话。

这份文档回答一个问题：**lightty 想对一段会话做某件事时，官方给了什么，我们用了什么，为什么剩下的没用。**
新增功能前先查这张表，不要先自己解析目录或者往终端里敲命令。

## 一句话结论

会话的**列表、删除、改名**都有官方接口，lightty 全部走官方接口。
自己动手的有两处，都是官方给不出东西时的兜底：

- **codex 的「这段会话是不是已经在别处开着」**——那家没有对应接口，只能读操作系统的文件表。
- **Claude 少数会话读不出工作目录**——开发包只看转录文件的头 64KB，贴图开头的会话
  会漏掉。见「三、已知的接口坑」。

## 一、lightty 已经在用的

| 要做的事 | Codex | Claude |
| --- | --- | --- |
| 列出会话 | `codex app-server` 的 `thread/list`（`CodexSessionCatalog`） | 开发包的 `listSessions`（`scripts/claude-session-helper/list-sessions.mjs`） |
| 删除会话 | `codex delete --force <id>`（`SessionDeletion`） | 开发包的 `deleteSession`（`delete-session.mjs`） |
| 改名（会话没开） | `thread/name/set`（`SessionRename`） | 开发包的 `renameSession`（`rename-session.mjs`） |
| 改名（会话开着） | 把 `/rename` 敲进那个终端（`AgentCommand.rename`） | 同左 |
| 恢复会话 / 打开选择器 | `codex resume [<id>]` | `claude --resume [<id>]` |
| 状态（思考中 / 工具 / 等你 / 完成） | 钩子（`HookInstaller`） | 钩子 |
| 判断会话是否已在别处打开 | 读操作系统文件表（`SessionOccupancy`） | `claude agents --json` |

### 改名为什么分两条路

会话正开着的时候只能敲 `/rename`：从外面写进记录文件，那个**已经跑起来的进程不会重读**，它屏幕上还是旧标题。
会话没开就走接口，于是关着的会话第一次也能改名——以前必须先把会话开起来、还得等它空闲。

唯一给不了改名的情况是「开着、而且 agent 正在跑」：那一刻 PTY 前台是它的输出流，塞不进命令。

**敲命令必须分两步**：先送文本，再单独按一次回车键（`TerminalSurfaceView.sendReturn()`）。
`sendText` 在 core 里走的是 `completeClipboardPaste`——它是粘贴，不是打字（`vendor/ghostty/src/apprt/embedded.zig` 的 `ghostty_surface_text` 注释写着这句）。
agent 的 TUI 开着括号粘贴模式，**粘进去的回车只是插入一个换行，不提交**，命令会原样停在输入框里。
换成 `\r` 也没用——问题不在换行符是 LF 还是 CR，在于整段走的是粘贴。
提交只能是一次真的按键，走 `ghostty_surface_key`，和用户自己按回车同一条路（所以用户配在回车上的绑定照样生效）。

### 状态为什么继续用钩子

钩子是两家都正式提供的扩展点，**不是** hack，而且它给的粒度比任何只读接口都细。
只读的替代都更差：`claude agents --json` 只有忙 / 闲；codex 要先连上一个共用的后台服务才有状态变化通知。

### 占用检测为什么两家不一样

- Claude 自己维护着一张活会话表，`claude agents --json` 就是给脚本读的（帮助里写着 `for scripting; does not require a TTY`）。它直接给出 pid 与 sessionId 的对应，是这个问题的正面答案。核对过：lightty 自己 pane 里跑的 claude 也在这张表里。
- Codex 没有对等的东西。`codex agents` 要先有一个共用的后台服务（见下），而 lightty 是直接在终端里跑 codex，不连那个服务；不连的话 `thread/list` 里每一条的状态都是「未加载」。

读文件表这条路对两家都留着：Claude 那条命令可能因为版本旧、输出改格式而失败，失败时不能把「问不出来」当成「没人用」。

## 二、还没用、但以后要做相关功能时应该先看的

### Codex：从外面给一段会话排一条消息

`thread/queue/add`，命令行是 `codex queue --thread <UUID或会话名> --message <文本>`。
这是「handoff 派任务」那类功能的正经接口——不用再往终端里敲字。

**前提**：要连上共用的后台服务（`codex app-server daemon start`），并且那段会话本身是挂在这个服务下的（终端里用 `codex --remote <地址>` 启动）。
lightty 现在不是这么跑的，所以要用这条得先改启动方式。这一整块在 codex 里还标着 experimental。

同一套前提下还能拿到的东西：`thread/status/changed`、`turn/started`、`turn/completed` 这些通知，以及 `turn/interrupt`、`turn/steer`。
换句话说，**如果哪天决定挂到那个后台服务上，钩子那一整套是可以退休的**——但那是一次架构改动，不是一个函数。

**这一段没有验到底**：确认过后台服务能起来（`codex app-server daemon start` 返回 `{"status":"started"}`），也确认过不起它 `codex agents` 直接报连不上 socket；
但「终端用 `--remote` 挂上去、再从外面看到它的实时状态」这一整条没走通——直接跟控制 socket 说话被拒，前面应该还有一层握手，没继续查。
上面这些能力是从帮助文本和导出的协议定义推出来的，不是跑通的结论。真要做，第一步是先把这条路走通一次。

代价也要一起算：那个后台服务是**全机器一个**，不归 lightty 独有，起停会影响机器上别的用它的东西；
而且现在一个 pane 一个 codex 进程，崩一个只死一个 pane，挂上去之后那个服务倒了就是所有 pane 的 agent 一起没。

### Claude：会话的其他操作

开发包里除了已经在用的三个，还有：

| 函数 | 作用 |
| --- | --- |
| `tagSession(id, tag)` | 给会话打一个标签，传 `null` 清掉 |
| `forkSession(id, { upToMessageId, title })` | 分叉出一段新会话，可以只截到某条消息为止 |
| `getSessionInfo(id)` | 单独读一段会话的元数据（标题、首条提问、目录、分支、时间） |

要做「给会话打标签 / 分叉」的时候直接用，不用自己写。都在已经打包的那个版本里，不新增依赖。

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

- 这里的每一个接口都只碰**会话的元数据**：列表、标题、删除、占用。不加载会话、不启动 agent、不读会话正文。
- 配置根一律显式传（`CODEX_HOME` / `CLAUDE_CONFIG_DIR`），不依赖默认值——用户可能配了自己的目录。
- 起的子进程一律去掉 `LIGHTTY_` 开头的环境变量：那是 pane 的钩子路由，工具进程不是 pane，绝不能继承。
- codex 的 app-server 整体仍标着 experimental，不能对外宣传成永不变化。认不出的输出必须退化成「问不出来」，不能崩、也不能当成空表。

## 参考

- [Codex App Server](https://developers.openai.com/codex/app-server)
- [openai/codex：v2 协议里的 thread 定义](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/thread.rs)
- [Claude Agent SDK：会话](https://platform.claude.com/docs/en/agent-sdk/sessions)
- 相邻文档：[会话来源调研](session-provider-research.md)、[开发包分发调研](claude-sdk-distribution-research.md)、[会话删除调研](../session-deletion-research.md)、[钩子](../hooks.md)
