// Explicit title change through the pinned official SDK. No Agent execution.
// Writes the same custom-title entry the CLI's own /rename writes, so the sidebar
// and the CLI never hold two different titles for one session.
import { renameSession } from '@anthropic-ai/claude-agent-sdk';
const [id, title] = process.argv.slice(2);
try {
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id ?? '')
      || typeof title !== 'string' || title.length === 0 || title.length > 240
      || /[\u0000-\u001f\u007f]/.test(title)
      || !process.env.CLAUDE_CONFIG_DIR?.startsWith('/') || process.env.CLAUDE_CONFIG_DIR === '/') {
    throw new Error('invalid request');
  }
  await renameSession(id, title);
  process.stdout.write(JSON.stringify({ renamed: id }));
} catch {
  // Never expose transcript content, credentials, or private SDK diagnostics.
  process.exitCode = 1;
}
