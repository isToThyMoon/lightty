# Lightty

**English** | [简体中文](README.zh-Hans.md)

A macOS terminal built for running multiple AI agents in parallel. The core is [libghostty](https://github.com/ghostty-org/ghostty), so full terminal capability is a given; the shell addresses the three problems that come with a screen full of claude / codex sessions: **knowing what each session is doing, being notified when one finishes or needs you, and picking up interrupted work where it left off**.

**Status at a glance.** Every pane shows what its agent is doing in real time: thinking, running a tool, waiting for input, or finished. You don't need to keep watching — when an agent finishes or needs your intervention, the menu bar item and a system notification will tell you, and one click takes you to the pane.

**Interrupted work carries over.** Each pane can be bound to a "task". Before ending a session, have the agent write its progress into the task's handoff document; open that task in any new session later and the new agent automatically receives the context and continues the work — no scrolling through chat history, no manual copying.

**Still a full terminal.** Ghostty's rendering, configuration, and keybindings work as-is. Organize tabs and splits freely; panes can be dragged and rearranged, and mistakes are undoable with cmd+Z. In-app updates via Sparkle; the UI is bilingual (English / Simplified Chinese, following the system language).

First-time setup: choose "Agent status hooks" from the menu to connect claude / codex status with one click. Installation goes through their own plugin mechanisms — your agent configuration is never modified.

## Install

Download the DMG from [Releases](../../releases) and drag it into Applications.

The app is signed but not notarized. If Gatekeeper blocks the first launch:
**System Settings → Privacy & Security → scroll down → "Open Anyway"**, or run:

```sh
xattr -cr /Applications/lightty.app
```

Requires macOS 13+ (universal binary for Apple Silicon / Intel).

## Building from source

The kernel is a patched ghostty fork (branch [`lightty-patches`](https://github.com/isToThyMoon/ghostty/tree/lightty-patches)) and requires [zig](https://ziglang.org) 0.16.0:

```sh
git clone https://github.com/isToThyMoon/lightty && cd lightty
git clone -b lightty-patches https://github.com/isToThyMoon/ghostty vendor/ghostty
(cd vendor/ghostty && zig build -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast)
scripts/sync-ghosttykit.sh
swift build && .build/debug/lightty      # run for development
scripts/package-app.sh                   # package lightty.app (MAKE_DMG=1 for a DMG)
```

Developer docs: [task file format](docs/task-format.md) · [agent status hooks](docs/hooks.md)

## License

[MIT](LICENSE), same as Ghostty. The vendored ghostty kernel remains under its own MIT license.
