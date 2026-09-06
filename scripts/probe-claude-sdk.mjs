// Isolated public-SDK spike, not a production session parser.
// npm install --prefix <temporary-package-root> --ignore-scripts --omit=optional \
//   --no-audit --no-fund @anthropic-ai/claude-agent-sdk@0.3.263
// node scripts/probe-claude-sdk.mjs <temporary-package-root> [1000]
// Writes synthetic fixtures ONLY beneath a new mkdtemp directory. Keeps results for inspection.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, readdir, readFile, realpath, stat, utimes, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const script = fileURLToPath(import.meta.url);
if (process.argv[2] === '--worker') {
  const [packageRoot, expectedPath] = process.argv.slice(3);
  const expected = JSON.parse(await readFile(expectedPath, 'utf8'));
  const beforeImport = performance.now();
  const require = createRequire(join(packageRoot, 'package.json'));
  const { listSessions } = await import(pathToFileURL(require.resolve('@anthropic-ai/claude-agent-sdk')).href);
  const importMs = performance.now() - beforeImport;
  const measurement = process.argv[5];
  if (measurement) {
    const started = performance.now();
    const rows = await listSessions({ includeProgrammatic: false, ...(measurement === 'page' ? { limit: 100 } : {}) });
    console.log(JSON.stringify({ measurement, count: rows.length, importMs,
      listMs: performance.now() - started, peakRSSMiB: process.resourceUsage().maxRSS / 1024 }));
    process.exit(0);
  }
  const start = performance.now();
  const first = await listSessions({ limit: 1, includeProgrammatic: false });
  const firstPageMs = performance.now() - start;
  const second = await listSessions({ limit: 1, offset: 1, includeProgrammatic: false });
  assert.equal(first.length, 1);
  assert.equal(second.length, 1);
  assert.notEqual(first[0].sessionId, second[0].sessionId);
  assert.ok(first[0].lastModified >= second[0].lastModified);
  const allStart = performance.now();
  const all = await listSessions({ includeProgrammatic: false });
  const allMs = performance.now() - allStart;
  const actualIDs = new Set(all.map(row => row.sessionId));
  assert.equal(actualIDs.size, all.length, 'No duplicates');
  assert.deepEqual(actualIDs, new Set(expected.ids), 'Cross-project catalog and exclusions');
  const named = all.find(row => row.sessionId === expected.namedID);
  assert.equal(named.customTitle, '自定义标题 / renamed');
  assert.equal(named.cwd, expected.directories[0]);
  assert.ok(named.lastModified > 1e12, 'Milliseconds, not seconds');
  const project = await listSessions({ dir: expected.directories[0], includeWorktrees: false, includeProgrammatic: false });
  assert.ok(project.length > 0 && project.length < all.length);
  assert.ok(project.every(row => row.cwd === expected.directories[0]));
  const programmatic = await listSessions({ includeProgrammatic: true });
  assert.ok(programmatic.some(row => row.sessionId === expected.programmaticID));
  // Large transcripts must use bounded metadata reads, and a partial tail must not lose the row.
  assert.ok(actualIDs.has(expected.largeID));
  assert.ok(actualIDs.has(expected.partialID));
  const metadata = JSON.parse(await readFile(join(dirname(require.resolve('@anthropic-ai/claude-agent-sdk')), 'package.json'), 'utf8'));
  console.log(JSON.stringify({ sdkVersion: metadata.version,
    count: all.length, importMs, firstPageMs, allMs, peakRSSMiB: process.resourceUsage().maxRSS / 1024,
    checks: ['cross-project', 'pagination', 'custom-title', 'cwd', 'epoch-ms', 'exclude-sidechain',
      'exclude-programmatic', 'project-filter', 'partial-tail', 'large-transcript'] }));
  process.exit(0);
}

const packageRoot = resolve(process.argv[2] ?? '');
assert.ok(process.argv[2], 'Provide an isolated npm installation directory');
const count = Number(process.argv[3] ?? 1000);
assert.ok(Number.isInteger(count) && count >= 4 && count <= 10000);
const root = await realpath(await mkdtemp(join(tmpdir(), 'lightty-claude-metadata-')));
const runtimeFlags = process.env.LIGHTTY_PROBE_JITLESS === '1' ? ['--jitless'] : [];
const configRoot = join(root, 'isolated-config');
const directories = [join(root, '项目 one'), join(root, 'project-two')];
const projects = directories.map(value => join(configRoot, 'projects', value.replace(/[^a-zA-Z0-9]/g, '-')));
await Promise.all([...directories, ...projects].map(path => mkdir(path, { recursive: true })));
const ids = Array.from({ length: count }, () => randomUUID());
const programmaticID = randomUUID();
const sidechainID = randomUUID();
const date = new Date('2026-09-07T00:00:00.000Z');
async function fixture(id, index, { sidechain = false, programmatic = false, partial = false, large = false } = {}) {
  const cwd = directories[index % 2];
  const user = { type: 'user', sessionId: id, uuid: randomUUID(), parentUuid: null,
    isSidechain: sidechain, cwd, timestamp: date.toISOString(), version: '2.1.263',
    entrypoint: programmatic ? 'sdk-ts' : 'cli', message: { role: 'user', content: `Synthetic session ${index}` } };
  const records = [user];
  if (large) records.push({ type: 'assistant', sessionId: id, uuid: randomUUID(), parentUuid: user.uuid,
    timestamp: date.toISOString(), message: { role: 'assistant', content: [{ type: 'text', text: 'x'.repeat(8 * 1024 * 1024) }] } });
  if (index === 0) records.push({ type: 'custom-title', sessionId: id, customTitle: '自定义标题 / renamed' });
  const file = join(projects[index % 2], `${id}.jsonl`);
  await writeFile(file, records.map(value => JSON.stringify(value)).join('\n') + '\n' + (partial ? '{"type":' : ''));
  await utimes(file, date, new Date(date.getTime() + index * 1000));
}
// Keep file concurrency bounded even for the 10k scale case.
for (let index = 0; index < count; index += 32) {
  await Promise.all(ids.slice(index, index + 32).map((id, offset) => fixture(id, index + offset,
    { partial: index + offset === 1, large: index + offset === 2 })));
}
await fixture(programmaticID, count, { programmatic: true });
await fixture(sidechainID, count + 1, { sidechain: true });
await writeFile(join(projects[0], `${randomUUID()}.jsonl`), 'not json\n');
const expectedPath = join(root, 'expected.json');
await writeFile(expectedPath, JSON.stringify({ ids, namedID: ids[0], partialID: ids[1], largeID: ids[2], programmaticID, directories }));
const runtime = join(root, 'runtime');
await mkdir(runtime);
const node = join(runtime, 'node');
const worker = join(runtime, 'probe.mjs');
await copyFile(process.execPath, node);
await copyFile(script, worker);
const profile = join(root, 'readonly.sb');
// The worker cannot read private user history, write any files, use the network or launch Claude/git.
await writeFile(profile, `(version 1)\n(allow default)\n(deny network*)\n(deny process-fork)\n(deny file-write*)\n(deny file-read* (subpath ${JSON.stringify(homedir())}))\n`);
async function fingerprint(path) {
  const hash = createHash('sha256');
  async function walk(dir) {
    for (const name of (await readdir(dir)).sort()) {
      const file = join(dir, name);
      const info = await stat(file);
      hash.update(file + ':' + info.size + ':' + info.mtimeMs);
      if (info.isDirectory()) await walk(file); else hash.update(await readFile(file));
    }
  }
  await walk(path);
  return hash.digest('hex');
}
const before = await fingerprint(configRoot);
const results = [];
for (let attempt = 0; attempt < 3; attempt++) {
  const started = performance.now();
  const child = spawnSync('/usr/bin/sandbox-exec', ['-f', profile, node, ...runtimeFlags, worker, '--worker', packageRoot, expectedPath], {
    cwd: root, env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', CLAUDE_CONFIG_DIR: configRoot, TMPDIR: root },
    encoding: 'utf8', timeout: 60000, maxBuffer: 1024 * 1024,
  });
  assert.equal(child.status, 0, `Sandboxed worker failed: ${child.error ?? child.stderr}`);
  results.push({ ...JSON.parse(child.stdout), processMs: performance.now() - started });
}
const singleCalls = [];
for (const measurement of ['page', 'all']) {
  const started = performance.now();
  const child = spawnSync('/usr/bin/sandbox-exec', ['-f', profile, node, ...runtimeFlags, worker, '--worker', packageRoot, expectedPath, measurement], {
    cwd: root, env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', CLAUDE_CONFIG_DIR: configRoot, TMPDIR: root },
    encoding: 'utf8', timeout: 60000, maxBuffer: 1024 * 1024,
  });
  assert.equal(child.status, 0, `Measurement failed: ${child.error ?? child.stderr}`);
  singleCalls.push({ ...JSON.parse(child.stdout), processMs: performance.now() - started });
}
assert.equal(await fingerprint(configRoot), before, 'Catalog must not mutate fixture history');
const report = { fixtureRoot: root, packageRoot, nodeVersion: process.version, runtimeFlags,
  sandbox: 'deny network, writes, process-fork and user-home reads', unchangedFiles: true, results, singleCalls };
await writeFile(join(root, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
