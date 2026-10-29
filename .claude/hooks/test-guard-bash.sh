#!/bin/bash
# guard-bash.sh 的表驱动自测。用 LIGHTTY_GUARD_ASSUME_RUNNING=1/0 代替 pgrep 伪造"运行中/未运行"。
# 只打印失败项与最后的 PASS/FAIL。
set -euo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/guard-bash.sh"
fails=0
total=0

# 用法：check <running 0|1> <block|allow> <command>
check() {
    local running="$1" want="$2" cmd="$3" json rc=0
    json="$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
    printf '%s' "$json" | LIGHTTY_GUARD_ASSUME_RUNNING="$running" "$GUARD" >/dev/null 2>&1 || rc=$?
    total=$((total + 1))
    local got=allow
    [[ $rc -eq 2 ]] && got=block
    if [[ "$got" != "$want" ]]; then
        echo "FAIL running=$running want=$want got=$got(rc=$rc): $cmd"
        fails=$((fails + 1))
    fi
}

while IFS= read -r c; do
    [[ -n "$c" ]] && check 1 block "$c"
done <<'LIST'
.build/debug/lightty
.build/release/lightty
./.build/debug/lightty
/Users/x/project/lightty/.build/debug/lightty
.build/arm64-apple-macosx/debug/lightty --foo
swift build && .build/debug/lightty
ls; ./.build/debug/lightty &
env FOO=1 .build/debug/lightty
FOO=1 .build/debug/lightty
exec .build/debug/lightty
nohup .build/debug/lightty >/dev/null 2>&1 &
timeout 10 .build/debug/lightty
(.build/debug/lightty)
echo hi | .build/debug/lightty
open dist/lightty.app
open -a lightty
open -n -a lightty
dist/release/lightty.app/Contents/MacOS/lightty
scripts/check-config-parity.sh
bash scripts/check-config-parity.sh
cd scripts && ./check-config-parity.sh
LIST

while IFS= read -r c; do
    [[ -n "$c" ]] && check 1 allow "$c"
done <<'LIST'
.build/debug/lightty-hook
./.build/debug/lightty-hook --x
swift build
swift test --filter Foo
ls .build/debug/lightty
grep lightty Sources/lightty/App.swift
git log --oneline -- .build/debug/lightty
cat scripts/check-config-parity.sh
rg check-config-parity scripts
file .build/debug/lightty
open README.md
open -a Safari
ls dist/lightty.app/Contents/MacOS/lightty
scripts/test.sh
LIST

# 未运行：全部放行
while IFS= read -r c; do
    [[ -n "$c" ]] && check 0 allow "$c"
done <<'LIST'
.build/debug/lightty
open -a lightty
scripts/check-config-parity.sh
LIST

# 非 JSON / 无 command 也放行
rc=0; printf 'garbage' | LIGHTTY_GUARD_ASSUME_RUNNING=1 "$GUARD" >/dev/null 2>&1 || rc=$?
total=$((total + 1)); [[ $rc -eq 0 ]] || { echo "FAIL garbage input rc=$rc"; fails=$((fails + 1)); }

if [[ $fails -eq 0 ]]; then
    echo "PASS ($total cases)"
else
    echo "FAIL ($fails/$total)"
    exit 1
fi
