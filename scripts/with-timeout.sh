#!/bin/bash
# 用法：scripts/with-timeout.sh <秒> <命令...>
# 到时杀掉整棵进程树并退出 124；否则透传命令的退出码。macOS 没有 timeout，
# 而卡死的 ghostty_surface_free 会让 swift test 永远不退出，只杀 swift test 本身还会留下测试进程。
set -uo pipefail

limit="$1"; shift

kill_tree() {
    local child
    for child in $(pgrep -P "$1"); do kill_tree "$child"; done
    kill -9 "$1" 2>/dev/null
}

marker="$(mktemp)"
rm -f "$marker"
# 后台任务默认把 stdin 换成 /dev/null，显式保留
"$@" <&0 &
target=$!
( sleep "$limit"; : >"$marker"; kill_tree "$target" ) &
watchdog=$!

wait "$target"
status=$?
kill_tree "$watchdog"
wait "$watchdog" 2>/dev/null

if [ -e "$marker" ]; then
    rm -f "$marker"
    exit 124
fi
exit "$status"
