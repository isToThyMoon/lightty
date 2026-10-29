#!/bin/bash
# PreToolUse(Bash) 守卫：lightty 正在运行时，禁止 agent 再启动第二个 lightty 实例。
# 原因：第二个实例与用户正在使用的实例共用真实配置目录 ~/.lightty（覆盖 HOME 也无效），
# scripts/check-config-parity.sh 还会启动 lightty 并迁移真实 ~/.lightty。
# 把"不要启动第二实例"从文字约定变成确定性检查。
# 协议：stdin 为 JSON（.tool_input.command）；exit 2 + stderr = 拦截并把 stderr 回给 Claude；exit 0 静默 = 放行。
# 测试钩子：LIGHTTY_GUARD_ASSUME_RUNNING=1/0 代替 pgrep（仅供 test-guard-bash.sh 使用）。
# 注意：helper 二进制 lightty-hook 不算 lightty 进程，pgrep -x 精确匹配。
set -euo pipefail

input="$(cat)"
if command -v jq >/dev/null 2>&1; then
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
else
    cmd="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command") or "")
except Exception: pass' 2>/dev/null || true)"
fi
[[ -n "$cmd" ]] || exit 0

NL=$'\n'
# 命令位置：开头，或 ; & | ( ` 换行 $( 之后；可带 env/exec/nohup/timeout N/VAR=x 等前缀
START='(^|[;&|(`'"$NL"']|\$\()[[:space:]]*'
PRE='((env|exec|nohup|command|sudo|time)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|timeout[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-9.]+[smhd]?[[:space:]]+|-[A-Za-z-]+[[:space:]]+)*'
END='([[:space:]]|[;&|)]|$)'
HEAD="${START}${PRE}"

re_bin="${HEAD}([^[:space:];&|()]*/)?\\.build/[^[:space:];&|()]*/lightty${END}"
re_app="${HEAD}[\"']?([^[:space:];&|()]*/)?[^[:space:];&|()/]*lightty\\.app/Contents/MacOS/lightty${END}"
re_open_app="${HEAD}open[[:space:]]+[^;&|]*lightty\\.app"
re_open_a="${HEAD}open[[:space:]]+([^;&|]*[[:space:]])?-a[[:space:]]+[\"']?lightty(\\.app)?[\"']?${END}"
re_parity="${HEAD}((bash|sh|zsh)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?([^[:space:];&|()]*/)?check-config-parity\\.sh${END}"

hit=""
if [[ "$cmd" =~ $re_bin || "$cmd" =~ $re_app || "$cmd" =~ $re_open_app || "$cmd" =~ $re_open_a ]]; then
    hit="launch"
elif [[ "$cmd" =~ $re_parity ]]; then
    hit="parity"
fi
[[ -n "$hit" ]] || exit 0

if [[ -n "${LIGHTTY_GUARD_ASSUME_RUNNING:-}" ]]; then
    [[ "$LIGHTTY_GUARD_ASSUME_RUNNING" == "1" ]] || exit 0
else
    pgrep -x lightty >/dev/null 2>&1 || exit 0
fi

if [[ "$hit" == "parity" ]]; then
    echo "lightty 正在运行：scripts/check-config-parity.sh 会启动 lightty 并迁移真实 ~/.lightty（覆盖 HOME 无效）。用测试 fixture 验证（scripts/test.sh / scripts/snapshot.sh），配置一致性交给用户在当前实例里验收；需要时请用户先退出 lightty。" >&2
else
    echo "lightty 正在运行：第二个实例会共用 ~/.lightty。用测试 fixture 验证（scripts/test.sh / scripts/snapshot.sh），真实界面交给用户在当前实例里验收；需要时请用户先退出 lightty。" >&2
fi
exit 2
