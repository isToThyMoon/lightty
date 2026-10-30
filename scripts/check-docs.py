#!/usr/bin/env python3
"""文档与代码漂移守卫：入口文档里的链接、锚点、路径、类型名必须仍然存在。

用法：python3 scripts/check-docs.py        （仓库任意目录均可，< 3s）
输出：每个问题一行 `file:line: message`，有问题时退出码 1。
检查：
  a. 相对 markdown 链接指向的文件存在
  b. `#anchor` 命中目标 .md 的标题（GitHub slug 规则，重复标题加 -1/-2）
  c. 行内代码里像仓库路径的 token（含 `/` 且带扩展名，或以 Sources/ Tests/ scripts/ docs/ 开头）存在
  d. 入口文档（AGENTS/CLAUDE/CONTEXT、docs/UI-harness.md、docs/testing.md、.claude、.agents）里的
     UpperCamelCase 标识符（>=2 个驼峰）必须出现在 Sources/ 或 Tests/ 的 .swift 内容或文件名中
外部名字（AppKit 类型、产品名等）登记在 scripts/check-docs-allowlist.txt，一行一个，# 开头为注释。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {"vendor", ".build", "node_modules", ".git"}
ENTRY_FILES = {"AGENTS.md", "CLAUDE.md", "CONTEXT.md", "docs/agent-dependencies.md", "docs/UI-harness.md", "docs/testing.md"}
ENTRY_DIRS = (".claude/", ".agents/", "docs/agent-dependencies/")
PATH_PREFIXES = ("Sources/", "Tests/", "scripts/", "docs/")
# 运行期产物 / 不在仓库里的目录，路径检查不适用。
RUNTIME_PREFIXES = (".build/", "dist/", ".lightty/", ".claude/settings.local.json", "Frameworks/")

issues = []


def report(path, line, msg):
    issues.append((str(path), line, msg))


def load_allowlist():
    p = ROOT / "scripts" / "check-docs-allowlist.txt"
    out = set()
    if p.exists():
        for raw in p.read_text(errors="ignore").splitlines():
            raw = raw.split("#", 1)[0].strip()
            if raw:
                out.add(raw)
    return out


ALLOW = load_allowlist()


def walk(base, pattern):
    for p in sorted(base.rglob(pattern)):
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        yield p


def collect_docs():
    docs = []
    for name in ("AGENTS.md", "CLAUDE.md", "CONTEXT.md", "README.md"):
        if (ROOT / name).is_file():
            docs.append(ROOT / name)
    for d in ("docs", ".claude", ".agents"):
        if (ROOT / d).is_dir():
            docs.extend(walk(ROOT / d, "*.md"))
    return docs


def is_entry(rel):
    return rel in ENTRY_FILES or rel.startswith(ENTRY_DIRS)


def slugify(text):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("`", "")
    text = re.sub(r"[*_~]{1,3}(?=\S)|(?<=\S)[*~]{1,3}", "", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchor_cache = {}


def anchors_of(path):
    if path in _anchor_cache:
        return _anchor_cache[path]
    seen = {}
    result = set()
    fence = False
    for line in path.read_text(errors="ignore").splitlines():
        if re.match(r"\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence:
            continue
        m = re.match(r"\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        slug = slugify(m.group(1))
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        result.add(slug if n == 0 else f"{slug}-{n}")
    _anchor_cache[path] = result
    return result


def iter_lines(path):
    """yield (lineno, text, in_fence)"""
    fence = False
    for i, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
        if re.match(r"\s*(```|~~~)", line):
            fence = not fence
            yield i, line, True
            continue
        yield i, line, fence


LINK_RE = re.compile(r"(?<!\!)\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_RE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
IDENT_RE = re.compile(r"\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*){1,}\b")
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.\-]*:")


def check_links(doc, rel):
    for lineno, line, fence in iter_lines(doc):
        if fence:
            continue
        for m in LINK_RE.finditer(line):
            target = m.group(1)
            if target in ALLOW or SCHEME_RE.match(target):
                continue
            file_part, _, frag = target.partition("#")
            if file_part:
                if file_part in ALLOW:
                    continue
                dest = (doc.parent / file_part).resolve()
                if not dest.exists():
                    report(rel, lineno, f"broken link: {target} (file not found)")
                    continue
            else:
                dest = doc
            if frag and dest.is_file() and dest.suffix == ".md":
                if frag.lower() not in anchors_of(dest):
                    report(rel, lineno, f"broken anchor: {target} (no matching heading in {dest.relative_to(ROOT)})")


def path_candidate(span):
    span = span.strip()
    if not span or re.search(r"\s", span):
        return None
    if span[0] in "~$/" or SCHEME_RE.match(span) or re.search(r"[*<>{}|$=()\[\]]", span):
        return None
    span = re.sub(r":\d+(-\d+)?$", "", span)
    span = re.sub(r"#L?\d+.*$", "", span)
    has_ext = bool(re.search(r"\.[A-Za-z][A-Za-z0-9]{0,7}$", span))
    if span.startswith(PATH_PREFIXES) or ("/" in span and has_ext):
        return span
    return None


def check_paths(doc, rel):
    for lineno, line, fence in iter_lines(doc):
        if fence:
            continue
        for m in CODE_RE.finditer(line):
            span = m.group(1)
            cand = path_candidate(span)
            if not cand or cand in ALLOW or span.strip() in ALLOW:
                continue
            if cand.startswith(RUNTIME_PREFIXES) or cand.startswith("./."):
                continue
            plain = cand.rstrip("/")
            if any((b / plain).exists() for b in (ROOT, doc.parent, ROOT / "vendor" / "ghostty")):
                continue
            report(rel, lineno, f"path not found: {cand}")


def build_symbol_index():
    symbols = set()
    for base in ("Sources", "Tests"):
        if not (ROOT / base).is_dir():
            continue
        for p in walk(ROOT / base, "*.swift"):
            symbols.add(p.stem)
            symbols.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", p.read_text(errors="ignore")))
    return symbols


def check_identifiers(doc, rel, symbols):
    for lineno, line, _fence in iter_lines(doc):
        text = LINK_RE.sub(lambda m: " ", line)
        text = re.sub(r"https?://\S+", " ", text)
        text = re.sub(r"\b[\w./-]*/[\w./-]+", " ", text)  # 路径段不当作标识符
        seen = set()
        for m in IDENT_RE.finditer(text):
            name = m.group(0)
            if name in seen:
                continue
            seen.add(name)
            if name in ALLOW or name in symbols:
                continue
            report(rel, lineno, f"unknown identifier: {name} (not in Sources/ or Tests/ .swift; add to scripts/check-docs-allowlist.txt if external)")


def is_research_record(doc):
    # 调研记录描述的是当时的代码，被引用的文件可能已按结论删除；只核链接，不核路径。
    head = doc.read_text(encoding="utf-8", errors="ignore").splitlines()[:6]
    return any("状态：调研记录" in line for line in head)


def main():
    docs = collect_docs()
    symbols = None
    for doc in docs:
        rel = str(doc.relative_to(ROOT))
        check_links(doc, rel)
        if not is_research_record(doc):
            check_paths(doc, rel)
        if is_entry(rel):
            if symbols is None:
                symbols = build_symbol_index()
            check_identifiers(doc, rel, symbols)
    issues.sort(key=lambda t: (t[0], t[1]))
    for f, l, msg in issues:
        print(f"{f}:{l}: {msg}")
    if issues:
        print(f"check-docs: {len(issues)} issue(s)", file=sys.stderr)
        return 1
    print(f"check-docs: ok ({len(docs)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
