// One bounded page per process. No Agent execution, credentials, or transcript mutations.
// stdout is a versioned protocol; never forward SDK diagnostics or message bodies.
import { listSessions } from '@anthropic-ai/claude-agent-sdk';
import { closeSync, existsSync, openSync, readdirSync, readSync } from 'node:fs';
import { join } from 'node:path';
import { StringDecoder } from 'node:string_decoder';

const offset = Number(process.argv[2]);
const limit = 100;
const text = (value, max) => typeof value === 'string'
  ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, max) : null;

// 官方开发包列会话时，**只在转录文件的头 64KB 里找工作目录**（末尾 64KB 另找
// 搬家记录）。用户第一句话里贴了图片时，第一条用户记录能有几百 KB，而 `cwd`
// 写在这条记录的末尾——就落在 64KB 之外，于是整条会话报不出工作目录。
// 实测本机 34 条里有 2 条这样：真实文件里 `cwd` 在第 486191 字节，窗口只到 65536。
// 拿不到工作目录的会话点开后会弹「原会话目录不存在」，等于把「没读出来」
// 说成了「目录没了」。
//
// 这里按会话号找到转录文件，往后多读一段，取出 CLI 自己写下的 `cwd`。
// 读到的是原值，不是猜的：**绝不从项目目录名反解**——那个编码不可逆
// （路径里本来就带连字符时还原不回去）。
//
// 已知局限：会话中途搬过目录（转录里的 `relocated` 记录）时，这里读到的是最初那个。
// 那个目录若已不在，上层仍会让用户重新选，不会拿着错目录直接跑。
const PER_FILE_BYTES = 8 * 1024 * 1024;
const PER_PAGE_BYTES = 64 * 1024 * 1024;

function transcriptFinder(root) {
  let names;
  try { names = readdirSync(join(root, 'projects')); } catch { return () => null; }
  return (id) => {
    for (const name of names) {
      const path = join(root, 'projects', name, `${id}.jsonl`);
      if (existsSync(path)) return path;
    }
    return null;
  };
}

// 顺着文件往前读，取第一条带 `cwd` 的记录。整条会话都没有就返回 null。
function cwdFromTranscript(path, budget) {
  let fd;
  try { fd = openSync(path, 'r'); } catch { return { cwd: null, used: 0 }; }
  const cap = Math.min(PER_FILE_BYTES, budget);
  const chunk = Buffer.allocUnsafe(65536);
  const decoder = new StringDecoder('utf8');
  let pending = '';
  let used = 0;
  try {
    while (used < cap) {
      const count = readSync(fd, chunk, 0, Math.min(chunk.length, cap - used), null);
      if (count <= 0) break;
      used += count;
      pending += decoder.write(chunk.subarray(0, count));
      let newline;
      while ((newline = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        // 先粗筛再解析：绝大多数记录没有这个字段，不值得整条 JSON 解一遍。
        if (!line.includes('"cwd"')) continue;
        let value;
        try { value = JSON.parse(line)?.cwd; } catch { continue; }
        if (typeof value === 'string' && value.startsWith('/') && value.length <= 4096) {
          return { cwd: value, used };
        }
      }
    }
  } catch { /* 读坏了就当没有，列表照常出 */ }
  finally { closeSync(fd); }
  return { cwd: null, used };
}

function fillMissingDirectories(sessions, root) {
  if (!sessions.some((row) => row.cwd === null)) return;
  const find = transcriptFinder(root);
  let budget = PER_PAGE_BYTES;
  for (const row of sessions) {
    if (row.cwd !== null || budget <= 0) continue;
    const path = find(row.id);
    if (!path) continue;
    const { cwd, used } = cwdFromTranscript(path, budget);
    budget -= used;
    if (cwd) row.cwd = text(cwd, 4096);
  }
}

try {
  const root = process.env.CLAUDE_CONFIG_DIR;
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= 50000 || !root?.startsWith('/')) {
    throw new Error('invalid request');
  }
  const rows = await listSessions({ limit, offset, includeProgrammatic: false });
  const sessions = rows.map(row => ({
    id: row.sessionId,
    title: text(row.customTitle || row.summary, 240) || '',
    cwd: row.cwd ?? null,
    updatedAt: row.lastModified,
  }));
  fillMissingDirectories(sessions, root);
  process.stdout.write(JSON.stringify({ version: 1, sessions,
    nextCursor: rows.length === limit ? String(offset + limit) : null }));
} catch {
  process.stdout.write(JSON.stringify({ version: 1, error: 'catalog_unavailable' }));
  process.exitCode = 1;
}
