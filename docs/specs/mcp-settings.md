# 独立 MCP server 设置页

## 这一页管什么

只管**独立配置的** MCP server：用户自己写进 Agent 配置文件的那些。
插件自带的 server 不在这里，它们在 Plugins 页里，随插件一起出现。

同一台服务器不该在两个页面各列一遍——这正是把插件技能移出 Skills 页时要避免的那件事。
判断标准很简单：这台 server 是谁写进配置的。用户写的归这一页，插件带来的归那个插件。

## 读哪里

- **Codex**：`~/.codex/config.toml` 的 `[mcp_servers.<name>]`，`CODEX_HOME` 可改。
  子表（`[mcp_servers.<name>.env]` 之类）属于同一台 server，跟着它走。
- **Claude Code**：`~/.claude.json` 顶层的 `mcpServers`。
  项目级的 server 写在各自检出的 `.mcp.json` 里，这一页不读——设置页没有项目上下文，
  不去猜当前是哪个项目，这一条与 Plugins 页只收 user scope 安装同理。

## 启用状态

- **Codex**：写了 `enabled = false` 才算停用。**默认是开的**，这一条和插件相反：
  插件缺 `enabled` 键记作未启用（缺键不能宣称已启用），而 server 登记在 config.toml
  里就是要跑的，否则没写 `enabled` 的那些永远用不了。
- **Claude Code**：用户级 server 没有启用开关，配置在那里就是开着的。这一页如实说明，
  不画一个点不动的开关。

## 写入

只改 `enabled` 这一个值：首次改动前留一份 `.lightty-backup`（之后不再覆盖），
同目录临时文件加原子替换，落盘前用独立实现回读校验，验不过整份丢弃并报错。
不做 TOML 全量解析回写——那会丢掉注释和排版。

没有 `[mcp_servers.<name>]` 表的 server 不给建表：这一页只改已登记的，
没登记的该由 Agent 自己写。请求会被拒绝，配置文件一个字不动。

## 界面

三栏：左栏「全部 / Claude Code / Codex」带数量，中栏列 server（第二行是命令或地址），
右栏是这台 server 的身份、启用开关、配置文件路径，以及**配置原文**。

正文是原文而不是重新格式化的结果：展示的和真正生效的必须是同一段字。

## 不做的

- 连上去列出它暴露的 tools / resources / prompts——那要真的启动服务器。
- 新增、删除、编辑 server 配置。
- 项目级 server。
