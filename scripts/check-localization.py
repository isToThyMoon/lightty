#!/usr/bin/env python3
"""界面文案的中文覆盖检查。

L("English key") 查表失败会回退英文键本身，漏翻不会报错，只会在中文界面里露出英文。
这里列出 Sources/lightty 里以字面量调用 L(...) 、但 zh-Hans 没有条目的键。
用法：python3 scripts/check-localization.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZH = ROOT / "Sources/lightty/Resources/zh-Hans.lproj/Localizable.strings"
KEY = r'"((?:[^"\\]|\\.)*)"'

translated = set(re.findall(r"^" + KEY + r"\s*=", ZH.read_text(encoding="utf-8"), re.M))
missing = []
for swift in sorted((ROOT / "Sources/lightty").rglob("*.swift")):
    for number, line in enumerate(swift.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        for key in re.findall(r"\bL\(" + KEY, line):
            if key not in translated:
                missing.append(f"{swift.relative_to(ROOT)}:{number}: no zh-Hans entry for \"{key}\"")

for item in missing:
    print(item)
if missing:
    print(f"check-localization: {len(missing)} missing zh-Hans entr(ies) in {ZH.relative_to(ROOT)}", file=sys.stderr)
    sys.exit(1)
print("check-localization: ok")
