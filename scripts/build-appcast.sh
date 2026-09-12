#!/bin/bash
# 为一种分发口味生成带增量包的 appcast。
#
# 用法：
#   echo "$SPARKLE_ED_PRIVATE_KEY" | scripts/build-appcast.sh <口味> <新包> <appcast 名> <下载前缀> [回溯版本数]
#
# 为什么要增量包：应用 317MB 里有 264MB 是 Claude 会话助手（两份 Node 运行时 +
# node_modules），版本之间一个字节都不变，而每次更新却让用户重下 150MB。
# 实测 v0.13.11 → v0.13.12 的增量包只有 1.2MB，小 124 倍。
#
# 做法：把最近几个已发布版本的同口味包下载到一个目录，连同新包一起交给 Sparkle 的
# generate_appcast，它会两两生成 .delta 并写进 appcast 的 <sparkle:deltas>。
# 用户装的是哪个版本，Sparkle 就取哪一条增量；对不上就退回整包，不会更新失败。
#
# 两处收尾是 generate_appcast 不管的：
#  1. 增量包的文件名只带版本号（lightty999-998.delta），三种口味撞名。GitHub 的
#     资产名是平的一层，必须改名并同步改 appcast 里的 URL。签名签的是内容不是文件名，
#     改名不会让签名失效。
#  2. 生成的 feed 会保留历史条目，但那些旧包挂在旧 Release 上，用当前前缀拼出来的
#     URL 是 404。Sparkle 只取最新那条，所以直接裁掉历史条目，与改动前的单条 feed 一致。
set -euo pipefail

FLAVOR="${1:?flavor}"
NEW_DMG="${2:?new dmg}"
APPCAST_NAME="${3:?appcast name}"
URL_PREFIX="${4:?download url prefix}"
HISTORY="${5:-2}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEED_DIR="$ROOT/dist/feed-$FLAVOR"
GENERATOR="$(find "$ROOT/.build/artifacts" -path '*Sparkle/bin/generate_appcast' | head -1)"
[ -x "$GENERATOR" ] || { echo "✗ 找不到 generate_appcast，先 swift build"; exit 1; }

rm -rf "$FEED_DIR"
mkdir -p "$FEED_DIR"
cp "$NEW_DMG" "$FEED_DIR/"

# ── 取历史包 ────────────────────────────────────────────────────────────────
# 同口味的资产名：arm64/x64 带后缀；universal 还要认改名之前的 lightty-<版本>.dmg。
matches_flavor() {
    case "$FLAVOR" in
        arm64|x64) [[ "$1" == *-"$FLAVOR".dmg ]] ;;
        universal) [[ "$1" == *-universal.dmg ]] || [[ "$1" =~ ^lightty-[0-9.]+\.dmg$ ]] ;;
    esac
}

found=0
if command -v gh > /dev/null 2>&1; then
    for tag in $(gh release list --limit 20 --json tagName,isDraft,isPrerelease \
        --jq '.[] | select(.isDraft == false and .isPrerelease == false) | .tagName' 2>/dev/null); do
        [ "$found" -lt "$HISTORY" ] || break
        [ "$tag" != "${GITHUB_REF_NAME:-}" ] || continue
        for asset in $(gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null); do
            [[ "$asset" == *.dmg ]] || continue
            matches_flavor "$asset" || continue
            if gh release download "$tag" --pattern "$asset" --dir "$FEED_DIR" 2>/dev/null; then
                echo "▸ 历史包 $tag/$asset"
                found=$((found + 1))
            fi
            break
        done
    done
fi
[ "$found" -gt 0 ] || echo "▸ 没有可比对的历史包（$FLAVOR 首次发布），本次只出整包"

# ── 生成 ────────────────────────────────────────────────────────────────────
# 私钥经 stdin 传入，不落盘。
"$GENERATOR" --ed-key-file - --download-url-prefix "$URL_PREFIX" \
    -o "$FEED_DIR/$APPCAST_NAME" "$FEED_DIR"

# ── 收尾：增量包改名 + 裁掉历史条目 ─────────────────────────────────────────
python3 - "$FEED_DIR" "$APPCAST_NAME" "$FLAVOR" <<'PY'
import sys, os, re
import xml.etree.ElementTree as ET

feed_dir, appcast_name, flavor = sys.argv[1], sys.argv[2], sys.argv[3]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
path = os.path.join(feed_dir, appcast_name)
tree = ET.parse(path)
channel = tree.getroot().find('channel')

items = channel.findall('item')
for stale in items[1:]:
    channel.remove(stale)

renames = {}
for enclosure in channel.iter('enclosure'):
    url = enclosure.get('url', '')
    name = url.rsplit('/', 1)[-1]
    if not name.endswith('.delta'):
        continue
    renamed = renames.get(name)
    if renamed is None:
        # lightty999-998.delta → lightty-arm64-999-998.delta
        stem = re.sub(r'^(.*?)(\d+-\d+)\.delta$', r'\2', name)
        renamed = f'lightty-{flavor}-{stem}.delta'
        os.rename(os.path.join(feed_dir, name), os.path.join(feed_dir, renamed))
        renames[name] = renamed
    enclosure.set('url', url[: -len(name)] + renamed)

# 没签上名的更新 Sparkle 会拒绝安装，但那要等到用户点更新才暴露。
# 私钥没配或与包里的 SUPublicEDKey 对不上时，generate_appcast 只打一行警告就放过，
# 所以在这里挡住。
unsigned = [e.get('url') for e in channel.iter('enclosure')
            if not e.get(f'{{{SPARKLE}}}edSignature')]
if unsigned:
    sys.exit('✗ 有未签名的更新包，检查 SPARKLE_ED_PRIVATE_KEY：\n  ' + '\n  '.join(unsigned))

tree.write(path, encoding='utf-8', xml_declaration=True)
print(f'appcast: {len(items)} 条 → 1 条；增量包 {len(renames)} 个')
PY

# 要上传的资产：新整包 + 增量包 + appcast。历史包只是比对用的输入，不上传。
{
    echo "$FEED_DIR/$(basename "$NEW_DMG")"
    find "$FEED_DIR" -maxdepth 1 -name '*.delta' | sort
    echo "$FEED_DIR/$APPCAST_NAME"
} > "$FEED_DIR/upload.txt"
echo "▸ $FLAVOR 待上传：$(wc -l < "$FEED_DIR/upload.txt" | tr -d ' ') 个文件"
