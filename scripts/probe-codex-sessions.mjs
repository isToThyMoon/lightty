// Isolated compatibility probe. No model calls, user history, credentials or app sockets.
// Usage: node scripts/probe-codex-sessions.mjs [/absolute/path/to/codex]
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import assert from 'node:assert/strict';

const root = await mkdtemp(join(tmpdir(), 'lightty-codex-catalog-'));
const configRoot = join(root, 'codex');
const workdir = join(root, 'work');
await mkdir(configRoot);
await mkdir(workdir);
const fixtureDir = join(configRoot, 'sessions', '2026', '09', '07');
await mkdir(fixtureDir, { recursive: true });
const ids = [
  '0199211a-0000-7000-8000-000000000001',
  '0199211a-0000-7000-8000-000000000002',
  '0199211a-0000-7000-8000-000000000003',
];
for (const [index, id] of ids.entries()) {
  const timestamp = `2026-09-07T00:00:0${index}.000Z`;
  const events = [
    { timestamp, type: 'session_meta', payload: {
      id, timestamp, cwd: workdir, originator: 'lightty-test',
      cli_version: '0.153.4', source: index === 2 ? 'vscode' : 'cli',
      model_provider: 'openai',
    } },
    { timestamp, type: 'event_msg', payload: {
      type: 'user_message', message: `Synthetic catalog fixture ${index}`, images: [],
    } },
  ];
  await writeFile(join(fixtureDir, `rollout-2026-09-07T00-00-0${index}-${id}.jsonl`),
    events.map(value => JSON.stringify(value)).join('\n') + '\n');
}
const environment = { ...process.env, CODEX_HOME: configRoot };
for (const key of Object.keys(environment)) {
  if (/TOKEN|API_KEY|SECRET|LIGHTTY_|CODEX_REMOTE/.test(key)) delete environment[key];
}
const child = spawn(process.argv[2] ?? 'codex', ['app-server', '--listen', 'stdio://'], {
  cwd: workdir, env: environment, stdio: ['pipe', 'pipe', 'pipe'],
});
const requests = new Map();
let nextID = 1;
let stderrBytes = 0;
child.stderr.on('data', value => { stderrBytes += value.length; });
const lines = createInterface({ input: child.stdout });
lines.on('line', line => {
  try {
    const message = JSON.parse(line);
    const callback = requests.get(message.id);
    if (callback) {
      requests.delete(message.id);
      if (message.error) callback.reject(new Error(JSON.stringify(message.error)));
      else callback.resolve(message.result);
    }
  } catch { /* Ignore non-protocol output; the deadline detects missing replies. */ }
});
child.on('error', error => {
  for (const request of requests.values()) request.reject(error);
  requests.clear();
});
const exited = new Promise(resolve => child.on('close', resolve));
function request(method, params) {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      requests.delete(id);
      reject(new Error(`${method} timed out`));
    }, 10000);
    requests.set(id, {
      resolve: value => { clearTimeout(timeout); resolve(value); },
      reject: error => { clearTimeout(timeout); reject(error); },
    });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
}
try {
  await request('initialize', {
    clientInfo: { name: 'lightty_session_probe', version: '0.1.0' },
    capabilities: { experimentalApi: false },
  });
  child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const query = { limit: 1, sourceKinds: ['cli'], modelProviders: [], archived: false };
  const first = await request('thread/list', query);
  assert.equal(first.data.length, 1);
  assert.ok(first.nextCursor, 'Expected a second CLI fixture page');
  const second = await request('thread/list', { ...query, cursor: first.nextCursor });
  assert.equal(second.data.length, 1);
  const actual = new Set([...first.data, ...second.data].map(value => value.id));
  assert.deepEqual(actual, new Set(ids.slice(0, 2)), 'CLI filtering / pagination');
  for (const entry of [...first.data, ...second.data]) {
    assert.equal(entry.cwd, workdir);
    assert.equal(entry.source, 'cli');
    assert.equal(typeof entry.updatedAt, 'number');
  }
  const archived = await request('thread/list', { ...query, archived: true });
  assert.equal(archived.data.length, 0);
  console.log('PASS: initialize, CLI-only two-page listing, ID/cwd/time, empty archives');
} finally {
  child.stdin.end();
  const terminate = setTimeout(() => child.kill('SIGTERM'), 1500);
  const kill = setTimeout(() => child.kill('SIGKILL'), 3000);
  await exited;
  clearTimeout(terminate);
  clearTimeout(kill);
  lines.close();
  console.log(JSON.stringify({ fixtureRoot: root, createdState: await readdir(configRoot), stderrBytes }));
}
