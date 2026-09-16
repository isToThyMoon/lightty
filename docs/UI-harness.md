# UI harness

为 UI 决策提供共同起点：先沿用已有视觉语言，再根据内容密度和交互目的调整。这里描述语义和选择依据；具体数值以 Swift 为准。无需为每个局部尺寸建立 token，也无需为合理的局部差异增加审批。

## 从哪里开始

| 区域 | 职责与视觉依据 | 实现入口 |
| --- | --- | --- |
| 第一侧栏 | Handoff / Sessions 资料库；浮起的卡片，标题、说明、分组和多行列表 | [PrimarySidebar](../Sources/lightty/PrimarySidebar.swift)、[HandoffSidebarContent](../Sources/lightty/HandoffSidebarContent.swift)、[SessionsSidebarContent](../Sources/lightty/SessionsSidebarContent.swift) |
| 第二侧栏 | 当前窗口的标签页与终端树；用缩进、容器字重和导航色表达归属及当前位置 | [TabColumnView](../Sources/lightty/TabColumnView.swift)、[TabSidebarView](../Sources/lightty/TabSidebarView.swift) |
| Terminal 区 | 终端内容由 Ghostty 配置；身份胶囊贴合终端，展开面板延续同一身份行 | [PaneHeaderView](../Sources/lightty/PaneHeaderView.swift)、[PaneIdentityPanel](../Sources/lightty/PaneIdentityPanel.swift)、[PaneLayoutView](../Sources/lightty/PaneLayoutView.swift) |

开合、拖拽、选中等行为见 [双侧栏约定](specs/double-sidebar.md)。设置页等新区域可借用基础角色，页面专属尺寸留在自己的 Style 中，如 [SkillsStyle](../Sources/lightty/SkillsStyle.swift)。现有页面是上下文，不代表每个历史常量都值得照搬。

设置中的多栏浏览页以背景、留白和文字层级区分导航、列表与正文，去掉栏间竖线及正文分割线。通用、外观等表单设置保留分组卡片的圆角外框与组内行间线，用来明确子项归属。多栏浏览器使用 `browserNavigationBackground` → `browserListBackground` → `browserDetailBackground` 从来源到正文逐级提亮；固定并列区域靠底色区分，阴影留给浮层。调宽命中区独立于可见分割线。输入控件及选中状态仍可使用有明确作用的轮廓。

## 基础语义

[ShellStyle](../Sources/lightty/ShellStyle.swift) 是壳层 token 入口。优先按用途选择，而不是寻找恰好等值的常量。

| 类别 | 选择依据 |
| --- | --- |
| 文字 | `Font.listTitle` 用于资料条目，`groupTitle` 用于树容器，`body` 用于普通正文/终端叶子名称，`section` 用于分组标题。`caption` / `captionStrong` 是元信息，`hint` 是说明，`count` 是数量。`compactTitle` / `compactBody` 留给 terminal 身份行与紧凑面板；`statusEmphasis` 表达需要注意的状态。 |
| 文字颜色 | `primaryText` 为主要内容，`secondaryText` 为说明，`tertiaryText` 为较弱的辅助信息。颜色层级与字号层级独立选择。 |
| 表面与状态 | `sidebarBackground` / `titlebarBackground` 为壳层底色，`raisedSurface` 为浮起面；`controlFill`、`inputFill` 对应控件与输入区域。hover、pressed、selection 各有已有 token。 |
| 导航与活动 | `activeContainerFill` / `activeItemFill` 区分所在容器与当前终端；`navigationAccent` 表达位置，`accent` 表达控件强调。任务绑定与 agent 活动通过 `dotColor` / `statusColor` 取色，避免混同导航与活动状态。 |
| 间距 | `textLineGap` 属于同一文本块，`inlineGap` 属于相邻元素，`rowVerticalInset` 是行内留白，`listRowGap` 是行间留白。`sidebarHorizontalInset`、`sectionInset`、`chromeGap` 分别服务于行内容、分组内容和 chrome 区块。 |
| 尺寸与圆角 | `chromeRowHeight` 是工具栏/终端头部的共同模数；`listActionSize`、`compactActionSize` 是不同密度下的操作区域。`panelCornerRadius`、`rowCornerRadius`、`compactRowCornerRadius`、`controlCornerRadius`、`capsuleCornerRadius` 按容器角色选择。 |

两级侧栏共享颜色与文字角色，允许列表密度不同。第一侧栏多行列表与第二侧栏紧凑树行的行高、缩进和操作区域不必相同。`PaneIdentityMetrics` 则同时服务胶囊与展开面板，它们的身份行需要保持同构。

Terminal 的前景、背景、透明度和终端字体由 Ghostty 拥有；壳层 token 不覆盖这些配置。胶囊以终端前景派生弱化文字及 hover 色，状态点仍共享应用语义。动态 `NSColor` 转为 layer 的 `CGColor` 后，参考 `ShellBackdropView` 在外观变化时重新解析。

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

测试与截图入口见 [HANDOVER 的构建与验证](../HANDOVER.md#构建与验证)；外观数值不写成单元测试断言。当前本机正在运行 lightty 时，不启动第二个应用实例（共享真实配置目录）；用测试 fixture 验证，真实终端交互留给当前实例的人工验收。

本文采用短入口、按需读取和代码作为事实来源的组织方式，参考 [OpenAI harness engineering](https://openai.com/index/harness-engineering/) 与 [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)。这是组织依据，不是需要 agent 每次阅读的外部前置材料。
