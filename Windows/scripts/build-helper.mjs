import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { build } from 'esbuild';
import postject from 'postject';

if (process.platform !== 'win32') throw Error('Build the Windows console helper on Windows.');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'helper-build');
await fs.mkdir(output, { recursive: true });
const bundle = path.join(output, 'helper.cjs');
await build({
  entryPoints: [path.join(root, 'src/helper.cjs')],
  outfile: bundle,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node22',
  external: ['electron'],
});
const config = path.join(output, 'sea-config.json');
const blob = path.join(output, 'helper.blob');
await fs.writeFile(
  config,
  JSON.stringify({
    main: bundle,
    output: blob,
    disableExperimentalSEAWarning: true,
    useSnapshot: false,
    useCodeCache: false,
    execArgvExtension: 'none',
  }),
);
const prepared = spawnSync(process.execPath, ['--experimental-sea-config', config], {
  stdio: 'inherit',
});
if (prepared.status !== 0) throw Error('Node could not prepare the standalone MCP helper.');
const executable = path.join(output, 'Inkline-MCP.exe');
await fs.copyFile(process.execPath, executable);
// The embedded application invalidates Node's original Authenticode signature.
// Remove that signature from our private copy; this release is unsigned.
const pe = await fs.readFile(executable);
const header = pe.readUInt32LE(0x3c) + 24;
const directory = header + (pe.readUInt16LE(header) === 0x20b ? 112 : 96) + 4 * 8;
const certificate = pe.readUInt32LE(directory),
  certificateSize = pe.readUInt32LE(directory + 4);
pe.writeUInt32LE(0, directory);
pe.writeUInt32LE(0, directory + 4);
await fs.writeFile(
  executable,
  certificate && certificate + certificateSize === pe.length ? pe.subarray(0, certificate) : pe,
);
await postject.inject(executable, 'NODE_SEA_BLOB', await fs.readFile(blob), {
  sentinelFuse: 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2',
});
let license;
try {
  license = await fs.readFile(path.join(path.dirname(process.execPath), 'LICENSE'));
} catch {
  const response = await fetch(
    'https://raw.githubusercontent.com/nodejs/node/v' + process.versions.node + '/LICENSE',
  );
  if (!response.ok) throw Error('Could not obtain the bundled Node runtime license.');
  license = Buffer.from(await response.arrayBuffer());
}
await fs.writeFile(path.join(output, 'Inkline-MCP-LICENSE.txt'), license);
console.log('Built standalone Windows MCP console helper:', executable);
