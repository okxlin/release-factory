import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchNpmBundles, verifyIpAddress, verifySelectorParser } from '../openclaw-builder/image/patch-vendored-deps.mjs';

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
      const npmVersion = index ? `12.2.${index - 1}` : '11.20.0';
      const directory = path.join(root, `.pnpm/npm@${npmVersion}/node_modules/npm/node_modules/undici`);
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

// These bundled versions come from https://registry.npmjs.org/npm/12.2.1.
test('repairs the complete real npm 12.2.1 pnpm bundle and preserves its CLI', {timeout: 150000}, async () => {
  const version = '12.2.1';
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-12-2-1-'));
  try {
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies: {npm: version}}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const original = path.join(root, 'npm');
    const directory = path.join(root, `.pnpm/npm@${version}/node_modules/npm`);
    fs.mkdirSync(path.dirname(directory), {recursive: true});
    fs.renameSync(original, directory);
    fs.symlinkSync(path.relative(root, directory), original);
    const link = fs.readlinkSync(original);
    const packageFile = path.join(directory, 'package.json');
    const packageBytes = fs.readFileSync(packageFile);
    const npmLicense = fs.readFileSync(path.join(directory, 'LICENSE'));
    assert.equal(JSON.parse(packageBytes).version, version);
    const bundled = name => path.join(directory, 'node_modules', name);
    const sourceVersions = {'brace-expansion': '5.0.12', undici: '6.29.0',
      'ip-address': '10.7.2', 'postcss-selector-parser': '7.1.6'};
    assert.deepEqual(Object.keys(pins).sort(), Object.keys(sourceVersions).sort());
    for (const [name, version] of Object.entries(sourceVersions)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(bundled(name), 'package.json'))).version, version);
    }
    await patchNpmBundles(root, pins);
    const licenses = {'brace-expansion': ['LICENSE'], undici: ['LICENSE', 'lib/web/fetch/LICENSE'],
      'ip-address': ['LICENSE'], 'postcss-selector-parser': ['LICENSE-MIT']};
    for (const [name, pin] of Object.entries(pins)) {
      const repaired = JSON.parse(fs.readFileSync(path.join(bundled(name), 'package.json')));
      assert.equal(repaired.version, pin.version);
      assert.equal(repaired.license, 'MIT');
      for (const license of licenses[name]) {
        assert.ok(fs.readFileSync(path.join(bundled(name), license), 'utf8').trim(), `missing ${name} ${license}`);
      }
    }
    assert.deepEqual(fs.readFileSync(packageFile), packageBytes);
    assert.deepEqual(fs.readFileSync(path.join(directory, 'LICENSE')), npmLicense);
    assert.equal(fs.readlinkSync(original), link);
    const cli = path.join(directory, 'bin/npm-cli.js');
    assert.equal(execFileSync(process.execPath, [cli, '--version'], {encoding: 'utf8', timeout: 10000}).trim(), version);
    const query = JSON.parse(execFileSync(process.execPath, [cli, 'query', '[name="npm"]'],
      {cwd: temporary, encoding: 'utf8', timeout: 15000}));
    assert.ok(query.some(pkg => pkg.name === 'npm' && pkg.version === version));
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', undiciRegression, bundled('undici')],
      {encoding: 'utf8', timeout: 15000});
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /without an orphan stream/);
    const unknownVersions = {'brace-expansion': '5.1.1', undici: '6.29.2',
      'ip-address': '10.7.8', 'postcss-selector-parser': '7.2.2'};
    for (const [name, version] of Object.entries(unknownVersions)) {
      const packageFile = path.join(bundled(name), 'package.json');
      const repairedPackage = fs.readFileSync(packageFile);
      const unreviewedPackage = JSON.stringify({...JSON.parse(repairedPackage), version});
      fs.writeFileSync(packageFile, unreviewedPackage);
      await assert.rejects(patchNpmBundles(root, pins), new RegExp(`unreviewed bundled ${name} version`));
      assert.equal(fs.readFileSync(packageFile, 'utf8'), unreviewedPackage);
      fs.writeFileSync(packageFile, repairedPackage);
    }
    const integrityPackage = path.join(bundled('ip-address'), 'package.json');
    const repairedPackage = fs.readFileSync(integrityPackage);
    const reviewedPackage = JSON.stringify({...JSON.parse(repairedPackage), version: sourceVersions['ip-address']});
    fs.writeFileSync(integrityPackage, reviewedPackage);
    const badPins = structuredClone(pins);
    badPins['ip-address'].sha512 = '0'.repeat(128);
    await assert.rejects(patchNpmBundles(root, badPins), {
      code: 'ERR_ASSERTION', actual: pins['ip-address'].sha512, expected: badPins['ip-address'].sha512,
    });
    assert.equal(fs.readFileSync(integrityPackage, 'utf8'), reviewedPackage);
    fs.writeFileSync(integrityPackage, repairedPackage);
    await patchNpmBundles(root, pins);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('repairs only the two vulnerable dependencies inside bundled npm', async () => {
  const selected = {'brace-expansion': pins['brace-expansion'], undici: pins.undici};
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-test-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const npm = path.join(root, '.pnpm/npm@11.20.0/node_modules/npm');
    fs.mkdirSync(npm, {recursive: true});
    fs.writeFileSync(path.join(npm, 'package.json'), '{"name":"npm","version":"11.20.0"}\n');
    const bundled = [];
    for (const [index, npmVersion] of ['11.20.0', '12.2.0'].entries()) {
      for (const [name, pin] of Object.entries(selected)) {
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
    await patchNpmBundles(root, selected);
    for (const {name, directory, version} of bundled) {
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.version, version);
      assert.equal(pkg.name, name);
    }
    assert.equal(JSON.parse(fs.readFileSync(path.join(unrelated, 'package.json'))).version, '6.28.0');
    assert.equal(fs.readFileSync(path.join(npm, 'package.json'), 'utf8'), '{"name":"npm","version":"11.20.0"}\n');
    await patchNpmBundles(root, selected); // Idempotent and does not download the archives again.
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

test('repairs the real global npm bundle and preserves its CLI', {timeout: 150000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-global-npm-'));
  try {
    const components = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url)));
    const version = components.build_args.OPENCLAW_NPM_VERSION;
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies: {npm: version}}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directory = path.join(root, 'npm');
    const packageFile = path.join(directory, 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    assert.equal(JSON.parse(originalPackage).version, version);
    await patchNpmBundles(root, pins);
    for (const [name, pin] of Object.entries(pins)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'node_modules', name, 'package.json'))).version, pin.version);
    }
    assert.deepEqual(fs.readFileSync(packageFile), originalPackage);
    const cli = execFileSync(process.execPath, [path.join(directory, 'bin/npm-cli.js'), '--version'],
      {encoding: 'utf8', timeout: 15000});
    assert.equal(cli.trim(), version);
    await patchNpmBundles(root, pins);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('rejects a global npm bundle that escapes its supplied root', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-global-npm-escape-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const outside = path.join(temporary, 'outside/npm');
    fs.mkdirSync(root);
    fs.mkdirSync(path.join(outside, 'node_modules/brace-expansion'), {recursive: true});
    fs.writeFileSync(path.join(outside, 'package.json'), '{"name":"npm","version":"11.21.2"}');
    const packageFile = path.join(outside, 'node_modules/brace-expansion/package.json');
    fs.writeFileSync(packageFile, '{"name":"brace-expansion","version":"5.0.12"}');
    const original = fs.readFileSync(packageFile);
    fs.symlinkSync(outside, path.join(root, 'npm'));
    await assert.rejects(patchNpmBundles(root, pins), /unexpected bundled npm.*path/);
    assert.deepEqual(fs.readFileSync(packageFile), original);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});


test('repairs the actual pnpm npm distribution networking and selector dependencies', {timeout: 150000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-network-'));
  try {
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies: {npm: '12.2.0'}}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const original = path.join(root, 'npm');
    const directory = path.join(root, '.pnpm/npm@12.2.0/node_modules/npm');
    fs.mkdirSync(path.dirname(directory), {recursive: true});
    fs.renameSync(original, directory);
    fs.symlinkSync(path.relative(root, directory), original);
    const link = fs.readlinkSync(original);
    const packageFile = path.join(directory, 'package.json');
    const packageBytes = fs.readFileSync(packageFile);
    const selected = {'ip-address': pins['ip-address'], 'postcss-selector-parser': pins['postcss-selector-parser']};
    const bundled = name => path.join(directory, 'node_modules', name);
    const oldVersions = Object.fromEntries(Object.keys(selected).map(name =>
      [name, JSON.parse(fs.readFileSync(path.join(bundled(name), 'package.json'))).version]));
    assert.equal(oldVersions['ip-address'], '10.5.0');
    assert.equal(oldVersions['postcss-selector-parser'], '7.1.4');
    assert.throws(() => verifyIpAddress(bundled('ip-address')),
      error => /IPv6 link-local address escaped classification/.test(error.stderr?.toString()));
    assert.throws(() => verifySelectorParser(bundled('postcss-selector-parser')),
      error => error.code === 'ETIMEDOUT' || /flat selector parsing exceeded/.test(error.stderr?.toString()));
    const bad = structuredClone(selected);
    bad['ip-address'].sha512 = '0'.repeat(128);
    await assert.rejects(patchNpmBundles(root, bad), {code: 'ERR_ASSERTION'});
    for (const [name, version] of Object.entries(oldVersions)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(bundled(name), 'package.json'))).version, version);
    }
    await patchNpmBundles(root, selected);
    for (const [name, pin] of Object.entries(selected)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(bundled(name), 'package.json'))).version, pin.version);
    }
    assert.deepEqual(fs.readFileSync(packageFile), packageBytes);
    assert.equal(fs.readlinkSync(original), link);
    const cli = path.join(directory, 'bin/npm-cli.js');
    assert.equal(execFileSync(process.execPath, [cli, '--version'], {encoding: 'utf8', timeout: 10000}).trim(), '12.2.0');
    // npm query is the actual selector-parser consumer, using the repaired bundle.
    const query = JSON.parse(execFileSync(process.execPath, [cli, 'query', '[name="npm"]'],
      {cwd: temporary, encoding: 'utf8', timeout: 15000}));
    assert.ok(query.some(pkg => pkg.name === 'npm' && pkg.version === '12.2.0'));
    await patchNpmBundles(root, selected);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
