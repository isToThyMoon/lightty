// Explicit, confirmed permanent mutation through the pinned official SDK.
import { deleteSession } from '@anthropic-ai/claude-agent-sdk';
const id = process.argv[2];
try {
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id ?? '')
      || !process.env.CLAUDE_CONFIG_DIR?.startsWith('/') || process.env.CLAUDE_CONFIG_DIR === '/') {
    throw new Error('invalid request');
  }
  await deleteSession(id);
  process.stdout.write(JSON.stringify({ deleted: id }));
} catch {
  // Never expose transcript content, credentials, or private SDK diagnostics.
  process.exitCode = 1;
}
