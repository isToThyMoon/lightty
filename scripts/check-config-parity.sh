#!/bin/bash
# Differential regression check: lightty and the official Ghostty binary must
# resolve the terminal-facing colors/opacity/blur identically.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIGHTTY_BIN="${LIGHTTY_BIN:-$ROOT/.build/debug/lightty}"
GHOSTTY_BIN="${GHOSTTY_BIN:-/Applications/Ghostty.app/Contents/MacOS/ghostty}"

if [[ ! -x "$LIGHTTY_BIN" ]]; then
    echo "missing lightty binary: $LIGHTTY_BIN" >&2
    exit 2
fi
if [[ ! -x "$GHOSTTY_BIN" ]]; then
    echo "missing Ghostty binary: $GHOSTTY_BIN" >&2
    exit 2
fi

# Architectural guard: lightty owns the shell, never a second terminal config layer.
# The only accepted loaders are default_files + recursive_files in GhosttyRuntime.
if rg -n 'ghostty_config_load_(file|cli_args)|\.config/lightty/config' \
    "$ROOT/Sources/lightty"; then
    echo "lightty must not load or overlay terminal configuration" >&2
    exit 1
fi
if rg -n '^[[:space:]]*appearance[[:space:]]*=' \
    "$ROOT/Sources/lightty/TerminalWindow.swift"; then
    echo "TerminalWindow must not force an appearance onto the terminal host" >&2
    exit 1
fi

KEYS='^(background|foreground|background-opacity|background-blur) = '
official="$($GHOSTTY_BIN +show-config | sed -n -E "/$KEYS/p")"
# Run outside the repository so a passing result cannot accidentally depend on cwd.
actual="$(cd /tmp && "$LIGHTTY_BIN" --print-effective-terminal-config | sed -n -E "/$KEYS/p")"

if [[ "$actual" != "$official" ]]; then
    echo "terminal config mismatch" >&2
    diff -u <(printf '%s\n' "$official") <(printf '%s\n' "$actual") || true
    echo >&2
    (cd /tmp && "$LIGHTTY_BIN" --print-effective-terminal-config) \
        | sed -n '/^diagnostic = /p' >&2
    exit 1
fi

printf '%s\n' "$actual"
