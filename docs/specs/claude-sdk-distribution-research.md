# Claude Agent SDK 本地会话 helper：分发与接口核验

核验日期：2026-09-07。范围仅为官方 SDK 的本地会话列表，不启动 Agent、不读取用户真实会话。本文包含官方资料核验及隔离实验；不等于完成发布验收。

## 实验结论

**官方 SDK + 独立本地 helper 路线技术验证通过，推荐按此接入，不编写 Swift transcript parser。**
接口、运行时、受限执行和合成会话覆盖已验证；最终发布许可、Developer ID 签名/公证、Intel 和旧系统仍待验收。App 已通过 `ClaudeSessionCatalog` 接入独立 helper，SDK 不进入 Swift target，依赖由构建准备脚本及锁文件管理。

复现脚本：[probe-claude-sdk.mjs](../../scripts/probe-claude-sdk.mjs)。脚本只生成临时合成数据，保留 `report.json` 供检查。SDK 包保持未修改，省略可选原生 CLI，保留全部 peer dependencies。

### 环境与覆盖

- 本机：Apple Silicon、macOS 26.5.2。
- SDK：npm `@anthropic-ai/claude-agent-sdk@0.3.263`；peer 解析版本为 `@anthropic-ai/sdk@0.124.0`、`@modelcontextprotocol/sdk@1.30.0`、`zod@4.5.4`。生产构建必须另行保存 lockfile，不能每次解析范围依赖。
- 运行时：官方 Node **22.23.2** arm64 独立二进制，只有系统动态库依赖。下载 SHA-256：`61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6`，与官方 SHASUMS 一致。[官方产物](https://nodejs.org/dist/v22.23.2/)、[校验值](https://nodejs.org/dist/v22.23.2/SHASUMS256.txt)
- 使用 `CLAUDE_CONFIG_DIR` 隔离来源；worker 不继承认证、开发环境 PATH 或 hook 环境。复制 Node 和 worker 到临时目录，禁止读取用户主目录，不依赖用户安装的 Node/Claude。
- macOS sandbox-exec 强制禁止联网、文件写入、子进程创建；1,000 和 10,000 条样本均通过。测试前后对会话目录内容、大小、mtime 做指纹比较，未改变。
- 覆盖跨两个项目、中文/空格 cwd、自定义标题、毫秒时间、分页、项目筛选、programmatic/sidechain 过滤、损坏记录、半写尾行、8 MiB 大 transcript。没有执行 `query` 或真实 `resume`。
- 项目筛选测试显式 `includeWorktrees:false`；Git worktree 枚举、其他历史版本和真实账号覆盖率尚未验证。合成样本不是所有 Claude 版本的兼容承诺。

### 性能与包体

以下为 Node 22 的独立 worker 单次列表调用，时间包含已缓存文件，不是清空系统缓存后的冷启动承诺；首屏为 100 条。进程时间包含 sandbox 启动、SDK 导入和列表读取，不含 Swift UI 绘制。

| 历史量 / 请求 | SDK 导入 | 列表读取 | 完整进程 | 峰值 RSS |
| --- | --- | --- | --- | --- |
| 1,000 / 首屏 100 | 45 ms | 18 ms | 92 ms | 97 MiB |
| 1,000 / 全部 | 46 ms | 51 ms | 127 ms | 129 MiB |
| 10,000 / 首屏 100 | 45 ms | 78 ms | 154 ms | 151 MiB |
| 10,000 / 全部 | 46 ms | 475 ms | 556 ms | 419 MiB |

1,000 和 10,000 的完整功能检查各运行三次；新复制的 Node 首次进程运行约 1–2.2 秒，但它包含多轮检查，不能等同于首屏延迟。接入 UI 必须有加载态，后台读取，避免每个窗口重复拉取。

产物字节数：SDK + 所有已安装 peer dependencies **31,366,373 B**；Node 22 arm64 **112,937,728 B**。合计约 **144 MB（138 MiB）未压缩**，tar+gzip（含 Node LICENSE）为 **45,451,806 B，约 45 MB**。这是辅助依赖单架构测算，不是最终 DMG 增量，不含 Intel runtime。默认可选 Claude arm64 包单独声明约 199 MB 解包体积，本列表方案无需捆绑它。

生产 Interface 为 `SessionCatalogProvider.page(archived:cursor:cancelled:)`，每次返回至多 100 条。Swift helper 进程有 15 秒超时、1 MiB 输出上限、取消及终止回收；库按页合并、去重，用户按需加载更多。SDK offset 分页仍可能重扫文件元数据，不能视为数据库索引游标；连续翻页总成本仍需规模验收。

### 签名与最低系统

- 本机 Node 24.19.0 二进制最低 macOS 13.5，不符合 lightty 当前 13.0 支持范围；Node 22.23.2 二进制声明最低 11.0，可作为候选，但未替代旧系统真机验收。
- 临时 Node 22 副本使用 ad-hoc 签名、Hardened Runtime、**仅 `com.apple.security.cs.allow-jit`**，`codesign --verify --strict` 通过，1,000 条受限 worker 检查通过。此权限只属于 helper，不加到 lightty 主 App。
- 禁用 JIT 的尝试未通过：Node `--jitless` 隐藏 WebAssembly，SDK 导入触发 Node 内建 undici 初始化失败。保留官方运行时默认行为，不通过修改 SDK 或伪造网络库绕过。
- 未完成 Developer ID 最终嵌套签名、公证、Gatekeeper 新机器启动或 x86_64 验收；不据 ad-hoc 成功声称可直接发布。

### 接入决策

1. 固定 SDK、Node、lockfile 与校验值；依赖随构建产物分发，不要求用户手装运行时、不在运行时下载。开发先运行 `node scripts/prepare-claude-helper.mjs`；打包自动传 `--all` 准备双架构。
2. `ClaudeSessionCatalog` 只负责启动 helper 和将明确版本的 JSON 元数据映射为 `AgentSession`。不向 UI 暴露 SDK 字段，不导出消息全文。
3. 查询固定 `includeProgrammatic:false`、不传 `dir/sessionStore`；只发现本机记录。项目组织继续由 lightty 保存，禁止回写原始会话。
4. 生命周期带超时、输出上限、取消和进程回收；按页运行，加载完释放，避免常驻几百 MiB 的无用进程。已通过两页合成数据、超时、取消、异常退出和输出限额测试。
5. 恢复继续用用户安装的 `claude --resume <id>` 及原配置根，不通过 SDK 启动对话，不注入 prompt。
6. 完成许可与最终分发门槛后再发布；技术实验不构成再分发许可结论。

复现：

```sh
probe_packages=$(mktemp -d /tmp/lightty-claude-sdk.XXXXXX)
npm install --prefix "$probe_packages" --ignore-scripts --omit=optional --no-audit --no-fund @anthropic-ai/claude-agent-sdk@0.3.263
node scripts/probe-claude-sdk.mjs "$probe_packages" 1000
node scripts/probe-claude-sdk.mjs "$probe_packages" 10000
```

请用上述已验证的 Node 22 重现部署候选结果；使用其他 Node 只代表该组合的实验。

## 接口与数据边界

TypeScript 的公开入口是 `@anthropic-ai/claude-agent-sdk` 的 `listSessions(options)`，不是云端 Managed Agents 的 `client.beta.sessions.list()`。省略 `dir` 枚举所有本地项目；结果以 `lastModified` 倒序，时间单位毫秒。字段包括 `sessionId`、`summary`、`cwd`、`customTitle` 等。[官方 TypeScript 参考](https://code.claude.com/docs/en/agent-sdk/typescript)

本次核验 npm 发布版 **0.3.263** 的 `sdk.d.ts` 还包含：

- `limit` 和 `offset`：分页。
- `includeProgrammatic`：默认 `true`；传 `false` 排除 SDK/headless 和 daemon 会话，目标是与终端 `/resume` 的选择范围一致。
- `includeWorktrees`：限定 `dir` 时可包含 Git worktree，默认 `true`。
- `sessionStore`：可选择自定义存储；lightty 不传此项，保持本机模式。

发布包是本次 API 判断的直接依据，网页版参考可能尚未展示全部新增选项。[npm 发布元数据](https://registry.npmjs.org/@anthropic-ai%2fclaude-agent-sdk/0.3.263)

官方会话浏览器教程明确说明这些操作针对 `~/.claude/projects/` 的本地文件，与 CLI 共享 transcript；列表读取文件属性和首尾片段，不解析整份对话，也不启动 Agent。因而列表不需要模型请求，但不能把整个 SDK 的所有功能都称为“不会联网”。限定本地列表且不提供外部 `sessionStore` 才是这里的边界。[官方会话浏览器教程](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)

发布包 `sdk.mjs` 中，`listSessions` 在无 `sessionStore` 时直接转入文件列表实现；配置根目录读取 `CLAUDE_CONFIG_DIR`，否则使用主目录下 `.claude`。helper 应在进程启动前固定该变量，返回结果身份包含相同配置根；恢复继续调用用户安装的 `claude --resume <id>`。不调用 `query()`、`startup()` 或变更会话的 API。

## 运行时和可选 CLI

| 路线 | 已证实的要求 | 不应混淆的部分 |
| --- | --- | --- |
| TypeScript 0.3.263 | npm 声明 Node `>=18`；平台 CLI 为 optional dependencies；另有 peer dependencies | 支持的最低 Node 版本不等于建议捆绑的受维护版本 |
| Python 仓库当前 0.2.152 | Python `>=3.10`；依赖 anyio、sniffio、mcp、jsonschema 等 | 官方发布 wheel 默认包含 Claude CLI，但文件列表不需要启动 CLI |

来源：[npm 元数据](https://registry.npmjs.org/@anthropic-ai%2fclaude-agent-sdk/0.3.263)、[Python pyproject](https://github.com/anthropics/claude-agent-sdk-python/blob/main/pyproject.toml)、[Python 安装说明](https://github.com/anthropics/claude-agent-sdk-python/blob/main/README.md)。

`--omit=optional` 可避免安装 npm 平台 CLI，但“只有列表功能时可以安全省略”的发布门槛应是：锁定具体版本，在无 Claude CLI、无认证、隔离配置目录且网络禁止的条件下运行列表测试。仅凭 optional 标签不能推断所有 SDK 功能都可运行。不要删除依赖后仍向上层暴露通用 Agent SDK 能力。

## 许可：SDK 不等同于普通 Anthropic API SDK

- **TypeScript Agent SDK** 的 `LICENSE.md` 是 Anthropic 保留权利并指向 Commercial Terms；不是 MIT。README 说明该条款适用于用 SDK 支撑面向自己用户的产品，单独许可的组件除外。[TS LICENSE](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/LICENSE.md)、[TS README](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/README.md)
- **Python 源码仓库** 的 LICENSE 是 MIT，要求保留版权与许可声明；但 README 同时指向 Commercial Terms，并明确单独许可组件例外。因此不能把随 wheel 捆绑的 Claude CLI 和所有依赖一概视为 MIT。[Python LICENSE](https://github.com/anthropics/claude-agent-sdk-python/blob/main/LICENSE)、[Python README](https://github.com/anthropics/claude-agent-sdk-python/blob/main/README.md)
- Commercial Terms 允许按条款使用服务来支撑自己的产品，但这不等于本页已经确认可任意拆分、修改或重新分发 SDK/CLI 二进制。尤其 TypeScript tree-shaking / vendoring / CLI 再分发，应基于最终锁定产物核对条款和组件许可；必要时向 Anthropic 确认。本页是工程核验，不是法律意见。[Commercial Terms](https://www.anthropic.com/legal/commercial-terms)

因此优先试验“完整未修改的 SDK JS 包（省略不需要的平台 CLI）+ 自有薄 helper”，不复制反混淆函数，也不把裁剪源码冒充官方 SDK。发布时必须建立运行时、SDK、间接依赖和可选二进制的完整 notices 清单；正式再分发资格仍须确认。

## macOS 分发门槛

独立 helper 进程可以让 Swift 模块只依赖稳定的 JSON 协议，但并不会消除运行时分发成本。不能假设用户安装了 Node/Python，或系统 Python 永远可用。

Developer ID 直发需要对所有分发的可执行文件签名，使用 Hardened Runtime 与时间戳，并完成 notarization。嵌入式 JS 运行时可能需要 JIT 相关权限；具体 entitlement 必须对最终构建验证，不给主 App 盲目放宽权限。[Apple notarization 要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)

未完成的发布事项：x86_64 运行、最低 macOS 真机、离线全新机器启动、最终 App/DMG 包体及冷启动、Developer ID 签名/notarization、SDK 再分发许可。arm64 运行时动态库和字节体积见上述实测。Node 单文件打包仍嵌入 Node，不会凭空消除运行时体积。[Node 单文件应用文档](https://nodejs.org/api/single-executable-applications.html)

## 决策原则

官方 SDK 给我们的是公开 API 和官方维护的格式适配器，**不是底层 transcript 格式永不变化的承诺**。锁定版本、合成样本、最小输出契约、可取消 helper 及升级回归仍然必要。当前适合验证官方 helper 路线；在运行和分发实验完成前，不宣称已经具备无额外安装的可发布集成。
