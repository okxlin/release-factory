// Copilot's published platform package embeds this dependency outside pnpm's lock.
// https://github.com/advisories/GHSA-xcpc-8h2w-3j85
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function verifyArchiveReader(directory) {
  const AdmZip = createRequire(import.meta.url)(directory);
  const zip = new AdmZip();
  zip.addFile('test.txt', Buffer.from('archive works'));
  const data = zip.toBuffer();
  assert.equal(new AdmZip(data).readAsText('test.txt'), 'archive works');
  const central = data.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  assert.ok(central >= 0);
  data.writeUInt32LE(0x7fffffff, central + 24);
  // Reproduce the advisory without allocating attacker-declared gigabytes.
  const originals = new Map(['alloc', 'allocUnsafe', 'allocUnsafeSlow'].map(key => [key, Buffer[key]]));
  let oversized = false;
  try {
    for (const [key, original] of originals) {
      Buffer[key] = (size, ...args) => {
        if (size > 1024 * 1024) { oversized = true; throw new Error('oversized ZIP allocation'); }
        return original(size, ...args);
      };
    }
    try { new AdmZip(data).readFile('test.txt'); } catch { /* Rejecting a malformed ZIP is valid. */ }
  } finally {
    for (const [key, original] of originals) Buffer[key] = original;
  }
  assert.equal(oversized, false, 'archive reader trusted the attacker-declared size');
}

async function main() {
  const pin = JSON.parse(fs.readFileSync(new URL('./components.json', import.meta.url))).adm_zip;
  assert.match(pin.version, /^\d+\.\d+\.\d+$/);
  assert.equal(pin.url, `https://registry.npmjs.org/adm-zip/-/adm-zip-${pin.version}.tgz`);
  assert.match(pin.sha512, /^[a-f0-9]{128}$/);
  const found = execFileSync('find', ['/app/node_modules', '-type', 'f', '-path',
    '*/foundry-local-sdk/node_modules/adm-zip/package.json'], {encoding: 'utf8'}).trim();
  const targets = found ? found.split('\n').map(file => path.dirname(fs.realpathSync(file))) : [];
  const outdated = [];
  for (const directory of targets) {
    assert.ok(directory.startsWith('/app/node_modules/.pnpm/@github+copilot-'));
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    assert.equal(pkg.name, 'adm-zip');
    if (pkg.version === '0.5.17') outdated.push(directory);
    else verifyArchiveReader(directory); // Keep a newer upstream fix only if it passes the same regression.
  }
  if (!outdated.length) {
    console.log('No vulnerable bundled Foundry adm-zip copy needs replacement');
    return;
  }
  const temporary = fs.mkdtempSync('/tmp/openclaw-adm-zip-');
  try {
    const response = await fetch(pin.url, {redirect: 'error', signal: AbortSignal.timeout(60000)});
    assert.equal(response.status, 200);
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      assert.ok(size <= 1024 * 1024, 'archive exceeds expected size');
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    assert.equal(createHash('sha512').update(bytes).digest('hex'), pin.sha512);
    const archive = path.join(temporary, 'adm-zip.tgz');
    fs.writeFileSync(archive, bytes);
    execFileSync('tar', ['-xzf', archive, '--no-same-owner', '--no-same-permissions', '-C', temporary]);
    const replacement = path.join(temporary, 'package');
    assert.equal(JSON.parse(fs.readFileSync(path.join(replacement, 'package.json'))).version, pin.version);
    verifyArchiveReader(replacement);
    for (const directory of outdated) {
      console.log(`Replace verified vendored adm-zip 0.5.17 -> ${pin.version}: ${directory}`);
      const {uid, gid} = fs.statSync(directory);
      fs.rmSync(directory, {recursive: true});
      fs.cpSync(replacement, directory, {recursive: true});
      execFileSync('chown', ['-R', `${uid}:${gid}`, directory]);
      verifyArchiveReader(directory);
    }
    fs.mkdirSync('/usr/share/doc/release-factory', {recursive: true});
    fs.writeFileSync('/usr/share/doc/release-factory/openclaw-vendored-deps.json',
      JSON.stringify({advisory: 'GHSA-xcpc-8h2w-3j85', pin, paths: outdated}, null, 2) + '\n');
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
