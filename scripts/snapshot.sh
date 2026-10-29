#!/bin/bash
# UI 快照入口：设置 LIGHTTY_UI_SNAPSHOT_DIR 后跑指定测试，列出产出的 PNG。
# 用法：scripts/snapshot.sh <swift-test-filter> [out-dir]
#   out-dir 默认 .build/ui-snapshots/<timestamp>
# 快照由测试里的 screencapture -l 抓窗口，需要「屏幕录制」权限且窗口真的上屏
# （测试期间会短暂弹出窗口）；没产出 PNG 时按该提示排查。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ $# -lt 1 ]; then
    echo "usage: scripts/snapshot.sh <swift-test-filter> [out-dir]" >&2
    exit 2
fi
FILTER="$1"
OUT="${2:-$ROOT/.build/ui-snapshots/$(date +%Y%m%d-%H%M%S)}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$OUT"
export LIGHTTY_UI_SNAPSHOT_DIR="$OUT"

STATUS=0
"$ROOT/scripts/test.sh" "$FILTER" || STATUS=$?

FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find "$OUT" -name '*.png' -type f | sort)
if [ ${#FILES[@]} -eq 0 ]; then
    echo "snapshots: none produced in $OUT"
    echo "  该 filter 的测试可能没有快照分支，或终端缺少屏幕录制权限（screencapture -l 静默失败）"
else
    echo "snapshots (${#FILES[@]}):"
    printf '  %s\n' "${FILES[@]}"
fi
exit $STATUS
