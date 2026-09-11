#!/bin/bash
# Regression check for Lightty's libghostty configuration layering:
# isolated bundled configuration, or bundled defaults with user overrides.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIGHTTY_BIN="${LIGHTTY_BIN:-$ROOT/.build/debug/lightty}"

if [[ ! -x "$LIGHTTY_BIN" ]]; then
    echo "missing lightty binary: $LIGHTTY_BIN" >&2
    exit 2
fi

# Architectural guard: one bundled baseline is allowed; there is still no CLI,
# ~/.config/lightty, or post-finalize terminal override layer.
if rg -n 'ghostty_config_load_cli_args|\.config/lightty/config' \
    "$ROOT/Sources/lightty"; then
    echo "lightty must not add another terminal configuration source" >&2
    exit 1
fi
load_file_count="$(rg -n 'ghostty_config_load_file\(' \
    "$ROOT/Sources/lightty/GhosttyRuntime.swift" | wc -l | tr -d ' ')"
if [[ "$load_file_count" != "1" ]]; then
    echo "expected one centralized bundled config file loader, found $load_file_count" >&2
    exit 1
fi
for resource in lightty-default.ghostty; do
    if [[ ! -f "$ROOT/Sources/lightty/Resources/$resource" ]]; then
        echo "missing bundled terminal config: $resource" >&2
        exit 1
    fi
done
if ! rg -q '^[[:space:]]*font-family[[:space:]]*=[[:space:]]*"Maple Mono NF CN"' \
    "$ROOT/Sources/lightty/Resources/lightty-default.ghostty"; then
    echo "the bundled Lightty defaults must select Maple Mono NF CN" >&2
    exit 1
fi
FONT_MANAGER="$ROOT/Sources/lightty/TerminalFontManager.swift"
if rg -n 'applicationSupportDirectory' "$FONT_MANAGER"; then
    echo "downloaded fonts must use the normal user font installation path" >&2
    exit 1
fi
if ! rg -q 'Library/Fonts' "$FONT_MANAGER"; then
    echo "downloaded fonts must install to ~/Library/Fonts" >&2
    exit 1
fi
if rg -n 'CTFontManagerRegisterFonts' "$FONT_MANAGER"; then
    echo "fonts in ~/Library/Fonts must use normal system discovery, not dynamic registration" >&2
    exit 1
fi
FONT_PREVIEW="$ROOT/Sources/lightty/TerminalFontDownloadPreview.swift"
if rg -n 'URLSession|FileManager|TerminalFontManager|CTFontManager|Library/Fonts' \
    "$FONT_PREVIEW"; then
    echo "font download preview must remain memory-only" >&2
    exit 1
fi
if rg -n '^[[:space:]]*appearance[[:space:]]*=' \
    "$ROOT/Sources/lightty/TerminalWindow.swift"; then
    echo "TerminalWindow must not force an appearance onto the terminal host" >&2
    exit 1
fi

KEYS='^(background|foreground|background-opacity|background-blur|cursor-style) = '

# lightty 的设置存在自己的文件里，读的时候不看命令行参数，所以开关必须靠一份真实的
# 设置文件来摆。这里给每次探测临时造一份，用 LIGHTTY_PREFERENCES_DIR 指过去；
# 用户真实的 ~/.lightty/preferences.json 全程不读也不写。
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

preferences_with_built_in_theme() {
    local enabled="$1"
    local dir="$SCRATCH/preferences-$enabled"
    mkdir -p "$dir"
    cat > "$dir/preferences.json" <<JSON
{"format":"lightty.preferences","version":1,"values":{"lightty.terminalTheme.useBuiltIn":$enabled}}
JSON
    printf '%s' "$dir"
}

BUILT_IN_ON="$(preferences_with_built_in_theme true)"
BUILT_IN_OFF="$(preferences_with_built_in_theme false)"

probe() {
    local xdg_config_home="$1"
    local preferences="${2:-$BUILT_IN_ON}"
    env \
        HOME="$ROOT/Tests/Fixtures/GhosttyConfigBaseline" \
        XDG_CONFIG_HOME="$xdg_config_home" \
        LIGHTTY_PREFERENCES_DIR="$preferences" \
        "$LIGHTTY_BIN" --print-effective-terminal-config | sed -n -E "/$KEYS/p"
}

expected_baseline=$'background = #eff1f5\nforeground = #4c4f69\nbackground-opacity = 0.88\nbackground-blur = 30\ncursor-style = block'
actual_baseline="$(probe "$ROOT/Tests/Fixtures/GhosttyConfigBaseline")"
[[ "$actual_baseline" == "$expected_baseline" ]] || {
    echo "bundled terminal defaults mismatch" >&2
    diff -u <(printf '%s\n' "$expected_baseline") \
        <(printf '%s\n' "$actual_baseline") || true
    exit 1
}

expected_override=$'background = #010203\nforeground = #a1b2c3\nbackground-opacity = 0.42\nbackground-blur = 7\ncursor-style = underline'
actual_isolated="$(probe "$ROOT/Tests/Fixtures/GhosttyConfigOverride")"
[[ "$actual_isolated" == "$expected_baseline" ]] || {
    echo "built-in configuration loaded user overrides" >&2
    exit 1
}
actual_override="$(probe "$ROOT/Tests/Fixtures/GhosttyConfigOverride" "$BUILT_IN_OFF")"
[[ "$actual_override" == "$expected_override" ]] || {
    echo "user overrides did not apply with built-in configuration disabled" >&2
    diff -u <(printf '%s\n' "$expected_override") \
        <(printf '%s\n' "$actual_override") || true
    exit 1
}

actual_locked_theme="$(probe "$ROOT/Tests/Fixtures/GhosttyThemeOverride")"
[[ "$actual_locked_theme" == "$expected_baseline" ]] || {
    echo "built-in theme did not override the user theme key" >&2
    diff -u <(printf '%s\n' "$expected_baseline") \
        <(printf '%s\n' "$actual_locked_theme") || true
    exit 1
}

expected_user_theme=$'background = #282a36\nforeground = #f8f8f2\nbackground-opacity = 0.88\nbackground-blur = 30\ncursor-style = block'
actual_user_theme="$(probe "$ROOT/Tests/Fixtures/GhosttyThemeOverride" "$BUILT_IN_OFF")"
[[ "$actual_user_theme" == "$expected_user_theme" ]] || {
    echo "disabling the built-in theme did not restore the user theme" >&2
    diff -u <(printf '%s\n' "$expected_user_theme") \
        <(printf '%s\n' "$actual_user_theme") || true
    exit 1
}

printf '%s\n' "$actual_baseline"
printf '%s\n' "bundled isolation + user/recursive overrides: OK"
