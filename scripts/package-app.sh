#!/bin/bash
# 把 SwiftPM 产物打成可分发的 lightty.app（+ 可选 DMG）。
#
# 用法：
#   scripts/package-app.sh [version]            # 默认版本取 git describe（无 tag 则 0.0.0-dev）
#   SIGN_IDENTITY="Developer ID Application: …" scripts/package-app.sh 1.0.0
#   MAKE_DMG=1 scripts/package-app.sh 1.0.0     # 附带产出 dist/lightty-<version>.dmg
#
# 签名策略：SIGN_IDENTITY 显式指定 > 钥匙串里的 Developer ID Application >
# ad-hoc（"-"，仅本机可跑，分发会被 Gatekeeper 拦）。
# 公证（notarytool）是发布流水线的事，不在本脚本内。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0-dev)}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${BUNDLE_ID:-com.istothymoon.lightty}"
DIST="$ROOT/dist"
APP="$DIST/lightty.app"
GHOSTTY_SHARE="$ROOT/vendor/ghostty/zig-out/share/ghostty"

# ── 前置检查 ────────────────────────────────────────────────────────────────
[ -d "$GHOSTTY_SHARE/themes" ] || {
    echo "missing $GHOSTTY_SHARE — run: (cd vendor/ghostty && zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast) && scripts/sync-ghosttykit.sh"
    exit 1
}

# ── 构建（universal：xcframework 本身就是 arm64+x86_64 双架构）─────────────
echo "▸ swift build -c release (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
BIN="$ROOT/.build/apple/Products/Release/lightty"
[ -x "$BIN" ] || BIN="$ROOT/.build/release/lightty"
[ -x "$BIN" ] || { echo "build output not found"; exit 1; }

# ── 组装 bundle ─────────────────────────────────────────────────────────────
echo "▸ assemble $APP  (v$VERSION build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/lightty"
# agent hook helper：注册进 claude/codex 配置的那条命令。用户会把 app 拖来拖去，
# 所以配置里写的是 ~/.lightty/bin/lightty-hook symlink，指向这里
HOOK="$(dirname "$BIN")/lightty-hook"
[ -x "$HOOK" ] || { echo "lightty-hook build output not found"; exit 1; }
cp "$HOOK" "$APP/Contents/MacOS/lightty-hook"
# SwiftPM 资源包（本地化 strings 等）：Bundle.module 会在主 bundle 的
# Resources 里按名查找
cp -R "$(dirname "$BIN")/lightty_lightty.bundle" "$APP/Contents/Resources/"
# Sparkle 动态框架：开发态靠 @loader_path 同目录找到，bundle 里进 Frameworks/
# 并给可执行补 rpath
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/lightty"
# libghostty 运行时资源。内核约定（termio/Exec.zig）：TERMINFO 指向
# "资源目录父目录/terminfo"，所以 terminfo 必须放在 ghostty/ 的旁边，
# 与官方 app bundle 布局一致——缺了它 TERM=xterm-ghostty 查无能力描述，
# shell 的 SIGWINCH prompt 重绘会错位（表现为侧栏动画期间残留旧 prompt）。
cp -R "$GHOSTTY_SHARE" "$APP/Contents/Resources/ghostty"
cp -R "$GHOSTTY_SHARE/../terminfo" "$APP/Contents/Resources/terminfo"
[ -d "$GHOSTTY_SHARE/../locale" ] && cp -R "$GHOSTTY_SHARE/../locale" "$APP/Contents/Resources/locale"
# 图标（有则带上；暂缺时用系统默认图标）
[ -f "$ROOT/assets/lightty.icns" ] && cp "$ROOT/assets/lightty.icns" "$APP/Contents/Resources/lightty.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>lightty</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>lightty</string>
    <key>CFBundleDisplayName</key><string>Lightty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>lightty</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>SUFeedURL</key><string>https://github.com/isToThyMoon/lightty/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>f072X9FONA/coPDuRgaSX9r/wPLjcSwxr6wFmTeWKy4=</string>
</dict>
</plist>
PLIST

# ── 内核资源契约自检 ────────────────────────────────────────────────────────
# 内核从 resources_dir 派生的全部路径（源码审计 2026-08-30，vendor 升级后复核）：
#   shell_integration.zig → resources_dir/shell-integration
#   Config themes         → resources_dir/themes
#   termio/Exec.zig       → dirname(resources_dir)/terminfo（TERM=xterm-ghostty 的能力库）
#   os/i18n.zig           → dirname(resources_dir)/locale
for required in \
    "Contents/Resources/ghostty/shell-integration" \
    "Contents/Resources/ghostty/themes" \
    "Contents/Resources/terminfo/78/xterm-ghostty" \
    "Contents/Resources/locale" \
    "Contents/Resources/lightty_lightty.bundle" \
    "Contents/Frameworks/Sparkle.framework" \
    "Contents/MacOS/lightty-hook"; do
    [ -e "$APP/$required" ] || { echo "✗ bundle 缺内核契约路径: $required"; exit 1; }
done
echo "▸ kernel resource contract OK"

# ── 签名 ───────────────────────────────────────────────────────────────────
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ]; then
    echo "▸ codesign: $IDENTITY (hardened runtime)"
    # 由内向外签：内嵌框架（--deep 覆盖 Sparkle 的 XPC/Autoupdate）→ hook helper
    # → app 本体。lightty-hook 是 Contents/MacOS 里的第二个 Mach-O，签 app bundle
    # 不会顺带签它，必须单独来一发，否则它在用户机上跑不起来（hook 静默失效）
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --deep \
        "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp \
        "$APP/Contents/MacOS/lightty-hook"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
    echo "▸ codesign: ad-hoc（未找到 Developer ID，仅本机可用）"
    codesign --force --sign - --deep "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - "$APP/Contents/MacOS/lightty-hook"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "  signature OK"

# ── DMG（可选）─────────────────────────────────────────────────────────────
if [ "${MAKE_DMG:-0}" = "1" ]; then
    DMG="$DIST/lightty-$VERSION.dmg"
    echo "▸ hdiutil → $DMG"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Lightty" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    echo "  $(du -h "$DMG" | cut -f1) $DMG"
fi

echo "done: $APP"
