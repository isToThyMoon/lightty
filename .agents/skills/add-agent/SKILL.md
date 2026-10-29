---
name: add-agent
description: 给 lightty 接入一家新的 Agent CLI（除 Claude Code / Codex 之外）或改一家 Agent 的常量（可执行名、配置根、hook 事件表、续接写法、插件清单、会话日志格式）时使用。
---

# 加一家 Agent

一家 Agent 的常量在 `AgentSpec`（LighttyCore）里，值写在 `Sources/LighttyCore/Agents/<家名>Agent.swift`，参照现有的 `ClaudeAgent.swift`、`CodexAgent.swift`。按家的行为差异还散在别处：穷举 switch 会报编译错误，`== .codex` 一类比较和写死的家名列表不会报，漏掉一处就静默走某一家的分支。

1. 读 [依赖清单](../../../docs/agent-dependencies.md)，列出新 CLI 在每个接触点（命令、hook、文件、安装方式）上的对应物；只用它的官方接口，问不出来的能力记为「问不出来」，不读进程表或目录反推（见 [会话接口清单](../../../docs/specs/agent-session-apis.md)）。
2. 给 `SessionAgent` 枚举补 case，按编译错误补齐：`spec` 那个 switch 与几处枚举桥（HookAgent / LaunchAgent / PluginAgent）。
3. 新建 `Sources/LighttyCore/Agents/<家名>Agent.swift`，填完 `AgentSpec` 的全部字段。
4. 编译器提示不到的两处另外补：`SessionCatalogSource.makeProvider`（造 provider；LighttyCore 不依赖 app 目标），`HookMarketplace` 里两份插件清单的内容。
5. 会话操作（列表、改名、删除、占用）新写一个 `XxxSessionProvider`，Agent 差异只放在 provider 里。
6. 找编译器报不出的分支：`rg -n 'case \.claude|case \.codex|== \.claude|== \.codex|"claude", ?"codex"' Sources`。目前集中在 `PluginCatalog`、`SessionLibrary`、`HookInstaller`、`HookMarketplace`、`AgentLaunchPreference`、`TranscriptSpeed`、`PluginsSettingsView` / `SkillsSettingsView` / `MCPCatalog`、`SessionsSidebarContent`、`PaneStatusStore`、`AgentSessionIcon`，以及 `lightty-hook` 的 `--agent` 解析。逐条判断新家走哪个分支；能变成 `AgentSpec` 字段的就移进去。
7. 在 `AgentContractTests` 与对应 fixture 场景测试里加这一家，界面文案补中文，跑 `scripts/check.sh`。

完成标准：`scripts/check.sh` 通过；依赖清单补上新的一列；第 6 步命令列出的每一处都已判断过新家的走向。
