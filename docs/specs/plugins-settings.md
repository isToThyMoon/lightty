# Plugins 设置页

## 目标与边界

把 Claude Code 与 Codex 两个 Agent 已安装的插件放进一个可浏览的界面：插件是什么、
提供了哪些内容、装在哪里、现在开着还是关着，并允许在这里开关。除了「启用」这一个
布尔值，lightty 不改插件目录、不改安装清单、不改缓存、不装不卸不升级——安装、更新、
卸载仍然走各自 Agent 的 CLI。

插件技能从 Skills 页移出来：一条插件技能属于它的插件，两边都列会让同一条技能读起来
像装了两份。Skills 页只保留通用安装、Agent 专属目录与内置技能。

## 布局

从 Settings 的 Plugins 标签进入，复用 `ColumnBrowserView` 三栏骨架（与 Skills、Handoff
同一具骨架，列宽、拖动与持久化、搜索、计数、空态、诊断页脚都在骨架里）。

```text
┌──────────────┬────────────────────┬──────────────────────────────┐
│ Claude Code 2│ notion@claude-…    │ notion                  ●──  │
│  figma 2.2.1 │ 搜索插件内容…       │ notion@claude-plugins-…      │
│  notion 0.1.0│                    │ 0.1.0 · claude-plugins-… ·   │
│ Codex      4 │ search             │ Claude Code                  │
│  visualize   │ Skill · 搜索工作区  │ Notion Skills + MCP server   │
│  sites@…     │                    │                              │
│  gmail       │ notion             │ 打开文件  Finder  复制路径     │
│              │ Command · 问 Notion │ /Users/…/notion/0.1.0        │
│              │                    │ ──────────────────────────── │
│              │ SessionStart       │ Skill · search        原文    │
│              │ Hook · hooks.json  │ ──────────────────────────── │
└──────────────┴────────────────────┴──────────────────────────────┘
```

- 左栏按 `Claude Code`、`Codex` 分组，仅 Agent 可折叠，折叠状态存本地设置。
  Agent 下按 marketplace 显示不折叠的来源标题及已安装数量；以次级文字和留白区分，不加框线或额外缩进。
  没有插件的 Agent 显示 0，不推断它是否装了什么。
- 插件行显示插件自己的名字，生效版本以次级色 11pt 跟在同一行；放不下时整个版本让位，
  名字不截断。`name@marketplace` 全称留给 tooltip、中栏标题与右栏。
  第二行是插件介绍（取法同右栏：Codex 优先 `interface.shortDescription`，否则 `description`），
  单行截断，全文在 tooltip；清单里没有介绍的插件保持单行。
  同名插件由来源分组区分，插件行保留短名称；来源标题直接显示原始 marketplace 标识，不另起显示名。
- 中栏是这个插件提供的内容：Skill / Command / Subagent / Hook / MCP server，
  每行带类别标签；搜索作用于名称、说明与类别。
- 右栏先是插件身份：全称、版本、市场、Agent、状态与启用开关，然后是完整可选择的
  安装（或缓存）路径与选中条目的路径，最后是选中条目的正文。
  身份下的介绍：Codex 插件优先用清单 `interface.shortDescription`（Codex app 列表显示的
  那一句，由插件作者写在 `.codex-plugin/plugin.json`），长的 `description` 放 tooltip；
  Claude Code 清单没有对等字段，显示 `description`。
  Markdown 走 `SkillDocumentPresentation`，保留完整 YAML frontmatter，可切原文；
  JSON 片段（hook 事件、MCP server 配置）没有「预览」可言，一律原样等宽显示，不给原文开关。
- 扫描警告与损坏安装走骨架的页脚提示按钮，不混进正文。

视觉规范沿用 `docs/specs/skills-settings.md` 的那张表：同一套 `SkillsStyle` 尺寸、
`ShellStyle` 配色与控件，栏宽与折叠状态各存各的（`settings.plugins.*`）。

## 数据依据

### Claude Code

- `~/.claude/plugins/installed_plugins.json` 是安装清单。每个键是 `name@marketplace`，
  值是一个数组，每个作用域一条。**只收 `scope` 为 user 的安装**：project 与 local
  属于某个检出，设置页没有项目上下文。没写 `scope` 的记录按 user 处理。
  该条记录的 `version` 就是生效版本。
- `~/.claude/settings.json` 的 `enabledPlugins` 决定开关。装上和开着是两件事，
  清单里有、`enabledPlugins` 里没有或为 false，都记为「已停用」——缺键不能宣称已启用。
- 插件内容在 `installPath` 下：`skills/`、`commands/`、`agents/`、
  `hooks/hooks.json`（或根部 `hooks.json`）、`.mcp.json`、`.claude-plugin/plugin.json`。
- `~/.claude/plugins/cache` 里的历史版本目录不单独成条：清单已经指明了生效的那一个。

### Codex

- `codex plugin list --json` 的 `installed` 清单决定安装状态、启用状态和生效版本；
  用完整 `name@marketplace` 区分身份，包含停用项，不硬编码排除内置市场。
- 从 `plugins/cache/<marketplace>/<plugin>/<version>/` 读取清单指定版本的内容；
  尚未缓存的安装仍保留，不混入旧版本：来源为 `remote` 的由 Codex 按需下载，未落盘是正常状态，
  只在详情里说明、不进提示；本地来源缺缓存才进提示。缓存中不在清单的条目
  留在所属来源下并标注「仅缓存」，不计入来源及 Agent 已安装数，也不能启用。
- `CodexPluginInventory` 使用用户 PATH / 登录 shell PATH 查找 CLI，显式传入
  `CODEX_HOME`（默认 `~/.codex`），复用有超时和输出上限的工具进程，不经 shell。
  打开页和手动刷新时后台查询；失败保留本页上次成功数据、显示诊断并隐藏 Codex 开关。
  CLI 一次约两秒，本地文件只要几十毫秒：刷新先按上次成功的清单重读本地文件立即显示，
  CLI 返回后再校正；上次结果在进程内按配置根保留，重新打开设置页从它开始。
  从未成功时，这一步不列 Codex，等 CLI 返回。
  首次失败不以缓存冒充安装清单。诊断带可执行路径和配置根，便于排查会话环境差异。
- 清单可以写在 `.codex-plugin/plugin.json`，其中 `hooks` 可以内联，`mcpServers`
  既可以是对象，也可以是指向 `.mcp.json` 的相对路径；两种都认。

### 通用

- 扫描只读，不写锁文件、不写链接、不动插件内容。
- 坏掉的安装要看得见：清单里有而目录不存在、`installPath` 不是绝对路径、条目结构不对、
  本地来源的 Codex 安装在缓存里没有、缓存目录下没有版本目录——都进警告，能成条的仍然成条并带说明，
  不静默丢弃。
- 不硬编码用户账号、个人市场或本机绝对路径；测试一律用临时目录。

## 启停写入

唯一会改用户文件的入口是 `PluginCatalog.setEnabled(_:for:)`。

- 首次改动前把原件复制成 `<文件名>.lightty-backup`；已有备份就不再覆盖，
  那是「改之前的样子」，不是「上一次的样子」。
- 写同目录临时文件再原子替换，中途失败不留半成品。
- 改完先验再落盘：JSON 用标准解析回读那个布尔值，TOML 用同一套行扫描回读，
  验不过整份丢弃并报错。失败一律进诊断提示，绝不静默无事发生。
- Claude 的 `settings.json` 做**定点字节手术**：只重写目标布尔值的那几个字节，
  缺 `enabledPlugins` 或缺键时按现有缩进插入。不做「解析→改→再序列化」的往返，
  那会打乱键序、抹掉用户的排版，还会按我们的规则重排不认识的键。
- Codex 的 `config.toml` 做**按行定点编辑**：找到 `[plugins."<id>"]` 一张表，
  只改里面的 `enabled`（保留缩进与行尾注释）；表在但没有这个键就插一行；
  表不在就在文件末尾追加一张。仓库没有 TOML 依赖，也不该为一个布尔值把整份文档往返一遍。
  已知不覆盖的写法：`[plugins]` 表里用行内表声明同一个插件——检测到就报错并停手，
  不去追加一张会变成重复键的表。
- 只有缓存的 Codex 插件不能启用：开关不出现，原因写在详情里，调用写入会直接报错。
- 写成功之后才更新界面状态，失败时开关回到原位，不展示一个没落盘的状态。

## 实施结果与验收

- 新增 `PluginCatalog.swift`（只读扫描 + 唯一写入口）、`PluginConfigEdit.swift`
  （JSON/TOML 定点编辑）、`PluginsSettingsView.swift`（三栏与动作）。
- `SkillCatalog` 收窄：不再扫插件，`SkillOrigin` 去掉 `.plugin`，
  `SkillRecord` 去掉只服务于插件的 `sourceName` / `sourceVersion` / `provenanceNote`；
  Skills 页导航去掉 `Plugin skills` 分支，保留 `Built-in skills`。
- 2026-09-15 全量 `swift test`：LighttyTests 223 项 XCTest（1 项跳过）、
  LighttyCoreTests 173 项、Swift Testing 142 项，0 失败。
- UI 测试覆盖中英文、明暗主题与 1280 / 1080 / 900pt 三种宽度，全部用隐藏窗口的
  `cacheDisplay` 出图，不启动第二个 lightty 实例。

```sh
unset LIGHTTY_PANE_ID LIGHTTY_SOCK
LIGHTTY_UI_SNAPSHOT_DIR=/tmp/lightty-plugins-snapshots swift test --filter PluginsSettingsViewTests
```

截图文件名：`settings-plugins-<en|zh-Hans>-<NSAppearanceNameAqua|NSAppearanceNameDarkAqua>-<宽度>.png`。

## 未接入

- 安装、更新、卸载、添加市场，仍然走 Agent 自己的 CLI。
- 项目级（project / local）作用域的插件。
- 单条内容的启停（只有整个插件一个开关）。
- Claude 端「只有缓存」的历史版本不单列。
