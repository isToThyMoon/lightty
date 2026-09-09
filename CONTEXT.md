# lightty 领域词汇

lightty 把可持续交接的工作、Agent 的对话历史与正在使用的终端现场分开表达。

## 导航与现场

**第一侧栏（Primary Sidebar）**：最左侧的资料导航，提供 Handoff 任务模式与 Sessions 会话模式；切换模式不改变已打开的终端现场。
_Avoid_：用“任务侧栏”泛指两种模式、左侧栏（无法区分两列）。

**第二侧栏（Secondary Sidebar）**：第一侧栏与终端主区之间的窗口导航，列出当前窗口的标签页及其终端。
_Avoid_：把第二侧栏叫会话列表。

**标签页（Tab）**：窗口内的一组终端现场，可以包含分屏。

**终端（Pane）**：标签页中的单个终端现场；Agent 会话可在其中运行，终端自身不是 Agent 会话。

**终端会话关联（Pane Session Association）**：终端指向一个确定 Agent 会话的关联，以 Agent 类型、配置根目录和原生会话 ID 共同标识；不以终端名、工作目录或任务名匹配。同一会话可以对应多个终端，侧栏选中态由当前聚焦终端的关联派生。

**任务绑定（Task Binding）**：终端指向一个 Handoff 文件的独立关联；一个任务可绑定多个终端，绑定或解绑不改变终端中的 Agent 会话。

**工作区快照（Workspace Snapshot）**：应用退出前窗口、标签页与终端现场的恢复记录。
_Avoid_：不加限定地称为“会话”（容易与 Agent 会话混淆）。

## 工作与会话

**Handoff 任务（Handoff Task）**：以交接文档保存目标、进展与下一步的长期工作条目，可以跨越多个 Agent 会话。
_Avoid_：将任务等同于某一次 Agent 对话。

**Agent 会话（Agent Session）**：由 Claude Code CLI 或 Codex CLI 保存在本机、可通过其原生恢复机制继续的对话历史；在 Sessions 模式中简称“会话”，不泛指 ChatGPT App、IDE 或云端记录。
_Avoid_：将已结束的会话等同于不能恢复的会话。

**恢复会话（Resume）**：使用原来的 Agent 继续其已保存的对话；不是读取 Handoff 文档后开启一段新对话。

**启动命令（Agent Command）**：新终端里敲下去的第一行命令，由 `AgentCommand` 统一表达——新建会话、handoff 启动任务、恢复会话、原生会话选择器、重启后恢复终端都构造它的一个 case，不各自拼字符串。设置页配的是意图（bypass 模式、附加参数），翻译成各 CLI 的参数写法只发生在这里。
_Avoid_：在建 pane 的地方直接写 `initialInput` 字符串。

**启动浮层（Launch Composer）**：开一个新终端前把四件事摆在一屏里决定——挂不挂任务、用哪个 Agent、在哪个目录、开到哪里（分屏 / 新标签页 / 新窗口）。三个入口（Sessions 新建会话、Handoff 新建任务、任务开始处理）是它的三组初值，不是三套界面。
_Avoid_：把它叫「任务弹窗」（会话模式也用它）、把「新建任务」当成只写文件的动作。

**项目（Project）**：lightty 在 Sessions 模式下提供的会话分组，可以同时收纳 Claude Code 与 Codex CLI 会话；不是标签页，也不等同于 Handoff 任务。

**组织数据（Organization）**：lightty 对项目、会话归属、排序、折叠和本地归档的管理记录；不包含 Agent 对话正文或终端现场。
_Avoid_：会话备份、工作区快照、会话目录缓存。

**移到项目（Move to Project）**：改变会话在 lightty 中的分组归属，不合并对话上下文，也不改变负责恢复它的 Agent。
_Avoid_：把整理进项目称为“归档”。

**归档（Archive in lightty）**：在 lightty 中将会话或整个项目从日常列表收起，保留其内容和找回能力；恢复项目保留分组。
_Avoid_：与 Agent 原生归档、删除会话混为一谈。

**来源归档（Source Archive）**：Agent 自己记录的历史归档状态，与 lightty 的项目归属及归档状态相互独立。

**已打开（Open in lightty）**：lightty 中存在对应终端现场的状态；不代表外部终端中是否也在运行该会话。
_Avoid_：仅凭磁盘更新时间称会话“运行中”。
