#!/bin/bash
# 交付前的一条命令：build -> tests -> terminal adapter parity -> localization -> docs drift。
# 用法：scripts/check.sh
# 每步一行状态（✓/✗），build 失败即停止；其余步骤失败后继续，最后汇总并以非零退出。
# 不含 check-config-parity.sh（它会迁移用户真实的 ~/.lightty 数据）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset LIGHTTY_PANE_ID LIGHTTY_SOCK

FAILED=()
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "→ build"
if swift build >"$SCRATCH/build.log" 2>&1; then
    echo "✓ build"
else
    echo "✗ build"
    sed 's/\x1b\[[0-9;]*m//g' "$SCRATCH/build.log" | grep -E '^/.*: error:|^error:' | sort -u | head -40
    echo "FAIL: build failed (stopped; tests and checks not run)"
    exit 1
fi

run_step() {
    local name="$1"; shift
    local out="$SCRATCH/$name.out"
    echo "→ $name"
    if "$@" >"$out" 2>&1; then
        echo "✓ $name"
        # test.sh 的 SKIPPED 行也要让人看到
        grep -E '^(PASS|SKIPPED)' "$out" || true
    else
        echo "✗ $name"
        cat "$out"
        FAILED+=("$name")
    fi
}

run_step tests scripts/test.sh
run_step terminal-adapter-parity scripts/check-terminal-adapter-parity.sh
run_step localization python3 scripts/check-localization.py
run_step docs python3 scripts/check-docs.py

if [ ${#FAILED[@]} -eq 0 ]; then
    echo "OK: all checks passed"
else
    echo "FAIL: ${FAILED[*]}"
    exit 1
fi
