// Build-time preparation only. Never invoked by the running application.
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, cp, readFile, writeFile, rename, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(repo, 'scripts', 'claude-session-helper');
const output = join(repo, '.build', 'claude-session-helper');
await mkdir(output, { recursive: true });
function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.error || result.status !== 0) throw new Error(`Build command failed: ${command}`);
}
run('npm', ['ci', '--prefix', source, '--ignore-scripts', '--omit=optional', '--no-audit', '--no-fund']);
await cp(join(source, 'node_modules'), join(output, 'node_modules'), { recursive: true });
await cp(join(source, 'list-sessions.mjs'), join(output, 'list-sessions.mjs'));
await cp(join(source, 'delete-session.mjs'), join(output, 'delete-session.mjs'));
await cp(join(source, 'rename-session.mjs'), join(output, 'rename-session.mjs'));
const version = '22.23.2';
const hashes = {
  arm64: '61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6',
  x64: '58e99022c2ff89395576cc7fd4d98cea24bb68081475d5f88b801ee8729fb026',
};
const architectures = process.argv.includes('--all') ? ['arm64', 'x64'] : [process.arch];
for (const arch of architectures) {
  if (!hashes[arch]) throw new Error('Unsupported architecture');
  const destination = join(output, `runtime-${arch}`);
  const cached = await readFile(join(destination, 'runtime.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (cached?.version === version && cached?.archiveSHA256 === hashes[arch]
      && await stat(join(destination, 'node')).catch(() => null)) continue;
  const temporary = await mkdtemp(join(output, '.download-'));
  const name = `node-v${version}-darwin-${arch}`;
  const archive = join(temporary, 'node.tar.gz');
  run('/usr/bin/curl', ['--silent', '--show-error', '--fail', '--location', '--retry', '2',
    '--max-time', '60', '--output', archive, `https://nodejs.org/dist/v${version}/${name}.tar.gz`]);
  const data = await readFile(archive);
  if (createHash('sha256').update(data).digest('hex') !== hashes[arch]) throw new Error('Node checksum mismatch');
  run('/usr/bin/tar', ['-xzf', archive, '-C', temporary, `${name}/bin/node`, `${name}/LICENSE`]);
  const prepared = join(temporary, 'runtime');
  await mkdir(prepared);
  await cp(join(temporary, name, 'bin', 'node'), join(prepared, 'node'));
  await cp(join(temporary, name, 'LICENSE'), join(prepared, 'LICENSE'));
  await writeFile(join(prepared, 'runtime.json'), JSON.stringify({ version, architecture: arch, archiveSHA256: hashes[arch] }));
  // Preserve a previous build artifact, never recursively delete an unresolved path.
  if (await stat(destination).catch(() => null)) await rename(destination, join(temporary, 'previous-runtime'));
  await rename(prepared, destination);
}
console.log(`Prepared Claude metadata helper: ${output}`);
