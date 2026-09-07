// One bounded page per process. No Agent execution, credentials, or transcript mutations.
// stdout is a versioned protocol; never forward SDK diagnostics or message bodies.
import { listSessions } from '@anthropic-ai/claude-agent-sdk';
const offset = Number(process.argv[2]);
const limit = 100;
const text = (value, max) => typeof value === 'string'
  ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, max) : null;
try {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= 50000 || !process.env.CLAUDE_CONFIG_DIR?.startsWith('/')) {
    throw new Error('invalid request');
  }
  const rows = await listSessions({ limit, offset, includeProgrammatic: false });
  const sessions = rows.map(row => ({
    id: row.sessionId,
    title: text(row.customTitle || row.summary, 240) || '',
    cwd: row.cwd ?? null,
    updatedAt: row.lastModified,
  }));
  process.stdout.write(JSON.stringify({ version: 1, sessions,
    nextCursor: rows.length === limit ? String(offset + limit) : null }));
} catch {
  process.stdout.write(JSON.stringify({ version: 1, error: 'catalog_unavailable' }));
  process.exitCode = 1;
}
