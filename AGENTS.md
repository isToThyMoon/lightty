# 工作入口

- 定位实现、修改代码或运行测试时，从 [HANDOVER.md](HANDOVER.md) 查相关入口与约定；按本次改动涉及的范围读取章节及引用文档。
- 新增或修改 UI（布局、文字层级、颜色、图标、交互状态）前，阅读 [UI harness](docs/UI-harness.md) 的相关部分，再查所在区域的组件与 token。已有实现是复用起点；具体设计可按内容与交互需要调整，验证方式见其中的「工作与验证」。

## Agent 兼容检查

用户说「检查 Agent 兼容性」「检查 Claude Code / Codex 对接」或要求升级后的兼容验证时，在仓库根目录执行 `python3 scripts/check-agent-compatibility.py`，检查本机已安装的两家 CLI。仅本机按需执行，不自动升级 CLI 或触发云端任务。

完成后读取本次 `report.json`，汇报实际 CLI 版本、各功能组结果、失败原因及报告路径。缺 CLI、跳过或未检查不能报为通过；检查范围不含真实 TUI / 模型交互。前置条件、报告位置、fixture 模式与失败定位见 [兼容验证](docs/agent-compatibility.md)。
