---
name: lightty
---

## Overview

macOS 原生工具的克制感：暖灰壳层、高信息密度、少框线，终端内容始终是主角。壳层安静地退到后面，只有 Agent 状态和当前位置用颜色说话，长时间并行盯多个 Agent 时不抢余光。

这里只写风格和每类 token 的用途，具体数值以 `Sources/lightty/ShellStyle.swift` 为准（页面专属尺寸在 `SkillsStyle`、`SearchPaletteStyle`、`PaneIdentityMetrics`）。页面只引用语义 token。区域、组件和行为规则见 [UI harness](docs/UI-harness.md)。

优先按用途选 token，不要寻找恰好等值的常量。

## Colors

壳层色都有明暗两套，由 `NSColor.shellDynamic` 定义。Terminal 的前景、背景、透明度和终端字体由 Ghostty 拥有，壳层 token 不覆盖这些配置。胶囊以终端前景派生弱化文字及 hover 色，状态点仍共享应用语义。动态 `NSColor` 转为 layer 的 `CGColor` 后，参考 `ShellBackdropView` 在外观变化时重新解析。

- **文字**：`primaryText` 为主要内容，`secondaryText` 为说明，`tertiaryText` 为较弱的辅助信息。颜色层级与字号层级独立选择。`tertiaryText` 在壳层底色上对比度不到 AA，不用于要读的内容。
- **表面与状态**：`sidebarBackground` / `titlebarBackground` 为壳层底色，`raisedSurface` 为浮起面；`controlFill`、`inputFill` 对应控件与输入区域。hover、pressed、selection 各有已有 token。浮卡里需要成段归组的连续行（Sessions 的已打开会话）用 `trayFill` 凹托：比 `raisedSurface` 暗一档，整段一块、不加框线，每行画自己那一截（行框含行间空隙，首尾收圆角），挪行动画时随行滑动；托内 hover / 选中照常叠画并缩进一圈。
- **导航与活动**：`activeContainerFill` / `activeItemFill` 区分所在容器与当前终端（当前终端为实心导航色，前景取 `onNavigationAccent`）；`navigationAccent` 表达位置，`accent` 表达控件强调。任务绑定与 agent 活动通过 `dotColor` / `statusColor` 取色，避免混同导航与活动状态。
- **重点色**不跟随系统强调色，由 `AccentPreference` 决定；无色相档位时导航退回 `navigationFallback`。`boundAccent`、`dormantAccent`、`statusAttention` 取系统动态色。

## Typography

全部用系统字体。`Font.listTitle` 用于资料条目，`groupTitle` 用于树容器，`body` 用于普通正文/终端叶子名称，`section` 用于分组标题。`caption` / `captionStrong` 是元信息，`hint` 是说明，`count` 是数量（等宽数字）。`compactTitle` / `compactBody` 留给 terminal 身份行与紧凑面板；`statusEmphasis` 表达需要注意的状态；`mode` / `selectedMode` 是模式切换。

## Layout

`textLineGap` 属于同一文本块，`inlineGap` 属于相邻元素，`rowVerticalInset` 是行内留白，`listRowGap` 是行间留白。`sidebarHorizontalInset`、`sectionInset`、`chromeGap` 分别服务于行内容、分组内容和 chrome 区块。

`chromeRowHeight` 是工具栏/终端头部的共同模数；`listActionSize` 是侧栏行内操作（⋯、✕、详情）的统一热区，字形大小另取、不随热区放大。第二侧栏的行比热区高，⋯ / ✕ 的可点范围再扩到整行高、✕ 延伸到行的右缘，字形仍在 `listActionSize` 槽位里；行尾按钮浮在铺到行尾的标题上，命中时显示着的按钮优先。

线条颜色用 `divider`；线宽没有 token，输入控件和选中轮廓按作用在组件内取值。局部尺寸不必进 token，留在所在页面的 Style 中。

## Elevation & Depth

固定并列区域靠底色区分，阴影只留给浮层（第一侧栏卡片、菜单、灵动岛）。阴影没有全局 token：参数随浮层大小和明暗不同，见 `ShellMenuPopover`、`IslandShadowView`，新增浮层先从它们取值。

## Shapes

`panelCornerRadius`、`rowCornerRadius`、`compactRowCornerRadius`、`controlCornerRadius`、`capsuleCornerRadius` 按容器角色选择，不按尺寸选。

## Components

状态、图标与对齐、分组层级的规则见 [UI harness](docs/UI-harness.md)。

动效：普通过渡用 `animationDuration`；侧栏开合用 `sidebarAnimationDuration` 配 `easeInOutCubic`。状态呼吸刻意慢到余光阈值以下：思考用 `statusBreathDuration`，工具用稍快的 `statusToolBreathDuration`；`statusDonePulseDuration` 的三拍闪烁是唯一主动抢注意力的动效，一次性不循环。减少动态效果开启时不播放装饰动画。

## Do's and Don'ts

- 要用底色和留白区分层级，不要加框线和卡片：框线多了就抢终端内容的视线。
- 要把状态色只用在状态上：thinking 和 tool 同一个蓝，橙（要你介入）和品红（跑完未读）才跳得出来；新加用途会稀释这三类的区分。
- 不要让壳层改变终端观感：没有 agent 在跑时，界面要和没装 hook 时一样。
