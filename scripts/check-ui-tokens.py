#!/usr/bin/env python3
"""UI token 守卫，两件事：

1. 尚未提交的新增行（git diff HEAD + 未跟踪文件）里，Sources/lightty 不写字面颜色。
   只查颜色：局部尺寸按 docs/UI-harness.md 允许留在组件里，AppKit 的数字常量也分不出是不是间距。
2. DESIGN.md 的颜色、字体、间距、圆角与 ShellStyle.swift 一致，新颜色 token 必须进 DESIGN.md。

用法：python3 scripts/check-ui-tokens.py
确实不该进 token 的字面色（预览图、品牌色），在该行注释写 `ui-token-exempt: 原因`。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STYLE = ROOT / "Sources/lightty/ShellStyle.swift"
DESIGN = ROOT / "DESIGN.md"
LITERAL = re.compile(
    r"NSColor\(\s*(srgbRed|red|white|calibratedRed|calibratedWhite|deviceRed|deviceWhite|displayP3Red|hue)\s*:"
    r"|CGColor\(\s*(red|srgbRed|gray)\s*:"
    r"|\.shell(RGB|Dynamic)\("
    r"|\bcolorWithRed\b"
)
WEIGHTS = {"regular": 400, "medium": 500, "semibold": 600}


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def added_lines():
    current = None
    for line in git("diff", "HEAD", "--unified=0", "--", "Sources/lightty").splitlines():
        if line.startswith("+++ "):
            current = line[6:]
        elif line.startswith("+") and current:
            yield current, line[1:]
    for path in git("ls-files", "-o", "--exclude-standard", "--", "Sources/lightty").splitlines():
        if path.endswith(".swift"):
            for line in (ROOT / path).read_text(errors="ignore").splitlines():
                yield path, line


def literal_colors():
    for path, line in added_lines():
        if path.endswith(".swift") and not path.endswith("/ShellStyle.swift") \
                and LITERAL.search(line) and "ui-token-exempt:" not in line:
            yield (f"{path}: literal color in new code: {line.strip()}\n"
                   "  Use a semantic color from ShellStyle (see DESIGN.md); add a token there if none fits.")


def camel(key):
    head, *rest = key.split("-")
    return head + "".join(p.capitalize() for p in rest)


def kebab(name):
    return re.sub(r"[A-Z]", lambda m: "-" + m.group().lower(), name)


def frontmatter():
    """按缩进读两到三层的 YAML 子集；只用标准库，所以 DESIGN.md 保持简单写法。"""
    sections, section, item = {}, None, None
    for raw in DESIGN.read_text().split("---")[1].splitlines():
        m = re.match(r'^( *)([\w-]+):\s*"?([^"]*)"?\s*$', raw)
        if not m:
            continue
        indent, key, value = len(m[1]), m[2], m[3]
        if indent == 0:
            section = sections.setdefault(key, {})
        elif indent == 2 and section is not None:
            section[key] = value if value else {}
            item = key
        elif indent == 4 and isinstance(section.get(item), dict):
            section[item][key] = value
    return sections


def design_drift():
    style = STYLE.read_text()
    tokens = frontmatter()
    colors, typo = tokens.get("colors", {}), tokens.get("typography", {})

    for name, light, dark in re.findall(
            r"static (?:private )?(?:let|var) (\w+) = NSColor\.shellDynamic\(light: 0x(\w{6}), dark: 0x(\w{6})\)", style):
        for key, want in ((kebab(name), light), (kebab(name) + "-dark", dark)):
            if colors.get(key, "").lstrip("#").upper() != want.upper():
                yield f"DESIGN.md: colors.{key} is {colors.get(key) or 'missing'}, ShellStyle.{name} says #{want}"

    for name, size, weight in re.findall(
            r"static let (\w+) = NSFont\.(?:systemFont|monospacedDigitSystemFont)\(ofSize: ([\d.]+)(?:, weight: \.(\w+))?\)",
            style[style.index("enum Font {"):style.index("// MARK: Spacing")]):
        entry = typo.get(kebab(name))
        if not isinstance(entry, dict):
            yield f"DESIGN.md: typography.{kebab(name)} is missing (ShellStyle.Font.{name})"
            continue
        if entry.get("fontSize") != f"{size}px" or entry.get("fontWeight") != str(WEIGHTS[weight or "regular"]):
            yield f"DESIGN.md: typography.{kebab(name)} differs from ShellStyle.Font.{name} ({size}px, {weight or 'regular'})"

    for section, suffix in (("spacing", ""), ("rounded", "CornerRadius")):
        for key, value in tokens.get(section, {}).items():
            name = camel(key) + suffix
            m = re.search(rf"static let {name}: CGFloat = ([\d.]+)", style)
            if not m:
                yield f"DESIGN.md: {section}.{key} has no ShellStyle.{name}"
            elif f"{m[1]}px" != value:
                yield f"DESIGN.md: {section}.{key} is {value}, ShellStyle.{name} says {m[1]}px"


problems = list(literal_colors()) + list(design_drift())
for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
