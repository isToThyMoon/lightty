#!/bin/bash
# Regression check for Lightty's libghostty configuration layering:
# bundled defaults, user Ghostty configuration, then the optional theme key.
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
for resource in lightty-default.ghostty lightty-theme.ghostty; do
    if [[ ! -f "$ROOT/Sources/lightty/Resources/$resource" ]]; then
        echo "missing bundled terminal config: $resource" >&2
        exit 1
    fi
done
if rg -n '^[[:space:]]*appearance[[:space:]]*=' \
    "$ROOT/Sources/lightty/TerminalWindow.swift"; then
    echo "TerminalWindow must not force an appearance onto the terminal host" >&2
    exit 1
fi

KEYS='^(background|foreground|background-opacity|background-blur) = '
probe() {
    local xdg_config_home="$1"
    shift
    env \
        HOME="$ROOT/Tests/Fixtures/GhosttyConfigBaseline" \
        XDG_CONFIG_HOME="$xdg_config_home" \
        "$LIGHTTY_BIN" --print-effective-terminal-config "$@" | sed -n -E "/$KEYS/p"
}

expected_baseline=$'background = #eff1f5\nforeground = #4c4f69\nbackground-opacity = 0.88\nbackground-blur = 30'
actual_baseline="$(probe "$ROOT/Tests/Fixtures/GhosttyConfigBaseline")"
[[ "$actual_baseline" == "$expected_baseline" ]] || {
    echo "bundled terminal defaults mismatch" >&2
    diff -u <(printf '%s\n' "$expected_baseline") \
        <(printf '%s\n' "$actual_baseline") || true
    exit 1
}

expected_override=$'background = #010203\nforeground = #a1b2c3\nbackground-opacity = 0.42\nbackground-blur = 7'
actual_override="$(probe "$ROOT/Tests/Fixtures/GhosttyConfigOverride")"
[[ "$actual_override" == "$expected_override" ]] || {
    echo "built-in theme swallowed unrelated user Ghostty values" >&2
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

expected_user_theme=$'background = #282a36\nforeground = #f8f8f2\nbackground-opacity = 0.88\nbackground-blur = 30'
actual_user_theme="$(probe \
    "$ROOT/Tests/Fixtures/GhosttyThemeOverride" \
    -lightty.terminalTheme.useBuiltIn false)"
[[ "$actual_user_theme" == "$expected_user_theme" ]] || {
    echo "disabling the built-in theme did not restore the user theme" >&2
    diff -u <(printf '%s\n' "$expected_user_theme") \
        <(printf '%s\n' "$actual_user_theme") || true
    exit 1
}

printf '%s\n' "$actual_baseline"
printf '%s\n' "user values + theme toggle: OK"
