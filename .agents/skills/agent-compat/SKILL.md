---
name: agent-compat
description: 检查 lightty 与本机 Claude Code / Codex CLI 的对接兼容性。用户说「检查 Agent 兼容性」「检查 Claude Code / Codex 对接」、升级两家 CLI 后要验证、或改完对接代码要核对时使用。
---

# Agent 兼容检查

只在本机按需运行：检查本机已安装的两家 CLI，不升级 CLI、不安装插件、不触发云端任务或模型请求。

1. 在仓库根目录运行 `python3 scripts/check-agent-compatibility.py`。只核 fixture 回归时加 `--fixtures-only`，此时本机接口记为 `not-checked`，不产生 CLI 兼容结论。
2. 读本次运行的 `.build/agent-compatibility/<本次运行>/report.json` 与失败组的日志。
3. 汇报：实际 CLI 版本、各功能组结果、失败原因、报告路径。缺 CLI、跳过、筛选后零测试、超时都如实报为未通过或未检查。检查范围不含真实 TUI / 模型交互，汇报时写明。

完成标准：每个功能组都有「通过 / 失败（原因）/ 未检查（原因）」之一，并附报告路径。

失败定位：按失败组进 [依赖清单](../../../docs/agent-dependencies.md) 找对应实现，适配入口表与运行时诊断见 [兼容验证](../../../docs/agent-compatibility.md)。
