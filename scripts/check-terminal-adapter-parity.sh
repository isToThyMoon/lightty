#!/bin/bash
# Architectural regression guard for the AppKit <-> libghostty seam.
# This intentionally checks ownership boundaries in addition to runtime tests:
# lightty may host core actions and provide one declarative baseline config, but it must
# never grow a second keymap or a shell-side terminal configuration implementation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/Sources/lightty"
SURFACE="$ROOT/Sources/lightty/TerminalSurfaceView.swift"
RUNTIME="$ROOT/Sources/lightty/GhosttyRuntime.swift"
WINDOW="$ROOT/Sources/lightty/TerminalWindow.swift"
CONTROLLER="$ROOT/Sources/lightty/TerminalWindowController.swift"
PANE="$ROOT/Sources/lightty/PaneView.swift"
PANE_HEADER="$ROOT/Sources/lightty/PaneHeaderView.swift"
VENDOR_SURFACE="$ROOT/vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift"

fail() {
    echo "terminal adapter parity guard failed: $1" >&2
    exit 1
}

require_source() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    rg -q "$pattern" "$file" || fail "$message"
}

[[ -f "$VENDOR_SURFACE" ]] || fail "vendored Ghostty AppKit reference is missing"

# Menus are mouse affordances only. Any non-empty AppKit key equivalent bypasses
# the user's Ghostty keybind table before the surface can see the event.
if rg -n 'keyEquivalent:[[:space:]]*"[^\"]+"|\.keyEquivalent[[:space:]]*=[[:space:]]*"[^\"]+"|keyEquivalentModifierMask' "$SOURCES"; then
    fail "lightty sources must not own AppKit keyboard shortcuts"
fi

# A fresh surface inherits global config inside core. New surfaces requested by
# core inherit through ghostty_surface_inherited_config; neither path may invent cwd.
if rg -n 'homeDirectoryForCurrentUser|working_directory[[:space:]]*=[[:space:]]*home' "$SURFACE"; then
    fail "TerminalSurfaceView must not force a working directory"
fi
require_source 'ghostty_surface_inherited_config' "$SURFACE" \
    "new-window/tab/split configuration must come from libghostty"

# Pin the easy-to-regress pieces of Ghostty's official AppKit bridge.
require_source 'ghostty_surface_key_translation_mods' "$SURFACE" \
    "option-as-alt translation is missing"
require_source 'override func flagsChanged' "$SURFACE" \
    "modifier press/release forwarding is missing"
require_source 'GHOSTTY_MODS_SHIFT_RIGHT' "$SURFACE" \
    "right-sided modifiers are missing"
require_source 'NSTextInputClient' "$SURFACE" \
    "IME bridge is missing"
require_source 'ghostty_surface_preedit' "$SURFACE" \
    "IME preedit forwarding is missing"
require_source 'addLocalMonitorForEvents' "$SURFACE" \
    "Command keyUp/focus-click bridge is missing"
require_source 'ghostty_surface_set_display_id' "$SURFACE" \
    "display migration forwarding is missing"
require_source 'ghostty_surface_set_occlusion' "$SURFACE" \
    "occlusion forwarding is missing"
require_source 'ghostty_surface_key_is_binding' "$SURFACE" \
    "AppKit key-equivalent routing is not consulting core"

# Host callbacks may implement the UI requested by core, but their trigger source
# must remain action_cb. These common host operations protect that path end-to-end.
for action in \
    GHOSTTY_ACTION_NEW_WINDOW \
    GHOSTTY_ACTION_NEW_TAB \
    GHOSTTY_ACTION_NEW_SPLIT \
    GHOSTTY_ACTION_GOTO_TAB \
    GHOSTTY_ACTION_GOTO_WINDOW \
    GHOSTTY_ACTION_CLOSE_TAB \
    GHOSTTY_ACTION_TOGGLE_FULLSCREEN \
    GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM \
    GHOSTTY_ACTION_START_SEARCH \
    GHOSTTY_ACTION_RELOAD_CONFIG; do
    require_source "$action" "$RUNTIME" "missing core host action: $action"
done

# `new_tab` and `new_split` are distinct Ghostty host actions. A tab is a native
# macOS tab group; it must never be flattened into the split tree again.
require_source 'tabbingMode[[:space:]]*=[[:space:]]*\.preferred' "$WINDOW" \
    "TerminalWindow must opt into native macOS tabs"
require_source 'AppState\.shared\.newTab' "$RUNTIME" \
    "core new_tab is not creating a native tab"
require_source 'tabGroup\?\.windows' "$RUNTIME" \
    "goto/close tab actions are not operating on the native tab group"
if rg -n 'newTaskPaneRight' "$SOURCES"; then
    fail "new_tab must not be remapped to a right-side split"
fi

# Ghostty panes are movable from their header. Preserve the complete source ->
# pasteboard -> four-zone destination -> split-tree move chain.
require_source 'NSDraggingSource' "$PANE_HEADER" \
    "pane header drag source is missing"
require_source 'lighttyPaneID' "$PANE_HEADER" \
    "pane drag payload is missing"
require_source 'performDragOperation' "$PANE" \
    "pane drop destination is missing"
require_source 'PaneDropZone\.calculate' "$PANE" \
    "pane four-zone drop calculation is missing"
require_source 'movePane\(withID:' "$CONTROLLER" \
    "pane drop is not connected to split-tree movement"

echo "terminal adapter ownership and vendor bridge guards: PASS"
