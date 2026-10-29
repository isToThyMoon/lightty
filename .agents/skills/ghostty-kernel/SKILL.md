---
name: ghostty-kernel
description: 修改或升级 lightty 的 Ghostty 内核（vendor/ghostty、lightty-patches 分支、GhosttyKit.xcframework、libghostty C API）时使用；只跑 swift build 不会重建内核。
---

# 改 Ghostty 内核

内核是带补丁的 ghostty fork，分支 `lightty-patches`，克隆在 `vendor/ghostty`（不入本仓库），需要 zig 0.16.0。

1. 改内核前读 [libghostty 契约](../../../docs/libghostty-embedding.md) 的硬约束；升级 vendor 时按 [适配核查清单](../../../docs/parity-plan.md) 逐项复核 bridge。
2. 在 `vendor/ghostty` 里改动并提交到 `lightty-patches` 分支。
3. 重建内核：`(cd vendor/ghostty && zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast)`。
4. 同步产物：`scripts/sync-ghosttykit.sh`（复制到 `Frameworks/` 并改成 SwiftPM 要求的命名）。
5. 构建与验证：`scripts/check.sh`（含终端适配门禁 `scripts/check-terminal-adapter-parity.sh`）。

完成标准：`scripts/check.sh` 通过，且 `Frameworks/GhosttyKit.xcframework` 来自本次重建（sync 脚本输出 `synced:`）。发布流水线按 `GHOSTTY_REF` 重新拉内核，补丁要推到 fork 才会进 release。
