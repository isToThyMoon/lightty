# Skills 设置页

## 目标与边界

把本机共享技能、Agent 专属技能和内置技能放进一个按来源浏览的界面。插件提供的技能
属于它的插件，在 Plugins 页（`docs/specs/plugins-settings.md`）浏览，这里不再重复列出。
保留 Agent 与安装器原有目录结构；lightty 只保存收藏和「我的」标记，不修改
SKILL.md、安装锁文件、软链接或插件缓存。第一版提供浏览、搜索、收藏、归类、
打开文件、Finder 定位和来源链接；安装、更新、卸载与按 Agent 启停后续单独接入。

## 布局

从 Settings 的 Skills 标签进入，**保留原有设置导航**。Skills 仅挂载在右侧
`pageHost`，内部依次为来源／标签、技能列表和正文；没有额外的「返回设置」入口。
Esc 与设置左上角的「返回应用」沿用设置页行为。侧栏已标识 Skills，内容区不再重复标题。

```text
┌──────────────┬──────────────┬────────────────────┬─────────────────────────┐
│ 返回应用      │ 全部技能  78  │ 全部技能     78 ↻  │ code-review          ☆ ⋯ │
│ 搜索设置      │ 收藏       4 │ 搜索技能或来源…     │ mattpocock/skills        │
│              │ 我的       3 │                    │ 简短说明                 │
│ 通用          │ 待归类     5 │ code-review        │                         │
│ 外观          │              │ 审查代码规范与设计   │ 打开文件   Finder   来源 │
│ Handoff      │              │                    │                         │
│ Skills ●     │              │ codebase-design    │ SKILL.md            原文 │
│ 归档          │ 来源         │ 设计模块接口与职责   │ ─────────────────────── │
│              │ Lark CLI  28 │                    │ # Code review           │
│              │ mattpocock37 │ diagnosing-bugs    │                         │
│              │ …            │ 定位复杂错误        │ 正文，可选择和滚动       │
│              │ Built-in sk. │                    │                         │
└──────────────┴──────────────┴────────────────────┴─────────────────────────┘
```

- 来源是平铺筛选项，无折叠树；导航中省略仓库末尾的 `/skills`，详情保留完整来源。
- 「全部」默认涵盖普通安装与本地技能；内置技能有独立入口，避免大量附带技能刷屏。
- 搜索作用于当前分类的名称、说明与来源；分类与搜索组合使用，空结果直接说明。
- 左栏来源数量代表该来源总数，中栏标题显示当前筛选结果数。切分类保留仍可见的
  选中项，否则选择第一条；搜索无结果清空详情，不显示过期内容。
- 收藏和「我的」为两个独立标记，不改变来源。「来源未知」不能自动认定为自写。
- 列表用标准可键盘导航的 NSTableView；每行名称一行、说明一行，超长截断。
- 右栏优先显示内容。完整路径、所有发现位置和诊断放在简洁的信息区域／菜单，
  不用一排徽章或大卡片占据阅读空间。正文只读，打开文件交给系统默认应用。

## 视觉规范（先定义，所有新增控件统一引用）

| 项目 | 规格 |
| --- | --- |
| 设置导航 | 默认 240pt 左栏，边界可拖动，范围 160–320pt；Skills 位于第三项 |
| 来源栏 | 右侧内容内常规 184pt，窄窗口 172pt |
| 列表栏 | 常规 232pt，窄窗口 196pt；正文占剩余宽度 |
| 顶部留白 | 16pt；不重复显示 Skills 标题，来源列表直接从顶行开始；刷新放在技能列表表头 |
| 基础间距 | 4 / 8 / 12 / 16 / 24pt；栏内留白 16pt，详情常规 24pt／紧凑 16pt |
| 导航行 | 32pt 高，图标 13pt，行内距 8pt + 滚动容器外距 8pt |
| 列表行 | 64pt 高，名称与说明间距 4pt，行内距 8pt + 滚动容器外距 8pt |
| 按钮 | 28pt 高，沿用 ShellIconButton / ShellTextButton |
| 圆角 | 控件 8pt，列表选中底 9pt，沿用 ShellStyle |
| 字体 | 系统字体；详情标题 20pt medium，列表表头 13pt medium |
| 字体层级 | 名称／导航 13pt medium/regular，正文 13pt，说明 12pt，分组标题 11pt medium |
| 正文代码 | 系统等宽字体 12pt；保留换行、缩进，可复制 |
| 配色 | ShellStyle.sidebarBackground / raisedSurface / primaryText / secondaryText |
| 选中／悬停 | ShellStyle.selectionFill / hoverFill；无原生蓝色选中底 |
| 分隔 | 栏间 1pt divider、7pt 拖动命中区；两条分隔线均可拖动调整相邻栏宽，来源最小 172pt、列表最小 196pt、正文栏最小 292pt；内容区域不额外套圆角卡片，不加阴影 |
| 明暗模式 | 全部使用 ShellStyle 动态色，切换后立即重解析 |

拖动第一条线调整来源与列表的相邻宽度；第二条线调整列表与正文。栏宽保存到本地 preferences.json，重新打开设置或重启应用后恢复用户调整的宽度，窗口缩小时按最小栏宽收紧，放大后恢复偏好宽度。
宽度不足时缩小导航和列表，详情保持可滚动；极窄窗口提供仅右侧三栏画布横向滚动（最小 660pt），
不丢失来源或内容，也不改应用主窗口最小尺寸。普通尺寸不出现横向滚动条。

## 数据依据

- 全局共享目录、各 Agent 专属目录扫描 SKILL.md；按解析后的真实路径合并软链接。
- 列的标准是「本机 Agent 认得、能调用的技能」。`~/.claude/skills/synced` 是 claude.ai
  同步下来的那批技能的容器，技能上面还有一层按组织和账号分的桶
  （`synced/<org>_<account>/<技能>/SKILL.md`）：桶里的技能要列，来源记作 claude.ai；
  容器本身不是技能，不列，也不能顶着「SKILL.md 缺失」冒充一条。
- `npx skills` 的全局 `.skill-lock.json` 提供来源信息；只关联对应共享安装，
  不能把同名的独立副本或插件技能归到这个来源。兼容 XDG_STATE_HOME 指定的记录位置。
- 插件目录（Claude 的 installed_plugins.json、Codex 的 plugins/cache）不在本页扫描范围内，
  口径见 `docs/specs/plugins-settings.md`。
- 文件读失败、损坏锁文件、断链与缺失 SKILL.md 应可见，不静默伪装成空安装。
- 元数据只用来组织界面，持久化到 `~/.lightty/skills-organization.json`。
- 不硬编码用户账号、个人来源仓库或本机绝对路径；测试一律用临时目录。

## 实施计划

1. **数据与组织**：独立扫描器、来源解析、软链接去重、可持久化收藏／我的标记；
   用临时目录验证未知来源、重复名称、不完整文件、损坏记录。
2. **三栏 UI**：统一 SkillsStyle；来源筛选、可搜索列表、正文预览和文件动作；
   接入 Settings，保留普通设置页和语言／外观切换行为。
3. **验证与打磨**：中英文、明暗主题、常规与窄窗口布局截图；键盘选择、空结果、
   组织信息往返测试；正常负载串行全量 swift test。不启动第二个 lightty 实例。

数据扫描与 UI 相互独立，按用户已有并行约定分工；集成与测试串行执行。

## 实施结果与验收

- 已实现：`SkillCatalog.swift`（只读扫描与来源）、`SkillOrganization.swift`（共享的
  组织信息存储）、`SkillsSettingsView.swift`（三栏与动作）、`SkillsStyle.swift`
  （布局与 Markdown 阅读排版），入口为 Settings → Skills。
- 收藏与「我的」标记跨窗口共享；语言切换刷新缓存页面；收藏、筛选及外观切换
  不重置当前文档的滚动位置和文字选择。
- 本版扫描全局共享／Claude／Codex 技能目录与内置目录；`~/.cursor/skills` 不扫，那两家读不到。
  `~/.agents/skills` 是 Codex 现行的用户级目录（`codex-rs/ext/skills/src/host_roots.rs`），
  Claude Code 不读它，要靠软链进 `~/.claude/skills`；`<CODEX_HOME>/skills` 是 Codex 标为已废弃、
  仍兼容的旧位置。仓库级目录（`<repo>/.agents/skills`、`.claude/skills`）与 Codex 的 Admin 级
  目录本页不扫：前者随项目走，后者属受管部署。
  项目级技能、任意标签、安装更新移除未接入；插件技能移到 Plugins 页。
- 缺失文件、断链和坏元数据进入提示。
- 2026-09-15 全量 `swift test`：505 项 XCTest（1 项跳过）和 140 项 Swift Testing，
  0 失败；本次新增 19 个测试函数。资源文件 `plutil -lint` 与 `git diff --check` 通过。
- UI 测试覆盖中英文、明暗主题和 完整设置页的 1280 / 1080 / 900pt 宽度；全部通过隐藏窗口的
  `cacheDisplay` 输出截图，不启动第二个 lightty 实例，也不显示测试窗口。

```sh
unset LIGHTTY_PANE_ID LIGHTTY_SOCK
LIGHTTY_UI_SNAPSHOT_DIR=/tmp/lightty-skills-snapshots swift test --filter SkillsSettingsViewTests
```

截图文件名：`settings-skills-<en|zh-Hans>-<NSAppearanceNameAqua|NSAppearanceNameDarkAqua>-<宽度>.png`。

### 设置页边界回归

Skills 必须从 Settings 右侧 240pt 分界线开始，背景覆盖到窗口顶边；切页后左侧导航
仍可见。根因是旧实现隐藏原有不透明设置背景，并把带自动标题栏 inset 的透明
滚动区直接挂到整个设置根视图。现改挂右侧 pageHost、保留背景、关闭内层自动 inset。
回归测试 `skillsStayInsideSettingsContentAndKeepNavigationVisible` 在修复前失败、修复后通过；
截图以完整 SettingsView 为根，避免只测试 Skills 子视图遗漏集成边界。

## 内置技能层级

来源栏分为「通用安装」和 Built-in skills。内置技能下的 Claude Code / Codex 始终展开，
Agent 标题下直接列出技能，点击打开正文；旧折叠偏好不再隐藏条目。
Claude Code 暂不支持读取时，在标题下显示说明。标题、来源与条目的文字层级、留白和缩进
统一遵循 [UI harness](../UI-harness.md#分组与嵌套)，不增加同名分类层。

预览保留完整 YAML frontmatter，以等宽文本显示；刷新复用 RefreshButton 的旋转与减少动态效果支持，扫描完成后结束当前圈。

详情操作按钮下方展示可选择、复制的完整实际文件路径，以及不同的发现位置（如 .claude 软链接入口）。路径区独立滚动，不截断实际路径文本。
