# Pane 状态与 Handoff 注入契约

安装、卸载和故障排查见 [Agent 状态 hooks](../hooks.md)。实时活动状态与任务文件 frontmatter 的 status 无关；后者仅作文件兼容保留。

## 1. 职责

状态不依赖任务绑定。Claude Code CLI / Codex CLI 的生命周期 hook 为 lightty 中的终端提供活动信号；Handoff 注入只对已绑定任务的终端执行。

## 2. 注册与生命周期

- lightty 在自己的 marketplace 中提供插件，通过 Agent 官方 CLI 注册，不自行合并用户 hook 配置文件。
- helper 是独立 lightty-hook executable，只依赖 Foundation / LighttyCore，不执行模型调用。
- 稳定入口 ~/.lightty/bin/lightty-hook 指向当前 app 内的 helper，启动时刷新。
- Codex hook trust 由用户与 Codex 管理，lightty 不绕过审核。

## 3. 数据流

终端启动时注入 LIGHTTY_PANE_ID 与 LIGHTTY_SOCK，shell、Agent、hook 沿进程树继承。
helper 将一事件一报文发往当前 lightty 实例的 Unix domain SOCK_DGRAM socket；PaneStatusStore 接收并在主线程更新状态。

每实例路径为 ~/.lightty/run/<pid>.sock。实时状态仅在内存，不写 status.json，不用目录 watcher 传输，不做持久化补发。
收包队列顺序解码，每次状态迁移交给主线程；UI 可按 runloop 合并重绘，不能在接收层压掉用于完成提醒的迁移。
无监听者或发送失败不应阻塞 Agent。报文不能用于证明外部终端的运行状态，多个发送者也不构成全局执行顺序证明。

## 4. 数据契约

### 4.1 运行时目录

- ~/.lightty/tasks/：Handoff 任务文件。
- ~/.lightty/panes/<uuid>/owner.pid：终端归属的 lightty 进程，供残留回收。
- ~/.lightty/panes/<uuid>/task：任务绝对路径，lightty 写、hook 读。
- ~/.lightty/panes/<uuid>/handoff.injected：上次注入的会话 ID 与任务路径。

终端解绑删除任务指针及注入标记；终端关闭移除运行时状态。工作区快照中的 Agent 身份用于重启恢复，不代表实时状态持久化。

### 4.2 报文

UTF-8 JSON，版本 v=1；信封含 pane UUID，载荷含 ts（ISO8601）、state，以及可选 agent、session_id、tool、detail、cwd、event。
单包上限与编解码校验以 LighttyCore/PaneStatus.swift 的 PaneStatusDatagram 为准。未知版本、畸形报文、已 detach 的 pane 均丢弃；detail 长度不可信，展示时截断。
原始 event 必须区分 SessionStart 与 SessionEnd，两者虽然同为 idle，自动恢复决策不同。

### 4.3 状态机

| 状态 | 触发事件 | 含义 |
| --- | --- | --- |
| idle | SessionStart / SessionEnd / Interrupt | 无活跃 turn |
| thinking | UserPromptSubmit / PostToolUse | turn 进行中 |
| tool | PreToolUse | 正在调用工具 |
| attention | Notification / PermissionRequest | 需要用户介入 |
| done | Stop | turn 完成、待用户查看 |

lightty 在用户下一次查看/交互或全部标记已读时清除 done：切入终端、重复聚焦、点击、
键盘/输入法输入、粘贴与滚动均走终端的统一交互事件，由 SessionLibrary 标记已读。
即使完成时终端已聚焦，也先保留提示，不在收到 Stop 时自动清除；其他 pane 的未读不受影响。
attention 与“是否已读”分开：点击、输入或全部标记已读只确认提醒，不把 Agent 的等待状态
改成 idle。文字与状态圆点保留，呼吸与待发通知停止；后续生命周期事件正常替换等待状态。
新的请求重新变为未读；相同请求报文的重复投递不重新点亮。已读信息只由应用在内存管理，
不写入 hook 报文或工作区快照。侧栏重建、切换标签页不丢失已读信息。
新收到的生命周期事件正常覆盖当前状态。hook 不判断用户是否已读。
未知 hook 事件不映射为已有状态。

## 5. 展示与线程

PaneStatusStore 在主线程使用，接收队列回到主线程后发布定向 lighttyPaneStatusDidChange；不复用会重建任务列表的通知。
终端头部、第二侧栏和菜单栏使用一致的状态语义；高频更新原地重绘，不改变终端名称布局。提醒与通知由各自展示逻辑处理。
动态颜色的 CGColor 快照在外观变化时重新解析；不可见终端不应持续运行动画。
第二侧栏行底色只表达选中/悬停，不表达完成未读。完成以圆点和“✓ 已完成”文字提示；
完成文字用完成强调色，“需要你”用橙色且不加前置符号；两者均为 11.5pt semibold，其他状态
保持 10.5pt medium。未读文字使用原生 NSTextField + NSAnimation 做 3.2 秒一周期的颜色呼吸，
最弱阶段保留 80% 状态强调色；动画不改字号、透明度或几何。
隐藏、移出窗口或窗口不可见时停止；“减弱动态效果”开启时保留静态强调色。

## 6. 验证

- fixture 验证所有事件映射、未知版本、畸形/超长报文、detach 后在途消息与多实例隔离。
- 临时 socket 验证真实 helper 发包、接收顺序与退出资源清理，不使用用户运行目录做测试。
- 真终端检查环境继承、CLI hook 注册、Codex trust、状态显示、完成提醒和通知定位。
- Handoff 注入验证先绑定后启动、先启动后绑定、改名、解绑再绑定、同一会话重复提交。
- Handoff 写回验证三条触发路径都真的落盘，且落盘内容遵守机械契约（只重写 frontmatter
  结束的 `---` 之后、刷新 `updated`、其余键不动）：
  - 面板里的「更新交接文档」：插件已装时敲的是技能调用且带上绝对路径；把插件卸掉或
    停在旧版本，敲的应当改为完整指令。两家各验一次——调用写法不同，且写错不报错。
  - 用户自然语言（“帮我总结下 handoff”）：模型自行调起技能。压缩过的长会话要单独验，
    那时路径已不在上下文里，技能应当从 `~/.lightty/panes/<pane-uuid>/task` 找回。
  - Agent 完成一大段工作后主动问、用户点头后写回。
- Handoff 写回的拒绝路径同样要验：Agent 处于 thinking / tool 时那一行置灰、鼠标与键盘
  都点不动；面板开着期间转忙后再点，列表不关且该行当场变灰。

## 8. Handoff 注入

helper 在 SessionStart 读取已绑定任务，通过 hookSpecificOutput.additionalContext 注入正文与任务地址。
UserPromptSubmit 补处理晚绑定与改名；handoff.injected 按 session ID + 路径去重，同一组合不重复注入，解绑清除标记。

### 8.1 注入文本

注入文本由 LighttyCore/HandoffProtocol.swift 渲染，不在 helper 内手写；插件里的
skills/handoff/SKILL.md 与设置页展示取自同一常量，三处的机械契约与写作规矩逐字相同。
改 Agent 收到的措辞只改该常量，其余两处自动跟随。

两版差别只在开头两段。SessionStart 时上下文为空，直接摆出文档并指向 Next steps 节。
UserPromptSubmit 时 Agent 可能已在做别的事，且这段文字与用户当轮输入一同送入，因此
要交代两件事：用户当前请求优先、本文档作背景；本次注入取代本段会话中同一任务的早先
副本——改名会更换路径，同一文档的两个版本会先后进入同一段上下文。

注入的是任务文件全文，含 frontmatter。“只重写 frontmatter 结束的 --- 之后”这条要求
需要 Agent 对着实物看，只给正文会让它引用一个看不见的边界。

### 8.2 写回

上下文注入不等于自动生成或写回总结。写入始终由用户点头；Agent 可以主动问，不能自行
落盘。三条触发路径通向同一份做法：

- 面板里的「更新交接文档」：不是终端头部的按钮，是从头部胶囊打开的 identity panel 里、
  任务列表底部的一行，与改名、解绑并排。插件已装且非旧版时敲技能调用，否则敲入完整指令。
  两个显示条件缺一不可——绑定了任务，且该终端能认出跑的是哪家 Agent
  （`displayedSessionKey != nil`）：两家调用写法不同，认不出就无从决定敲什么，猜错是静默
  失败，所以整行不出现而不是置灰。Agent 处于 thinking / tool 时置灰并给出理由，那一刻向
  PTY 注入会打乱它自己的输入；置灰行不接受鼠标点击，也不接受键盘高亮与回车。
  行的状态在列表重建时算得，面板开着期间 Agent 可能转忙，因此发送前会再验一次；
  没送出去就重建那一行让它当场变灰，而不是关掉列表假装做过。
- 用户自然语言（“帮我总结下 handoff”）：模型自行调起技能；插件未装则走注入文本里的
  写回契约，结果相同。
- Agent 判断完成了一大段工作后问一句，用户点头后写回。

技能随插件装给两家，skills/handoff/SKILL.md 一份文件共用，SKILL.md 不写
disable-model-invocation——那会切断上面第二条路径，且 Codex 的插件校验器要求该字段不为
true。调用写法两家不同：Claude Code 用 /<插件名>:<技能名>，Codex 用 $<插件名>:<技能名>；
两家都按插件名加前缀，裸技能名不生效。调用名写错或插件未装都是静默失败，不报错也不
执行，因此按钮走技能这条路之前必须先确认插件已装。

启动浮层由 LaunchComposer 提供，选择 Agent、工作目录与分屏 / 新标签页 / 新窗口；已打开位置可直接前往。Sessions 模式的原生恢复不自动绑定任务或额外注入 Handoff。
