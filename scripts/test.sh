#!/bin/bash
# 给 agent 用的精简测试入口：跑 swift test，完整日志落盘，终端只输出结论。
# 用法：scripts/test.sh [swift-test-filter]
#   成功：一行 PASS（XCTest / Swift Testing 数量、耗时、日志路径）+ 跳过用例清单
#   失败：失败用例及其 file:line 错误、编译错误、崩溃时的日志尾部，最后是日志路径
# 会清掉从 lightty 窗格继承来的 LIGHTTY_PANE_ID / LIGHTTY_SOCK（否则测试行为异常）。
# filter 匹配到 0 个用例同样视为失败。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
unset LIGHTTY_PANE_ID LIGHTTY_SOCK

LOG_DIR="$ROOT/.build/test-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"

ARGS=()
FILTER="${1:-}"
if [ -n "$FILTER" ]; then ARGS=(--filter "$FILTER"); fi

START=$SECONDS
set +e
swift test ${ARGS[@]+"${ARGS[@]}"} >"$LOG" 2>&1
STATUS=$?
set -e
ELAPSED=$((SECONDS - START))

python3 - "$LOG" "$STATUS" "$ELAPSED" "$FILTER" <<'PY'
import re, sys

log, status, elapsed, flt = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
text = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="ignore").read())
lines = text.splitlines()

xc_total = 0
st_total = 0
st_seen = False
for i, l in enumerate(lines):
    if re.match(r"Test Suite '(Selected tests|All tests)' (passed|failed) at", l) and i + 1 < len(lines):
        m = re.search(r"Executed (\d+) tests?", lines[i + 1])
        if m:
            xc_total += int(m.group(1))
    m = re.match(r"[✔✘] Test run with (\d+) tests?", l)
    if m:
        st_total += int(m.group(1)); st_seen = True

# 失败：XCTest
failed = {}  # name -> [messages]
order = []
def add(name, msg):
    if name not in failed:
        failed[name] = []; order.append(name)
    if msg: failed[name].append(msg)

for l in lines:
    m = re.match(r"Test Case '-\[(\S+) (\S+)\]' failed", l)
    if m: add(f"{m.group(1)}.{m.group(2)}", None)
    m = re.match(r"(.+?:\d+): error: -\[(\S+) (\S+)\] : (.*)", l)
    if m: add(f"{m.group(2)}.{m.group(3)}", f"{m.group(1)}: error: {m.group(4)}")

# 失败：Swift Testing
i = 0
while i < len(lines):
    l = lines[i]
    m = re.match(r"✘ Test (.+?) recorded an issue(?: at (\S+?:\d+)(?::\d+)?)?: (.*)", l)
    if m:
        msg = f"{m.group(2)}: {m.group(3)}" if m.group(2) else m.group(3)
        j = i + 1
        while j < len(lines) and re.match(r"\s*↳", lines[j]):
            msg += "\n      " + lines[j].strip(); j += 1
        add(m.group(1), msg)
    m = re.match(r"✘ Test (.+?) failed after", l)
    if m and not m.group(1).startswith("run "): add(m.group(1), None)
    i += 1

skipped = []
for l in lines:
    m = re.match(r"Test Case '-\[(\S+) (\S+)\]' skipped", l)
    if m: skipped.append(f"{m.group(1)}.{m.group(2)}")
    m = re.match(r"[↩➜] Test (.+?) skipped", l)
    if m: skipped.append(m.group(1))

compile_errors = []
for l in lines:
    if re.match(r"/\S+?:\d+:\d+: error: ", l) and l not in compile_errors:
        compile_errors.append(l)

crash_pat = re.compile(r"Exited with unexpected signal|Fatal error:|unexpected signal|Crash(ed)? |signal code|Illegal instruction|Segmentation fault|Bus error", re.I)
crashed = any(crash_pat.search(l) for l in lines)

total = xc_total + st_total
nfail = len(failed)
zero = (status == 0 or not compile_errors) and total == 0 and not compile_errors and not crashed

def skiplines():
    if skipped:
        print(f"SKIPPED ({len(skipped)}, not passed): " + ", ".join(skipped))

if status == 0 and total > 0 and not failed:
    print(f"PASS: {xc_total} XCTest + {st_total} Swift Testing tests, {elapsed}s (log: {log})")
    skiplines()
    sys.exit(0)

print(f"FAIL: {nfail} failing test(s), {xc_total} XCTest + {st_total} Swift Testing run, {elapsed}s, swift test exit {status}")
if total == 0 and status == 0:
    print(f"No tests matched filter '{flt}'." if flt else "No tests were run.")
for n in order:
    print(f"  {n}")
    for msg in failed[n]:
        print(f"    {msg}")
if compile_errors:
    print("Build errors:")
    for l in compile_errors[:40]:
        print(f"  {l}")
if crashed or (status != 0 and not failed and not compile_errors):
    print("Last 30 log lines" + (" (crash/unexpected signal detected):" if crashed else " (no parsed failure):"))
    for l in lines[-30:]:
        print(f"  {l[:300]}")
skiplines()
print(f"log: {log}")
sys.exit(1)
PY
