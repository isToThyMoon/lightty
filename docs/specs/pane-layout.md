# pane 排布与移动

术语见 [CONTEXT.md](../../CONTEXT.md)。本文说明标签页内 pane 怎么排布、怎么在标签页和窗口之间移动，以及侧栏拖拽怎么落到这些移动上。

## 为什么是现在这个形状

以前视图层级本身就是模型：每个标签页里是嵌套的 NSSplitView，移动一个 pane 是一串视图手术——摘掉子视图、解包只剩一个孩子的分屏、同步强制布局、再把分隔线位置推到下一拍去摆。

这条路有一个无法绕开的问题。连续改动 NSSplitView 的子视图时，AppKit 的约束求解器会抛 `NSInternalInconsistencyException`，原文是 "Tried accessing the col index for a variable that is a row head"。排查结论：

- 绕开控制器、只对视图做原始调用也能复现，我们自己的约束代码是干净的。
- 先把整棵分屏树摘离窗口再拆，照样炸。
- 只有每摘掉一个子视图就先让分屏重新布局一次，才能躲过。
- 会不会炸取决于求解器内部的主元状态，所以标签页数量、侧栏开合、合并之后过了多久都会影响它。

异常在一串手术中途抛出，树就停在改到一半的样子：标签页里可能一个 pane 都不剩，被拖的 pane 不属于任何标签页；AppKit 吞掉异常继续运行，侧栏的拖拽卡片也被甩在屏幕上。

"每步都布局一次"是在猜 AppKit 的内部时序，所以没有走那条路，而是换掉整个排布方式。

## 模型：值类型的树

`LighttyCore` 里的 `PaneLayout`、`TabArrangement`、`WindowArrangement`、`SplitSnapshot`，纯函数，不依赖 AppKit。

- `PaneLayout`：一个标签页内的排布。叶子是 pane 的身份，分屏节点带方向和各分支的比例。
- 插入无条件把目标叶子原位包成二叉分屏，两半对半分，外层比例不动，同方向也不压平。移除时兄弟节点接管空位，空出来的比例交给相邻兄弟。语义对齐 Ghostty 上游的 `SplitTree`。
- 均分、拖分隔线、按键调尺寸、算 frame 也都在模型上完成。几何计算先按累计比例算边界、再对齐到物理像素，pane 与分隔线之间不会出现一像素的缝或重叠。
- `TabArrangement`：只看「标签页身份 + 排布」的结构命令——把 pane 放到另一个 pane 旁边、并进某个标签页、拆成新标签页、标签页换位、移除 pane。被移空的标签页直接从结果里消失。

### 窗口排布 `WindowArrangement`

一个窗口的完整编排：有序的 `tabs: [ArrangedTab]` 加 `activeTabID`。`ArrangedTab` 带身份、`PaneLayout`、标题、放大中的 pane 和最近聚焦的 pane。控制器只持有这一份值，标签页的一切状态都在里面，视图上不另存。

- **命令**：选中（按身份，或按 goto_tab 的 previous / next / last / 序号）、记录焦点、追加标签页、改名、标签页换位（`movingTab(_:after:)`、`movingActiveTab(by:)`）、插入 / 移除 / 移动 / 拆出 pane、一次移除一组 pane（`removingPanes`）、改比例、切换放大、撤销时换回记录（`restoring`）、生成快照条目。每条命令要么返回完整的新编排，要么返回 nil 表示无效或无事可做。
- **贯穿所有命令的三条规则**，集中在模型内部，调用方不用各自处理：
  - 当前标签页被移除时，落到它原来位次上的邻居（越界取最后一个）。一次移除一组时按移除前的位次算。
  - 标签页的排布结构变了，它的放大态作废；只改比例不算结构变化。
  - pane 离开标签页（关闭、移走、拆出、跨窗口移出）时，它不再是那个标签页的焦点。
- **标题 `TabTitle`**：`.numbered(n)` 是默认名，只存序号，显示时才按当前语言格式化，所以切换语言不会把默认名变成「用户起的名字」；`.custom(s)` 是用户起的名字，原样保存。快照里显式存了是否改过名；缺这个字段的旧快照读入时按默认名格式反推一次。默认名序号由 `AppState` 持有的 `TabNumbering` 跨窗口发放，同一时刻不会有两个窗口出现同名的默认标签页；只在提交成功后占号，清空窗口后回落到其他窗口仍在用的最大序号。
- **放大**：`zoomedPane` 记在标签页上，`togglingZoom` 切换，结构一变就清掉。
- **焦点**：每个标签页记住最近聚焦的 pane（`focusedPane`，只经 `focusing` 写入），`focusTarget` 是记录值，没有就取树序第一个。切回一个标签页时焦点回到它最近聚焦的 pane。撤销时只在那个 pane 回到记录后仍在同一标签页才保留。
- **快照**：`SplitSnapshot<Leaf>` 承载工作区快照里分屏树的线格式（已发布，不能改）以及它与 `PaneLayout` 的双向换算；壳层的 `SplitNodeSnapshot` 是它的别名。取快照时任何一个叶子取不到就整棵放弃；恢复时取不到身份的叶子跳过，所在分屏改为均分。

## 渲染：按 frame 摆放

`PaneLayoutView` 是每个标签页的容器，按模型用 frame 摆放 pane 和 1pt 的分隔线，不经过任何排布约束。pane 换标签页或换窗口就是一次换父视图。

- 渲染时拿的是整个窗口的 pane 注册表。已经不在注册表里的 pane 摘掉；还在注册表里、只是不归本标签页的 pane 留给新容器来接，它一刻也不离开窗口。
- 分隔线命中区在线条两侧各放宽 3pt，压在 pane 边缘之上；拖动时单个 pane 不小于 40pt。
- 放大（toggle_split_zoom）只隐藏其余 pane，不把它们移出视图层级，surface 生命周期不变。

## 控制器：唯一的改树通路

`TerminalWindowController.commit` 是改 pane 树的唯一入口：

1. 校验：新编排自身合法（标签页与 pane 身份不重复、当前标签页在列表里），每个 pane 都找得到视图。不通过就整份拒绝，什么都不动。
2. 标签页按身份对位：沿用、新建或摘掉容器。放大态与当前标签页的落点已经由 `WindowArrangement` 的命令算好，这里不再判断。
3. 渲染每个容器。
4. 收尾：默认名占号、选中、焦点、空态、侧栏刷新、持久化、同步会话库（一次）、广播 `lighttyWindowArrangementDidChange`（别的窗口的第二侧栏跟上，工作区快照节流保存）。

所有结构操作都是"用纯函数算出新编排，然后 commit"：分屏、关闭、移动、拆出、换位、快照恢复。只改比例、选中、改名、放大这些不动树的更新不走 commit，直接写模型并渲染或刷新侧栏。跨窗口移动时两步都算成功才提交，先让目标窗口接收，再让源窗口注销。

commit 可以带一个要交还焦点的 pane：它落在当前标签页时先记进模型、再成为 first responder，最后才同步会话库，这一次同步看到的就是它。

commit 不关闭 surface：不再被引用的 pane 只是从本窗口注销并摘下，它是被关掉还是搬去别的窗口由调用方决定。

### 按身份通信

控制器和第二侧栏之间只传标签页或 pane 的 UUID：侧栏从 `tabOverview()` 读取各标签页的身份、标题与 pane，行上的点击、改名、关闭、拖拽落点都回调 `selectTab(withID:)`、`renameTab(withID:to:)`、`closeTab(withID:)`、`moveTab(withID:after:)`、`detachPane(withID:toNewTabAfter:)`、`movePane(withID:…)` 这类按身份的方法。goto_tab N 这类序号只在控制器里换算成身份。侧栏行的高亮只从控制器的 `activePane` 派生，点击行只发命令，不直接改高亮。

### 关闭

`close(panes: Set<UUID>)` 是关闭的唯一入口：pane ✕ 与 shell 退出（`close(pane:)`）、容器行 ✕（`closeTab(withID:)`）、close_tab 的 this / other / right（`closeTabs(mode:)`）、清空窗口（`clearTabs`）都换算成一组 pane 交给它。

1. 对每个将被移除的 pane 对账 Agent 进程（`reconcileSessionProcess`）：退出通知可能还排在主队列里，关掉之后就没有机会再核对。
2. `WindowArrangement.removingPanes` 算出移除后的编排，一次 commit。本窗口没有的身份忽略。
3. 焦点交接：当前标签页丢了 pane 但还在时，正在用的 pane 没被关就留在它身上，被关的正是它才交给同标签页剩下的第一个 pane；当前标签页整个没了，由模型落到原位次上的邻居，焦点取那个标签页记录的焦点。

关闭本身不弹确认，是否确认由调用方决定；目前只有「关闭全部标签页」（`requestClearTabs`）先确认。

### 焦点

`activePane` 的规则：first responder 在当前标签页里就用它；否则用模型记录的 `focusTarget`。焦点只存在模型里，控制器没有另一份「最后聚焦的 pane」字段；跨窗口移动时源窗口的焦点也由它自己的模型修正。

## 撤销

移动前记下涉及窗口的完整编排，撤销时原样恢复，恢复本身也走 commit 并反向注册一次成为重做。

只在涉及窗口里的 pane 集合与当时一致时生效。期间有 pane 被关掉或新建，按旧编排恢复要么指向不存在的视图，要么把新 pane 从树里挤掉（等于关掉它），这种撤销静默作废。

## 侧栏拖拽

交互规则见 [双侧栏布局约定](double-sidebar.md)，这里只讲实现约定。

- 列表数据源从不被拖拽改写。`modelRows` 是控制器模型的如实投影，显示行由"模型行 + 拖拽会话"推导出来：源行挪到提议的位置，拖动的容器行临时折叠。拖拽途中来多少次刷新都只是重新推导，不会打断拖拽。
- 行按身份识别（pane 身份、标签页身份），不按下标。
- 开始、移动、松手是三个与鼠标事件无关的方法，跟手循环只是薄适配层，测试直接驱动它们。
- 松手时只定下命令、冻结显示、让卡片起飞落地；命令放到下一拍交给控制器。卡片的去留与改树的成败互不牵连。

## 测试入口

- `LighttyCoreTests/PaneLayoutTests`：单个标签页的排布与 `TabArrangement` 结构命令。
- `LighttyCoreTests/WindowArrangementTests`：窗口排布的全部命令，当前标签页落点、放大态作废、焦点修正、标题解析与恢复、撤销与快照条目。
- `LighttyCoreTests/SplitSnapshotTests`：快照线格式、方向字段的含义、叶子缺失时的取舍。
- `LighttyTests/PaneArrangementTests`：控制器在真实窗口里的表现，第一条就是当年稳定复现求解器异常的现场，另有跨配置反复重组的压力用例、事务性、跨窗口、撤销、放大、快照比例、方向聚焦、关闭时的焦点交接。
- `LighttyTests/LeafTabRowTests`：叶子行呈现与默认名（跨窗口不重复、改过名的按自定义保存）。
- `LighttyTests/PaneLayoutViewTests`：渲染契约。
- `LighttyTests/TabDragSemanticsTests`：落点判定、命令映射、拖拽会话（含途中刷新、松手后执行前有标签页被关）。
- `SessionFocusTests.swift`：移动 pane、关闭 pane、切换标签页之后，侧栏高亮与 Sessions 选中项都跟随 `activePane`。
- `AgentProcessLifecycleTests.swift` 里的 `everyCloseRouteReconcilesAgentProcesses`：每一种关闭入口都对账 Agent 进程。
