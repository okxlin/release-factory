import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchNpmBundles } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).npm_bundled;

// GHSA-xjj6-f33q-929c: the caught fetch rejection must not leave a crashing internal stream.
const undiciRegression = `
  import assert from 'node:assert/strict';
  import {once} from 'node:events';
  import {createRequire} from 'node:module';
  import {createServer} from 'node:net';
  const {Client, fetch} = createRequire(import.meta.url)(process.argv[1]);
  const response = Buffer.from('HTTP/1.1 200 OK\\r\\nContent-Encoding: ' +
    Array(6).fill('gzip').join(', ') + '\\r\\nContent-Length: 1\\r\\nConnection: close\\r\\n\\r\\n');
  let closed;
  const socketClosed = new Promise(resolve => { closed = resolve; });
  const server = createServer(socket => {
    socket.once('close', closed);
    socket.once('data', () => socket.end(response));
  });
  await once(server.listen(0, '127.0.0.1'), 'listening');
  const url = 'http://127.0.0.1:' + server.address().port;
  const client = new Client(url);
  try {
    await assert.rejects(fetch(url, {dispatcher: client}), error => {
      assert.match(error.cause?.message || '', /content-encoding/);
      return true;
    });
    await socketClosed;
    await new Promise(resolve => setTimeout(resolve, 100));
    console.log('bundled undici rejected excessive encoding without an orphan stream');
  } finally { await client.destroy(); await new Promise(resolve => server.close(resolve)); }
`;

test('repairs real old npm undici copies and rejects unsafe replacement inputs', {timeout: 150000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-undici-'));
  try {
    const pin = pins.undici;
    const versions = Array.isArray(pin.from) ? pin.from : [pin.from];
    const dependencies = Object.fromEntries(versions.map((version, index) => [`undici-${index}`, `npm:undici@${version}`]));
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = versions.map((version, index) => {
      const original = path.join(root, `undici-${index}`);
      const directory = path.join(root, `.pnpm/npm@${index ? '12.2.0' : '11.20.0'}/node_modules/npm/node_modules/undici`);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      return {directory, original, version, link: fs.readlinkSync(original)};
    });
    const run = directory => spawnSync(process.execPath,
      ['--input-type=module', '-e', undiciRegression, directory], {encoding: 'utf8', timeout: 15000});
    for (const {directory} of directories) {
      const result = run(directory);
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, /Unhandled 'error' event|UND_ERR_RES_CONTENT_LENGTH_MISMATCH|ResponseContentLengthMismatchError/);
    }
    await assert.rejects(patchNpmBundles(root, {undici: {...pin, sha512: '0'.repeat(128)}}), {code: 'ERR_ASSERTION'});
    for (const {directory, version} of directories) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, version);
    }
    const packageFile = path.join(directories.at(-1).directory, 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    fs.writeFileSync(packageFile, JSON.stringify({...JSON.parse(originalPackage), version: '6.28.2'}));
    await assert.rejects(patchNpmBundles(root, {undici: pin}), /unreviewed bundled undici version/);
    fs.writeFileSync(packageFile, JSON.stringify({...JSON.parse(originalPackage), version: '7.18.0'}));
    await assert.rejects(patchNpmBundles(root, {undici: pin}), /unreviewed bundled undici version/);
    fs.writeFileSync(packageFile, originalPackage);
    await patchNpmBundles(root, {undici: pin});
    for (const {directory, original, link} of directories) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, pin.version);
      assert.equal(fs.readlinkSync(original), link);
      const result = run(directory);
      assert.equal(result.error, undefined, result.error?.message);
      assert.equal(result.status, 0, result.stderr || result.stdout);
      assert.match(result.stdout, /without an orphan stream/);
    }
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('repairs only the two vulnerable dependencies inside bundled npm', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-test-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const npm = path.join(root, '.pnpm/npm@11.20.0/node_modules/npm');
    fs.mkdirSync(npm, {recursive: true});
    fs.writeFileSync(path.join(npm, 'package.json'), '{"name":"npm","version":"11.20.0"}\n');
    const bundled = [];
    for (const [index, npmVersion] of ['11.20.0', '12.2.0'].entries()) {
      for (const [name, pin] of Object.entries(pins)) {
        const directory = path.join(root, `.pnpm/npm@${npmVersion}/node_modules/npm/node_modules`, name);
        fs.mkdirSync(directory, {recursive: true});
        const versions = Array.isArray(pin.from) ? pin.from : [pin.from];
        fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify({name, version: versions[index % versions.length]}));
        bundled.push({name, directory, version: pin.version});
      }
    }
    const unrelated = path.join(root, 'unrelated');
    fs.mkdirSync(unrelated);
    fs.writeFileSync(path.join(unrelated, 'package.json'), '{"name":"undici","version":"6.28.0"}');
    await patchNpmBundles(root, pins);
    for (const {name, directory, version} of bundled) {
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.version, version);
      assert.equal(pkg.name, name);
    }
    assert.equal(JSON.parse(fs.readFileSync(path.join(unrelated, 'package.json'))).version, '6.28.0');
    assert.equal(fs.readFileSync(path.join(npm, 'package.json'), 'utf8'), '{"name":"npm","version":"11.20.0"}\n');
    await patchNpmBundles(root, pins); // Idempotent and does not download the archives again.
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('rejects a bundle dependency that escapes its npm root', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-escape-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const npm = path.join(root, '.pnpm/npm@11.20.0/node_modules/npm/node_modules');
    const outside = path.join(temporary, 'outside');
    fs.mkdirSync(npm, {recursive: true});
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, 'package.json'), '{"name":"undici","version":"6.28.0"}');
    fs.symlinkSync(outside, path.join(npm, 'undici'));
    await assert.rejects(patchNpmBundles(root, pins), /unexpected bundled npm dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
