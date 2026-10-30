# 设置页读写的配置

设置页（Skills / Plugins / MCP / Handoff）读写两家的哪些配置文件和接口。总览与入口见[依赖清单](../agent-dependencies.md)。

只读为主，写入只改一个布尔值，先备份（`*.lightty-backup`）再原子替换。

| 页面 | Claude Code | Codex | 写入 |
|---|---|---|---|
| Skills | `~/.claude/skills`；共享目录 `~/.agents/skills` 与 `~/.agents/.skill-lock.json` | `$CODEX_HOME/skills`，内置技能 `skills/.system` | 不写技能目录；收藏 / 标签存 `~/.lightty/skills-organization.json` |
| Plugins | `~/.claude/plugins/installed_plugins.json` + `settings.json` 的 `enabledPlugins`；使用计数读 `~/.claude.json` 的 `pluginUsage` / `skillUsage` | 常驻 app-server 的 `plugin/installed` 拿已装清单（含远端装的；远端部分拉不到只回本地的，不报错），再读 `plugins/cache` 里的内容；失败沿用上次结果 | Claude 改 `settings.json` 的 `enabledPlugins`；Codex 改 `config.toml` 的 `[plugins."…"].enabled` |
| MCP | `~/.claude.json` 的 `mcpServers`（没有启用开关，配了就是开着） | `config.toml` 的 `[mcp_servers.*]` 与其 `enabled` | 只有 Codex 可切换 |
| Handoff | 读插件安装状态（见[状态与上下文 hook](status-hooks.md)） | 同左 | 无 |

各页的产品行为见 `docs/specs/skills-settings.md`、`plugins-settings.md`、`mcp-settings.md`、`handoff-settings.md`。
