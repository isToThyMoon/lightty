# UI harness

为 UI 决策提供共同起点：先沿用已有视觉语言，再根据内容密度和交互目的调整。这里描述语义和选择依据；具体数值以 Swift 为准。无需为每个局部尺寸建立 token，也无需为合理的局部差异增加审批。

## 从哪里开始

| 区域 | 职责与视觉依据 | 实现入口 |
| --- | --- | --- |
| 第一侧栏 | Handoff / Sessions 资料库；浮起的卡片，模式切换、分组和多行列表 | [PrimarySidebar](../Sources/lightty/PrimarySidebar.swift)、[HandoffSidebarContent](../Sources/lightty/HandoffSidebarContent.swift)、[SessionsSidebarContent](../Sources/lightty/SessionsSidebarContent.swift) |
| 第二侧栏 | 当前窗口的标签页与终端树；用缩进、容器字重和导航色表达归属及当前位置 | [TabColumnView](../Sources/lightty/TabColumnView.swift)、[TabSidebarView](../Sources/lightty/TabSidebarView.swift) |
| Terminal 区 | 终端内容由 Ghostty 配置；身份胶囊贴合终端，展开面板延续同一身份行 | [PaneHeaderView](../Sources/lightty/PaneHeaderView.swift)、[PaneIdentityPanel](../Sources/lightty/PaneIdentityPanel.swift)、[PaneLayoutView](../Sources/lightty/PaneLayoutView.swift) |

开合、拖拽、选中等行为见 [双侧栏约定](specs/double-sidebar.md)。设置页等新区域可借用基础角色，页面专属尺寸留在自己的 Style 中，如 [SkillsStyle](../Sources/lightty/SkillsStyle.swift)。现有页面是上下文，不代表每个历史常量都值得照搬。

设置中的多栏浏览页以背景、留白和文字层级区分导航、列表与正文，去掉栏间竖线及正文分割线。通用、外观等表单设置保留分组卡片的圆角外框与组内行间线，用来明确子项归属。多栏浏览器使用 `browserNavigationBackground` → `browserListBackground` → `browserDetailBackground` 从来源到正文逐级提亮；固定并列区域靠底色区分，阴影留给浮层。调宽命中区独立于可见分割线。输入控件及选中状态仍可使用有明确作用的轮廓。

## 基础语义

token 的值和选择依据见 [DESIGN.md](../DESIGN.md)，壳层 token 入口是 [ShellStyle](../Sources/lightty/ShellStyle.swift)。

两级侧栏的模式/标题带共用 `ShellStyle.SidebarHeader`，对齐头部中心和列表起点；第一侧栏的模式说明放在 tooltip 与空状态，不常驻占一行。第一侧栏保留浮卡的外框与阴影，窗口外轮廓由系统负责。行内更多操作在悬停、键盘聚焦或菜单打开时显示，操作槽位始终保留。

两级侧栏的列表由 AppKit 原生常驻滚动条预留独立槽位；内容区尺寸只由系统布局计算，不在 `tile()` 后手工收窄。长列表的轨道可点击翻页，短列表的空槽仍可用于拖动侧栏边线。

身份胶囊分两块可点区域：点 pane 名展开灵动岛的详情态（改名、绑定任务的目录与更新时间、handoff 摘要、让 Agent 总结、打开文档、解除绑定）；点右侧任务区（未绑定「+ 任务」，已绑定任务名与箭头，窄时收成图标但不消失）直接进任务选择器。选择器也响应 `toggle_command_palette`（默认 ⇧⌘P，可在 Ghostty config 改绑）。选择器把与终端当前目录相关的任务排在前面（`TaskDirectoryMatch`），搜索匹配任务名和目录末级；有输入就常驻新建行，回车绑定高亮行，⌘回车新建；选定后岛体收起回到终端。第一行与胶囊的名字部分逐像素同构；任务区在形变时用位图淡出，不参与同构。

两级侧栏共享颜色与文字角色，允许列表密度不同。第一侧栏多行列表与第二侧栏紧凑树行的行高、缩进和操作区域不必相同。`PaneIdentityMetrics` 则同时服务胶囊与展开面板，它们的身份行需要保持同构。

第二侧栏底部固定一行（`chromeRowHeight`）承载 `AgentOutputMeterView`：按 Agent 取形象的像素精灵（`AgentSpec.sprite`，原创致敬图案，品牌色固定、通用精灵跟随次级文字色）与当前终端 Agent 最近几次请求的输出速度。
左边缘与「标签页」标题、行文字同起点。不放顶部：第一侧栏收起后顶部归窗口三键，位置随开合跳动会让人找不到。
不加卡片或边框，不占终端内容区域；没有读数时不显示数字，精灵静止。它的动画只表示 Agent 正在生成，
不表示服务器健康，也不随速度加速。隐藏 / 遮挡时停轮询（失焦仍跟随当前 pane），减少动态效果时不播放动画。
数据边界见 [输出速度方案](specs/output-speed.md)。

## 分组与嵌套

设置页导航共用 `ColumnBrowserCell` 的层级语言，先决定行的角色，再选择是否可折叠：

| 角色 | 表达方式 |
| --- | --- |
| 主分组（如 Claude Code、Codex） | `Font.groupTitle`、主文字色与 `navigationGroupFill` 轻底色，组间留白；描述是底色之外、标题下方的次级文字，与标题同列，窄栏换行不截断。 |
| 来源分组（如 openai-curated-remote） | `Font.body`、次级文字色，组间留白；标题与尾部安装数量共同说明范围。 |
| 内容条目（插件、技能） | 常规正文文字，沿用统一图标槽与文字轴；版本、状态、数量弱化。 |

主分组底色表示持久的分区，不表示选中；它与 hover、选中底色反向偏离导航底色（浅色提亮、深色压暗），同向时只差色阶，无法区分。来源分组保持透明。平铺分组下，主分组标题与条目共用文字起点；折叠箭头用紧凑尺寸，以固定中心贴近标题，两个朝向不左右跳；来源标题不推动每个子项向右。真正的树状父子关系才逐级增加缩进。同级标题及其说明共享文字起点。单行主分组的底色与内容高度一致，组间留白放在内容框外；图标、文字和数量均相对同一内容框定位，居中方式见「图标与对齐」；有常驻底色的行不再叠画 hover 底色。分组靠字重、颜色与留白区分，框线和背景遵循所在区域的表面规则。

折叠是交互能力，不代表更高的文字层级。Plugins 仅 Agent 主分组可折叠，来源始终展开；Skills 内置 Agent 与技能始终展开。非折叠分组不显示箭头，也不响应选择。参考 `SkillsSettingsView.navigationCell` 与 `PluginsSettingsView.navigationCell`；外观实现留在共享 cell 与 token 中。

## 图标与对齐

常见操作从 [ShellSymbol / SymbolImages](../Sources/lightty/SymbolImages.swift) 找语义与缓存入口，品牌标志使用 `AgentSessionIcon`。工具栏优先复用 `ShellIconButton`，刷新与独立展开按钮复用 `RefreshButton`、`SidebarDisclosureButton`；浏览器行内的箭头和内容图标统一由 `ColumnBrowserCell` 的 NSImageView 槽位渲染；第二侧栏的标签页容器保留矩形叠层图标来表达归属和折叠。新语义可以选合适的 SF Symbol，重复使用后再集中命名。

布局先确定共同的文字轴与图标槽位：同级行共享起点，层级变化才增加缩进；相邻文字对齐基线，图标对齐它所服务的文字行或控件中心。标题、说明组成一个文本块，尾部操作留独立空间。字形大小与点击区域分别考虑，光学校正优先留在组件内部。

垂直居中按视觉中心，而不是控件框的中心：
- 单行文字：让大写字高的中心（`ascender - capHeight / 2`）落在所在内容框或底色的中线上。`NSTextField` 把字排在框顶，框居中后字会偏高。
- 图标：让 SF Symbol 的 `alignmentRect` 中心对准所服务文字的大写字高中心，高矮不一的符号才能落在同一条线上。
- 同一行里字号不同的文字（如标题与数量）：对齐基线，不对齐框顶。
- 多行文本块：整块在行内定位，图标可以领起整块居中。
- 水平方向：窄字形（如折叠箭头）按视觉间距贴近文字，不必死守槽位中心；会旋转或切换朝向的字形共用固定中心。
- 参考 `ColumnBrowserCell.layout()` 与 `iconTop`。

根据内容选择 Auto Layout、stack 或手工 frame；关键是缩窄后的行为明确。名称通常尾部截断，路径优先保留可辨认的尾部；低优先级元信息先让位。参考 `PaneHeaderView` 的压缩优先级，避免长标题撑开 pane。页面专属坐标不必抽象为全局 token。

操作菜单使用 `ShellStyle.Menu` 的排版与分组 token：操作行同字号同字重，有图标时整张菜单共享图标槽位；尾注弱化。组间用带上下留白的细线，不显示小号组名；动作文字本身说清用途。空组及首尾、重复分割线不占空间，危险操作独立成组。

## 工作与验证

实现前选一个相关区域作为参考，查看它实际使用的 token 和组件。遇到相同语义的重复值，优先合并；存在用途差异时在所属组件保留，并简短说明原因。只有新增的共享概念才需要补充本文件。

完成后按改动选择构建、已有行为测试和视觉检查。视觉重点是正常/窄宽度、长文本，以及本次涉及的明暗和交互状态；查看渲染结果后再判断对齐与观感。编译通过不等于视觉已验证，交付时说明未覆盖的场景即可，无需每次完成全套矩阵。

看渲染结果用 `scripts/snapshot.sh <过滤>`，各区域对应的过滤见下表；外观数值不写成单元测试断言（见 [测试约定](testing.md#粒度)）。真实终端交互留给用户在当前运行的实例里验收。

| 区域 | `scripts/snapshot.sh` 的过滤 | 产出 |
| --- | --- | --- |
| 两级侧栏整体、输出速度计、hover / 键盘 / 宽屏 | `SidebarControlsTests/testInitialWindowOpensTaskPanel` | `sidebar-*`、`output-meter-*`，明暗各一套 |
| Sessions 会话行菜单 | `PrimarySidebarTests/testMoveToRecentMenu` | `session-menu-*` |
| Sessions 列表（项目与会话行、展开 / 收起） | `PrimarySidebarTests/testRapidDisclosure` | `disclosure-*` |
| Sessions 会话搜索 | `PrimarySidebarTests/testProjectsCollapse` | `session-search.png` |
| 身份胶囊（宽 / 窄 / 长文本）、灵动岛详情态与任务选择器 | `PaneIdentityPanelTests/testCaptureSnapshots` | `capsule-*`、`identity-*`，明暗各一套 |
| 设置：MCP / Skills / Plugins | `MCPSettingsViewTests` / `SkillsSettingsViewTests` / `PluginsSettingsViewTests` | 各页明暗与状态 |

截图时测试窗口会短暂上屏。`PrimarySidebarTests` 写在 `SessionCatalogTests.swift` 里，过滤按类名。新区域要截图时，在该区域的场景测试里按 `LIGHTTY_UI_SNAPSHOT_DIR` 分支加一张，并补进上表。

本文采用短入口、按需读取和代码作为事实来源的组织方式，参考 [OpenAI harness engineering](https://openai.com/index/harness-engineering/) 与 [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)。这是组织依据，不是需要 agent 每次阅读的外部前置材料。
