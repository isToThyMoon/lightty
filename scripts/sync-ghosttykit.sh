#!/bin/bash
# 把 vendor/ghostty 构建出的 GhosttyKit.xcframework 同步为 SwiftPM 可用的形态。
# SwiftPM 的 binaryTarget 要求静态库以 lib 前缀命名，而 zig build 产物叫
# ghostty-internal.a——不改 vendor（再生产物），复制到 Frameworks/ 后改名并修 plist。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ghostty/macos/GhosttyKit.xcframework"
DST="$ROOT/Frameworks/GhosttyKit.xcframework"

[ -d "$SRC" ] || { echo "missing $SRC — run: (cd vendor/ghostty && zig build -Demit-macos-app=false)"; exit 1; }

rm -rf "$DST"
mkdir -p "$ROOT/Frameworks"
cp -R "$SRC" "$DST"
mv "$DST/macos-arm64_x86_64/ghostty-internal.a" "$DST/macos-arm64_x86_64/libghostty.a"
plutil -replace "AvailableLibraries.0.BinaryPath" -string "libghostty.a" "$DST/Info.plist"
plutil -replace "AvailableLibraries.0.LibraryPath" -string "libghostty.a" "$DST/Info.plist"
echo "synced: $DST"
