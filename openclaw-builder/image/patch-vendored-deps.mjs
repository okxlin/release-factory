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

export async function patchNpmBundles(root, pins) {
  root = fs.realpathSync(root);
  const store = path.join(root, '.pnpm');
  for (const [name, pin] of Object.entries(pins)) {
    assert.ok(['brace-expansion', 'undici'].includes(name));
    assert.match(pin.version, /^\d+\.\d+\.\d+$/);
    assert.equal(pin.url, `https://registry.npmjs.org/${name}/-/${name}-${pin.version}.tgz`);
    assert.match(pin.sha512, /^[a-f0-9]{128}$/);
    const outdated = [];
    for (const entry of fs.readdirSync(store)) {
      if (!/^npm@\d/.test(entry)) continue;
      const directory = path.join(store, entry, 'node_modules/npm/node_modules', name);
      if (!fs.existsSync(directory)) continue;
      assert.equal(fs.realpathSync(directory), directory, 'unexpected bundled npm dependency path');
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.name, name);
      if (pkg.version === pin.from) outdated.push(directory);
      else {
        assert.match(pkg.version, /^\d+\.\d+\.\d+$/);
        const fixed = pin.version.split('.').map(Number);
        assert.ok(pkg.version.split('.').map(Number).reduce((order, value, index) =>
          order || value - fixed[index], 0) >= 0, `unexpected vulnerable ${name} version`);
      }
    }
    await replaceVerifiedDependency(name, pin, outdated);
  }
}

async function replaceVerifiedDependency(name, pin, outdated, verify = () => {}) {
  assert.match(pin.version, /^\d+\.\d+\.\d+$/);
  assert.equal(pin.url, `https://registry.npmjs.org/${name}/-/${name}-${pin.version}.tgz`);
  assert.match(pin.sha512, /^[a-f0-9]{128}$/);
  if (!outdated.length) return;
  const temporary = fs.mkdtempSync('/tmp/openclaw-npm-bundle-');
  try {
    const response = await fetch(pin.url, {redirect: 'error', signal: AbortSignal.timeout(60000)});
    assert.equal(response.status, 200);
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      assert.ok(size <= 4 * 1024 * 1024, 'npm dependency archive exceeds expected size');
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    assert.equal(createHash('sha512').update(bytes).digest('hex'), pin.sha512);
    const archive = path.join(temporary, 'dependency.tgz');
    fs.writeFileSync(archive, bytes);
    execFileSync('tar', ['-xzf', archive, '--no-same-owner', '--no-same-permissions', '-C', temporary]);
    const replacement = path.join(temporary, 'package');
    const pkg = JSON.parse(fs.readFileSync(path.join(replacement, 'package.json')));
    assert.equal(pkg.name, name);
    assert.equal(pkg.version, pin.version);
    verify(replacement);
    for (const directory of outdated) {
      const {uid, gid} = fs.statSync(directory);
      fs.rmSync(directory, {recursive: true});
      fs.cpSync(replacement, directory, {recursive: true});
      execFileSync('chown', ['-R', `${uid}:${gid}`, directory]);
      verify(directory);
      console.log(`Replace verified dependency ${name} ${pin.from} -> ${pin.version}: ${directory}`);
    }
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
}

// https://github.com/7rulnik/source-map-js/releases/tag/v1.2.2
export function verifySourceMaps(directory) {
  const require = createRequire(import.meta.url);
  // Verification may follow replacement at the same path in the fixture tests.
  for (const key of Object.keys(require.cache)) {
    if (key.startsWith(directory + path.sep)) delete require.cache[key];
  }
  const {SourceMapConsumer, SourceNode} = require(directory);
  const flat = {version: 3, sources: ['input.js'], sourcesContent: ['let x;\n'], names: [], mappings: 'AAAA'};
  const indexed = (line, map = flat, column = 0) => ({version: 3, sections: [{offset: {line, column}, map}]});
  for (const value of [-1, 1.5, Infinity, NaN, '1', null]) {
    for (const map of [indexed(value), indexed(0, flat, value)]) {
      assert.throws(() => new SourceMapConsumer(map), /non-negative integers/);
    }
  }
  assert.throws(() => new SourceMapConsumer(indexed(1e12)), /must not exceed/);
  assert.throws(() => new SourceMapConsumer(indexed(6e6, indexed(6e6))), /including offsets of nested sections/);
  const consumer = new SourceMapConsumer(indexed(0));
  assert.equal(consumer.originalPositionFor({line: 1, column: 1}).source, 'input.js');
  assert.equal(SourceNode.fromStringWithSourceMap('let x;\n', consumer).toString(), 'let x;\n');
  // A valid offset past the supplied code must skip the gap without allocating empty lines.
  const distant = SourceNode.fromStringWithSourceMap('let x;\n', new SourceMapConsumer(indexed(1e7)));
  assert.equal(distant.toString(), 'let x;\n');
  assert.ok(distant.children.length < 10);
}

export async function patchSourceMaps(root, pin) {
  const store = path.join(fs.realpathSync(root), '.pnpm');
  const outdated = [];
  for (const entry of fs.readdirSync(store)) {
    if (!entry.startsWith('source-map-js@')) continue;
    const directory = path.join(store, entry, 'node_modules/source-map-js');
    assert.equal(fs.realpathSync(directory), directory, 'unexpected source-map-js dependency path');
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    assert.equal(pkg.name, 'source-map-js');
    if (pkg.version === pin.from) outdated.push(directory);
    else verifySourceMaps(directory);
  }
  await replaceVerifiedDependency('source-map-js', pin, outdated, verifySourceMaps);
}

// Local workaround until upstream releases a fix for CVE-2026-93748.
// https://github.com/kornelski/http-cache-semantics/issues/56
// npm's dependency refresh can install 4.3.0, which retains the same unsafe stale path.
const cacheSourceHashes = new Map([
  ['4.2.0', '01b7d66c854b2fe53ac05c98feb6e0d64722ab8898a778e2d2426a8b468d178f'],
  ['4.3.0', 'ede1cc404a492fa348eb9d97a3007a0d72aa717bd22cd86a56bd0824c19729ca'],
]);
const cacheAnchor = `    evaluateRequest(req) {
        this._assertRequestHasHeaders(req);`;
const cacheGuard = `

        // release-factory: security prohibitions cannot be overridden by max-stale.
        if (!this.storable() || this._rescc['no-cache'] ||
            (this._isShared && (this._rescc['proxy-revalidate'] ||
                (this._resHeaders['set-cookie'] && !this._rescc.public && !this._rescc.immutable)))) {
            return this._evaluateRequestMissResult(req);
        }`;

export function verifyCacheSemantics(directory) {
  const require = createRequire(import.meta.url);
  const entry = require.resolve(directory);
  delete require.cache[entry];
  const CachePolicy = require(entry);
  const request = {url: 'https://cache.test/item', headers: {host: 'cache.test'}};
  for (const directive of ['max-stale', 'max-stale=999999']) {
    const next = {...request, headers: {...request.headers, 'cache-control': directive}};
    for (const headers of [
      {'set-cookie': 'session=fixture'},
      {'cache-control': 'proxy-revalidate'},
      {'cache-control': 'no-cache'},
      {'cache-control': 'no-store'},
      {'cache-control': 'private'},
      {'set-cookie': 'session=fixture', 'cache-control': 'stale-while-revalidate=999999'},
    ]) {
      const policy = new CachePolicy(request, {status: 200, headers});
      assert.equal(policy.satisfiesWithoutRevalidation(next), false, 'unsafe cached response reused');
      assert.equal(policy.evaluateRequest(next).response, undefined, 'unsafe response exposed during revalidation');
    }
    // Ordinary stale public responses and private client caches must keep working.
    for (const shared of [true, false]) {
      const policy = new CachePolicy(request, {status: 200, headers: {
        'cache-control': shared ? 'public, max-age=60' : 'max-age=60',
        'set-cookie': 'session=fixture',
      }}, {shared});
      policy.age = () => 120;
      assert.equal(policy.satisfiesWithoutRevalidation(next), true, 'ordinary stale cache reuse broken');
    }
  }
}

export function patchCacheSemantics(directory) {
  assert.equal(fs.realpathSync(directory), directory, 'unexpected cache dependency path');
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
  assert.equal(pkg.name, 'http-cache-semantics');
  const sourceHash = cacheSourceHashes.get(pkg.version);
  if (sourceHash) {
    const file = path.join(directory, 'index.js');
    assert.equal(fs.realpathSync(file), file, 'unexpected cache source path');
    const source = fs.readFileSync(file, 'utf8');
    const original = source.includes(cacheGuard) ? source.replace(cacheGuard, '') : source;
    assert.equal(createHash('sha256').update(original).digest('hex'), sourceHash,
      'unreviewed http-cache-semantics source');
    assert.equal(original.split(cacheAnchor).length, 2, 'missing cache patch anchor');
    if (source === original) fs.writeFileSync(file, original.replace(cacheAnchor, cacheAnchor + cacheGuard));
  }
  // A future upstream version is accepted only if the actual security regression passes.
  verifyCacheSemantics(directory);
  console.log(`Verified CVE-2026-93748 cache protections (${pkg.version}): ${directory}`);
}

async function main() {
  const components = JSON.parse(fs.readFileSync(new URL('./components.json', import.meta.url)));
  await patchNpmBundles('/app/node_modules', components.npm_bundled);
  await patchSourceMaps('/app/node_modules', components.source_map_js);
  const cacheFiles = execFileSync('find', ['/app/node_modules', '-type', 'f', '-path',
    '*/http-cache-semantics/package.json'], {encoding: 'utf8'}).trim();
  for (const file of cacheFiles ? cacheFiles.split('\n') : []) {
    const directory = path.dirname(fs.realpathSync(file));
    assert.ok(directory.startsWith('/app/node_modules/'));
    patchCacheSemantics(directory);
  }
  patchCacheSemantics('/usr/local/lib/node_modules/npm/node_modules/http-cache-semantics');
  const pin = components.adm_zip;
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
