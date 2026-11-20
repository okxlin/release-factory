import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {patchRuntimePackages, verifyRuntimePackage} from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).runtime_packages;
const names = ['qs', 'body-parser', 'dompurify', 'undici', 'joi'];
const run = (source, ...arguments_) => spawnSync(process.execPath, ['--input-type=module', '-e', source, ...arguments_],
  {encoding: 'utf8', timeout: 15000});

test('accepts the actual v2026.11.6 lock baselines without downgrading seroval', {timeout: 120000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-runtime-current-'));
  const baselines = {undici: '8.12.3', hono: '4.13.13', '@hono/node-server': '2.1.5', seroval: '1.7.0'};
  const selected = Object.fromEntries(Object.keys(baselines).map(name => [name, pins[name]]));
  try {
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies: {
      ...baselines, 'seroval-legacy': 'npm:seroval@1.6.11',
    }}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 90000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    const links = new Map();
    for (const [name, version] of Object.entries(baselines)) {
      const original = path.join(root, name);
      const entry = name.replaceAll('/', '+') + '@' + version;
      const directory = path.join(root, '.pnpm', entry, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(path.dirname(original), directory), original);
      directories[name] = directory;
      links.set(original, fs.readlinkSync(original));
    }
    const honoLink = path.join(path.dirname(directories['@hono/node-server']), '..', 'hono');
    fs.symlinkSync(path.relative(path.dirname(honoLink), directories.hono), honoLink);
    links.set(honoLink, fs.readlinkSync(honoLink));
    const legacy = path.join(root, '.pnpm/seroval@1.6.11/node_modules/seroval');
    fs.mkdirSync(path.dirname(legacy), {recursive: true});
    fs.renameSync(path.join(root, 'seroval-legacy'), legacy);
    const preserved = ['package.json', 'dist/index.js'].map(relative =>
      [relative, fs.readFileSync(path.join(directories.seroval, relative))]);
    const receipt = await patchRuntimePackages(root, selected);
    assert.equal(receipt.length, 5);
    for (const [name, directory] of Object.entries(directories)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version,
        name === 'seroval' ? '1.7.0' : selected[name].version);
    }
    assert.equal(JSON.parse(fs.readFileSync(path.join(legacy, 'package.json'))).version, '1.7.0');
    for (const [relative, bytes] of preserved) {
      assert.deepEqual(fs.readFileSync(path.join(directories.seroval, relative)), bytes,
        'current seroval package was rewritten or downgraded');
    }
    for (const [link, target] of links) assert.equal(fs.readlinkSync(link), target);
    await patchRuntimePackages(root, selected);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

// GHSA-27r3-jxmh-p828: the valid gzip frame completes before trailing bytes reach its decoder.
const bodyParserRegression = `
  import assert from 'node:assert/strict';
  import http from 'node:http';
  import {once} from 'node:events';
  import {createRequire} from 'node:module';
  import {gzipSync} from 'node:zlib';
  const require = createRequire(import.meta.url);
  const parser = require(process.argv[1]).json();
  const server = http.createServer((req, res) => parser(req, res, error => {
    res.statusCode = error ? error.status || 500 : 200;
    res.end(JSON.stringify(error ? {error: error.message} : req.body));
  }));
  await once(server.listen(0, '127.0.0.1'), 'listening');
  try {
    const body = Buffer.concat([gzipSync('{"a":1}'), Buffer.from([0]), Buffer.alloc(100 * 1024, 0x58)]);
    const result = await new Promise((resolve, reject) => {
      const req = http.request({host: '127.0.0.1', port: server.address().port, method: 'POST',
        agent: false, headers: {'content-type': 'application/json', 'content-encoding': 'gzip',
          'content-length': body.length}}, res => {
        let text = '';
        res.setEncoding('utf8');
        res.on('data', chunk => { text += chunk; });
        res.once('end', () => resolve({status: res.statusCode, text}));
        res.once('error', reject);
      });
      req.once('error', reject);
      req.end(body);
    });
    assert.equal(result.status, 200);
    assert.equal(result.text, '{"a":1}');
    // Let a decoder error surface after the response has already completed.
    await new Promise(resolve => setTimeout(resolve, 250));
    console.log('body-parser trailing-frame protection passed');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
`;

// The same boundary must still parse UTF-8 URL-encoded data split at every byte.
const bodyParserCompatibility = `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  import {PassThrough} from 'node:stream';
  const require = createRequire(import.meta.url);
  const bodyParser = require(process.argv[1]);
  for (const [parser, contentType, input, expected] of [
    [bodyParser.json(), 'application/json; charset=utf-8', '{"value":"中文€🙂"}', {value: '中文€🙂'}],
    [bodyParser.urlencoded({extended: true}), 'application/x-www-form-urlencoded; charset=utf-8',
      'value=%E4%B8%AD%E6%96%87%E2%82%AC%F0%9F%99%82&nested%5Bx%5D=one%2Btwo',
      {value: '中文€🙂', nested: {x: 'one+two'}}],
  ]) {
    const req = new PassThrough();
    req.headers = {'content-type': contentType, 'content-length': Buffer.byteLength(input)};
    req.method = 'POST';
    const parsed = new Promise((resolve, reject) => parser(req, {}, error => error ? reject(error) : resolve(req.body)));
    for (const byte of Buffer.from(input)) req.write(Buffer.of(byte));
    req.end();
    assert.deepEqual(await parsed, expected);
  }
  console.log('body-parser one-byte UTF-8 and URL decoding passed');
`;

// Official PoCs for GHSA-cg2g-xh64-v4q7 and GHSA-mrv2-3pqr-j5jr; jsdom is fixture-only.
const domPurifyRegression = `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  import path from 'node:path';
  const require = createRequire(path.join(process.argv[2], 'package.json'));
  const {JSDOM} = require('jsdom');
  const createDOMPurify = require(process.argv[1]);
  const win = new JSDOM('<!doctype html><body></body>').window;
  const doc = win.document;
  try {
    if (process.argv[3] === 'shadow') {
      for (const fragments of [['$', '{alert(document.domain)}'], ['{', '{alert(document.domain)}', '}'],
        ['<', '%alert(document.domain)%', '>']]) {
        const host = doc.createElement('div');
        const shadow = host.attachShadow({mode: 'open'});
        for (const fragment of fragments) {
          shadow.appendChild(doc.createTextNode(fragment));
          shadow.appendChild(doc.createElement('object'));
        }
        createDOMPurify(win).sanitize(host, {IN_PLACE: true, SAFE_FOR_TEMPLATES: true});
        shadow.normalize();
        assert.ok(!/\\$\\{|\\{\\{|<%/.test(shadow.textContent), 'shadow root template expression survived');
      }
    } else {
      for (const mode of ['self', 'parent', 'nextSibling']) {
        const purifier = createDOMPurify(win);
        doc.body.innerHTML = '<div id=root><figure><img class=bad src=a.png>' +
          '<img id=evil src=x onerror=alert(1)></figure><p>ok</p></div>';
        const root = doc.getElementById('root');
        const evil = doc.getElementById('evil');
        purifier.addHook('afterSanitizeAttributes', node => {
          if (node.getAttribute && node.getAttribute('class') === 'bad') {
            if (mode === 'self') node.remove();
            if (mode === 'parent') node.parentNode.remove();
            if (mode === 'nextSibling') node.nextElementSibling.remove();
          }
        });
        purifier.sanitize(root, {IN_PLACE: true});
        assert.equal(evil.getAttribute('onerror'), null, 'hook detached subtree kept an event handler: ' + mode);
        assert.equal(root.textContent, 'ok');
      }
    }
    console.log('DOMPurify ' + process.argv[3] + ' protection passed');
  } finally { win.close(); }
`;

// GHSA-xjj6-f33q-929c: catching fetch's rejection must also prevent an orphan stream crash.
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
  const client = new Client('http://127.0.0.1:' + server.address().port);
  try {
    await assert.rejects(fetch('http://127.0.0.1:' + server.address().port, {dispatcher: client}), error => {
      assert.match(error.cause?.message || '', /content-encoding/);
      return true;
    });
    await socketClosed;
    await new Promise(resolve => setTimeout(resolve, 100));
    console.log('undici rejected excessive encoding without an orphan stream');
  } finally { await client.destroy(); await new Promise(resolve => server.close(resolve)); }
`;

// GHSA-4528-x5fx-h6hg: no delimiter must not cause quadratic whitespace splitting.
const joiRegression = `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  import {performance} from 'node:perf_hooks';
  const Joi = createRequire(import.meta.url)(process.argv[1]);
  const spaces = ' '.repeat(100000);
  const mixed = 'joe@example.com' + spaces + 'joe@example.org';
  for (const [options, value, invalids] of [
    [{}, spaces, [spaces]], [{}, mixed, [mixed]],
    [{separator: ';'}, spaces, [spaces]], [{separator: ';'}, mixed, [mixed]],
    [{separator: ', '}, spaces, ['', '']], [{separator: ', '}, mixed, null],
  ]) {
    const schema = Joi.string().email({multiple: true, ...options});
    const start = performance.now();
    const {error} = schema.validate(value);
    assert.ok(performance.now() - start < 1000, 'Joi multiple-email split exceeded one second');
    if (invalids) {
      assert.equal(error.details[0].type, 'string.email');
      assert.deepEqual(error.details[0].context.invalids, invalids);
      const bounded = schema.max(64).validate(value, {abortEarly: false});
      assert.ok(bounded.error.details.some(item => item.type === 'string.email'));
    } else assert.equal(error, undefined);
  }
  console.log('Joi linear multiple-email splitting and separators passed');
`;

function checkPassed(result, signal) {
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.match(result.stdout, signal);
}

test('repairs real runtime packages and preserves pnpm consumers and security protections', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-runtime-packages-'));
  try {
    const dependencies = Object.fromEntries(names.map(name => [name, pins[name].from[0]]));
    dependencies.jsdom = '27.0.1'; // MIT; test-only DOM implementation, lifecycle scripts disabled below.
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    const links = new Map();
    for (const name of names) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', `${name}@${pins[name].from[0]}`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      directories[name] = directory;
      links.set(original, fs.readlinkSync(original));
    }
    const qsLink = path.join(path.dirname(directories['body-parser']), 'qs');
    fs.symlinkSync(path.relative(path.dirname(qsLink), directories.qs), qsLink);
    links.set(qsLink, fs.readlinkSync(qsLink));
    const consumer = path.join(root, 'fixture-consumer/node_modules/body-parser');
    fs.mkdirSync(path.dirname(consumer), {recursive: true});
    fs.symlinkSync(path.relative(path.dirname(consumer), directories['body-parser']), consumer);
    links.set(consumer, fs.readlinkSync(consumer));
    const joiConsumer = path.join(path.dirname(consumer), 'joi');
    fs.symlinkSync(path.relative(path.dirname(joiConsumer), directories.joi), joiConsumer);
    links.set(joiConsumer, fs.readlinkSync(joiConsumer));

    const oldBody = run(bodyParserRegression, directories['body-parser']);
    assert.equal(oldBody.status, 1, oldBody.stderr);
    assert.match(oldBody.stderr, /Unhandled 'error' event|incorrect header check|Z_DATA_ERROR/);
    for (const mode of ['shadow', 'hook']) {
      const result = run(domPurifyRegression, directories.dompurify, temporary, mode);
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, mode === 'shadow' ? /shadow root template expression survived/ : /hook detached subtree/);
    }
    const oldUndici = run(undiciRegression, directories.undici);
    assert.equal(oldUndici.status, 1, oldUndici.stderr);
    assert.match(oldUndici.stderr, /Unhandled 'error' event|UND_ERR_RES_CONTENT_LENGTH_MISMATCH|ResponseContentLengthMismatchError/);
    const oldJoi = spawnSync(process.execPath, ['--input-type=module', '-e', joiRegression, directories.joi],
      {encoding: 'utf8', timeout: 5000});
    if (oldJoi.error) assert.equal(oldJoi.error.code, 'ETIMEDOUT', oldJoi.error.message);
    else {
      assert.equal(oldJoi.status, 1, oldJoi.stderr);
      assert.match(oldJoi.stderr, /Joi multiple-email split exceeded one second/);
    }

    // A wrong integrity pin must leave the package tree unchanged.
    const badPins = structuredClone(pins);
    badPins.qs.sha512 = '0'.repeat(128);
    await assert.rejects(patchRuntimePackages(root, badPins), {code: 'ERR_ASSERTION'});
    for (const name of names) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version, pins[name].from[0]);
    }
    await patchRuntimePackages(root, pins);
    for (const name of names) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version, pins[name].version);
      verifyRuntimePackage(name, directories[name]);
    }
    for (const [link, original] of links) assert.equal(fs.readlinkSync(link), original);
    checkPassed(run(bodyParserRegression, directories['body-parser']), /trailing-frame protection passed/);
    checkPassed(run(bodyParserCompatibility, consumer), /one-byte UTF-8 and URL decoding passed/);
    for (const mode of ['shadow', 'hook']) {
      checkPassed(run(domPurifyRegression, directories.dompurify, temporary, mode), /DOMPurify .* protection passed/);
    }
    checkPassed(run(undiciRegression, directories.undici), /without an orphan stream/);
    checkPassed(run(joiRegression, joiConsumer), /Joi linear multiple-email splitting and separators passed/);
    await patchRuntimePackages(root, pins); // Already fixed packages require no further download.

    const packageFile = path.join(directories.dompurify, 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    const unreviewed = JSON.parse(originalPackage);
    unreviewed.version = '3.4.15';
    fs.writeFileSync(packageFile, JSON.stringify(unreviewed));
    await assert.rejects(patchRuntimePackages(root, pins), /unreviewed|unexpected|vulnerable/);
    fs.writeFileSync(packageFile, originalPackage);
    const outside = path.join(temporary, 'outside-dompurify');
    fs.renameSync(directories.dompurify, outside);
    fs.symlinkSync(outside, directories.dompurify);
    await assert.rejects(patchRuntimePackages(root, pins), /unexpected .* dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('upgrades stable upstream DOMPurify 3.4.17 and still rejects unreviewed versions', {timeout: 120000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-current-dompurify-'));
  try {
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true,
      dependencies: {dompurify: '3.4.17', jsdom: '27.0.1'}}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 90000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const original = path.join(root, 'dompurify');
    const directory = path.join(root, '.pnpm', 'dompurify@3.4.17', 'node_modules/dompurify');
    fs.mkdirSync(path.dirname(directory), {recursive: true});
    fs.renameSync(original, directory);
    fs.symlinkSync(path.relative(root, directory), original);
    const consumer = path.join(root, 'fixture-consumer/node_modules/dompurify');
    fs.mkdirSync(path.dirname(consumer), {recursive: true});
    fs.symlinkSync(path.relative(path.dirname(consumer), directory), consumer);
    const links = new Map([original, consumer].map(link => [link, fs.readlinkSync(link)]));
    const packageFile = path.join(directory, 'package.json');
    assert.equal(JSON.parse(fs.readFileSync(packageFile)).version, '3.4.17');

    const receipt = await patchRuntimePackages(root, {dompurify: pins.dompurify});
    assert.equal(JSON.parse(fs.readFileSync(packageFile)).version, '3.4.18');
    assert.equal(receipt.length, 1);
    assert.equal(receipt[0].version, '3.4.18');
    assert.equal(receipt[0].sha512, pins.dompurify.sha512);
    for (const [link, target] of links) assert.equal(fs.readlinkSync(link), target);
    for (const mode of ['shadow', 'hook']) {
      checkPassed(run(domPurifyRegression, consumer, temporary, mode), /DOMPurify .* protection passed/);
    }

    const fixedPackage = fs.readFileSync(packageFile);
    const unreviewed = JSON.parse(fixedPackage);
    unreviewed.version = '3.4.19';
    fs.writeFileSync(packageFile, JSON.stringify(unreviewed));
    await assert.rejects(patchRuntimePackages(root, {dompurify: pins.dompurify}), /unreviewed dompurify version/);
    fs.writeFileSync(packageFile, fixedPackage);
    await patchRuntimePackages(root, {dompurify: pins.dompurify});
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

// The pinned v2026.11.3 source contains both versions, including the newer copy.
test('upgrades both runtime Undici versions from the current upstream lock', {timeout: 150000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-current-undici-'));
  try {
    const versions = ['8.11.2', '8.12.2'];
    const dependencies = Object.fromEntries(versions.map((version, index) => [`undici-${index}`, `npm:undici@${version}`]));
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = versions.map((version, index) => {
      const original = path.join(root, `undici-${index}`);
      const directory = path.join(root, '.pnpm', `undici@${version}`, 'node_modules/undici');
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      return {original, directory, link: fs.readlinkSync(original), version};
    });
    const unreviewedPins = {undici: {...pins.undici, from: ['8.11.2']}};
    await assert.rejects(patchRuntimePackages(root, unreviewedPins), /unreviewed|unexpected|vulnerable/);
    for (const {directory, version} of directories) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, version);
    }
    await patchRuntimePackages(root, {undici: pins.undici});
    for (const {original, directory, link} of directories) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, pins.undici.version);
      assert.equal(fs.readlinkSync(original), link);
      checkPassed(run(undiciRegression, directory), /without an orphan stream/);
    }
    await patchRuntimePackages(root, {undici: pins.undici});
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('builds browser bundles from fixed DOMPurify and both reviewed Zod 4 versions', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-browser-bundle-'));
  try {
    const dependencies = {dompurify: pins.dompurify.from[0], zod: '4.6.5', zod43: 'npm:zod@4.3.6',
      jsdom: '27.0.1', esbuild: '0.28.2'};
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    for (const [alias, name, version] of [['dompurify', 'dompurify', pins.dompurify.from[0]],
      ['zod', 'zod', '4.6.5'], ['zod43', 'zod', '4.3.6']]) {
      const original = path.join(root, alias);
      const directory = path.join(root, '.pnpm', `${name}@${version}`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
    }
    // Match the browser artifact boundary: dependencies are inlined into one output,
    // and its later execution must not consult the repaired node_modules tree.
    fs.writeFileSync(path.join(temporary, 'build.mjs'), `
      import {build} from 'esbuild';
      await build({stdin: {contents: \`
        const purifier = require('dompurify');
        purifier.zods = {current: require('zod'), older: require('zod43')};
        purifier.versions = {current: require('zod/package.json').version, older: require('zod43/package.json').version};
        module.exports = purifier;
      \`, resolveDir: process.cwd(), sourcefile: 'fixture.cjs'}, bundle: true, platform: 'browser',
        format: 'cjs', minify: true, outfile: process.argv[2], logLevel: 'silent'});
    `);
    const build = name => {
      const output = path.join(temporary, `${name}.cjs`);
      execFileSync(process.execPath, ['build.mjs', output], {cwd: temporary, timeout: 30000, stdio: 'pipe'});
      return output;
    };
    const zodProbe = `
      import assert from 'node:assert/strict';
      import {createRequire} from 'node:module';
      const bundle = createRequire(import.meta.url)(process.argv[1]);
      const key = process.argv[2];
      const z = bundle.zods[key];
      assert.equal(bundle.versions[key], process.argv[3]);
      const result = z.array(z.string()).max(2).safeParse(Array(10000).fill(1));
      assert.equal(result.error.issues.length, 1, 'bundled Zod parsed every oversized element');
      assert.deepEqual(z.object({safe: z.string()}).parse({safe: 'value'}), {safe: 'value'});
      console.log('bundled Zod bounded-container protection passed');
    `;
    const oldBundle = build('before');
    for (const mode of ['shadow', 'hook']) {
      const result = run(domPurifyRegression, oldBundle, temporary, mode);
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, mode === 'shadow' ? /shadow root template expression survived/ : /hook detached subtree/);
    }
    for (const [key, version] of [['current', '4.6.5'], ['older', '4.3.6']]) {
      const result = run(zodProbe, oldBundle, key, version);
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, /bundled Zod parsed every oversized element/);
    }
    await patchRuntimePackages(root, {dompurify: pins.dompurify, zod: pins.zod});
    const fixedBundle = build('after');
    for (const mode of ['shadow', 'hook']) {
      checkPassed(run(domPurifyRegression, fixedBundle, temporary, mode), /DOMPurify .* protection passed/);
    }
    for (const key of ['current', 'older']) {
      checkPassed(run(zodProbe, fixedBundle, key, pins.zod.version), /bundled Zod bounded-container protection passed/);
    }
    // The previously built output remains vulnerable: changing only runtime files
    // cannot repair code already embedded in an asset.
    assert.match(run(zodProbe, oldBundle, 'current', '4.6.5').stderr,
      /bundled Zod parsed every oversized element/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});


// GHSA-qv5m-9pm6-hqp3: reset a real TCP socket while the upgrade handler awaits authentication.
const nodeServerResetRegression = `
  import assert from 'node:assert/strict';
  import {EventEmitter, once} from 'node:events';
  import {createRequire} from 'node:module';
  import {createConnection} from 'node:net';
  const {createAdaptorServer} = createRequire(import.meta.url)(process.argv[1]);
  const wss = new EventEmitter();
  wss.options = {noServer: true};
  wss.handleUpgrade = () => assert.fail('destroyed socket reached the WebSocket handshake');
  wss.close = () => {};
  let entered, release;
  const waiting = new Promise(resolve => { entered = resolve; });
  const pendingAuth = new Promise(resolve => { release = resolve; });
  const server = createAdaptorServer({websocket: {server: wss}, fetch: async (request, env) => {
    if (request.headers.get('upgrade') === 'websocket') {
      entered(env.incoming.socket);
      await pendingAuth;
      return new Response('denied', {status: 403});
    }
    return new Response('healthy');
  }});
  await once(server.listen(0, '127.0.0.1'), 'listening');
  const client = createConnection(server.address().port, '127.0.0.1');
  client.on('error', () => {});
  try {
    await once(client, 'connect');
    client.write('GET /upgrade HTTP/1.1\\r\\nHost: localhost\\r\\n' +
      'Connection: Upgrade\\r\\nUpgrade: websocket\\r\\n' +
      'Sec-WebSocket-Version: 13\\r\\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\n\\r\\n');
    const socket = await waiting;
    const closed = new Promise(resolve => socket.once('close', resolve));
    client.resetAndDestroy();
    await closed;
    release();
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(socket.destroyed, true);
    const response = await fetch('http://127.0.0.1:' + server.address().port + '/health',
      {headers: {connection: 'close'}});
    assert.equal(await response.text(), 'healthy');
    console.log('node-server survived a real TCP reset during asynchronous WebSocket upgrade');
  } finally {
    release(); client.destroy(); server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
`;

test('repairs real Hono, IPv6 and serialization packages with pnpm consumers preserved', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-runtime-network-'));
  const names = ['hono', '@hono/node-server', 'ip-address', 'seroval'];
  const selected = Object.fromEntries(names.map(name => [name, pins[name]]));
  try {
    const dependencies = Object.fromEntries(names.map(name => [name, selected[name].from[0]]));
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    const links = new Map();
    for (const name of names) {
      const original = path.join(root, name);
      const peer = name === '@hono/node-server' ? '_hono@4.13.12' : '';
      const entry = `${name.replaceAll('/', '+')}@${selected[name].from[0]}${peer}`;
      const directory = path.join(root, '.pnpm', entry, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(path.dirname(original), directory), original);
      directories[name] = directory;
      links.set(original, fs.readlinkSync(original));
      if (name === '@hono/node-server') {
        const sibling = path.join(root, '.pnpm', entry, 'node_modules/hono');
        fs.symlinkSync(path.relative(path.dirname(sibling), directories.hono), sibling);
        links.set(sibling, fs.readlinkSync(sibling));
      }
    }
    const oldSignals = {hono: /text\/ping skipped/, '@hono/node-server': /raw backslash path was normalized/,
      'ip-address': /IPv6 zone parsing exceeded/, seroval: /RegExp serialization can close/};
    for (const name of names) {
      assert.throws(() => verifyRuntimePackage(name, directories[name]), error =>
        name === 'ip-address' && error.code === 'ETIMEDOUT' || oldSignals[name].test(error.stderr?.toString()));
    }
    const oldReset = run(nodeServerResetRegression, directories['@hono/node-server']);
    assert.equal(oldReset.status, 1, oldReset.stderr);
    assert.match(oldReset.stderr, /Unhandled 'error' event[\s\S]*ECONNRESET|read ECONNRESET/);
    const bad = structuredClone(selected);
    bad.hono.sha512 = '0'.repeat(128);
    await assert.rejects(patchRuntimePackages(root, bad), {code: 'ERR_ASSERTION'});
    for (const name of names) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version, selected[name].from[0]);
    }
    const receipt = await patchRuntimePackages(root, selected);
    assert.equal(receipt.length, names.length);
    for (const name of names) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version, selected[name].version);
    }
    for (const [link, target] of links) assert.equal(fs.readlinkSync(link), target);
    checkPassed(run(nodeServerResetRegression, directories['@hono/node-server']), /survived a real TCP reset/);
    const esm = run(`
      import assert from 'node:assert/strict';
      import {once} from 'node:events';
      import path from 'node:path';
      import {pathToFileURL} from 'node:url';
      import vm from 'node:vm';
      const {Hono} = await import(pathToFileURL(path.join(process.argv[1], 'dist/index.js')));
      const {csrf} = await import(pathToFileURL(path.join(process.argv[1], 'dist/middleware/csrf/index.js')));
      const {createAdaptorServer} = await import(pathToFileURL(path.join(process.argv[2], 'dist/index.mjs')));
      const seroval = await import(pathToFileURL(path.join(process.argv[3], 'dist/index.js')));
      const app = new Hono();
      app.use('*', csrf());
      app.get('/health/:name', c => c.json({name: c.req.param('name')}));
      app.post('/change', c => c.text('changed'));
      const server = createAdaptorServer({fetch: app.fetch});
      await once(server.listen(0, '127.0.0.1'), 'listening');
      try {
        const base = 'http://127.0.0.1:' + server.address().port;
        assert.deepEqual(await (await fetch(base + '/health/openclaw')).json(), {name: 'openclaw'});
        assert.equal((await fetch(base + '/change', {method: 'POST', body: 'PING',
          headers: {'content-type': 'text/ping', origin: 'https://foreign.test'}})).status, 403);
        const value = new Uint8Array([4, 5]);
        value.constructor = {name: 'Uint8Array([0]);globalThis.serovalInjection=1;//'};
        for (const serialize of [seroval.serialize, seroval.serializeAsync]) {
          const output = await serialize(value);
          assert.equal(output.includes('serovalInjection'), false);
          assert.deepEqual(Array.from(vm.runInNewContext('(' + output + ')', {atob})), [4, 5]);
          const regex = new RegExp('(?<named>a)(?<=a)</script>', 'g');
          const source = await serialize(regex);
          assert.equal(source.includes('<'), false);
          assert.equal(vm.runInNewContext('(' + source + ')').source, regex.source);
        }
        console.log('ESM Hono/adapter HTTP and seroval serialization passed');
      } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    `, directories.hono, directories['@hono/node-server'], directories.seroval);
    checkPassed(esm, /ESM Hono\/adapter HTTP and seroval serialization passed/);
    await patchRuntimePackages(root, selected);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

// GHSA-474x-hrwr-fgx4 requires stopNodes; the actual mailauth caller uses default XML parsing.
const fastXmlStopNodesRegression = `
  import assert from 'node:assert/strict';
  import fs from 'node:fs';
  import {createRequire} from 'node:module';
  import path from 'node:path';
  import {performance} from 'node:perf_hooks';
  import {pathToFileURL} from 'node:url';
  const directory = process.argv[1];
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
  const {XMLParser} = process.argv[2] === 'cjs' ? createRequire(import.meta.url)(directory) :
    await import(pathToFileURL(path.join(directory, pkg.module)));
  const parser = new XMLParser({stopNodes: ['stop']});
  const start = performance.now();
  assert.throws(() => parser.parse('<stop>' + '<a '.repeat(100000)), /Unexpected end/);
  assert.ok(performance.now() - start < 1500, 'XML stop-node parsing exceeded 1.5 seconds');
  console.log('XML stop-node CPU bound passed');
`;

const mailauthSvgCompatibility = `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  const {validateSvg} = createRequire(import.meta.url)(process.argv[1]);
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" baseProfile="tiny-ps">' +
    '<title>safe</title><path d="M0 0 L10 10" /></svg>';
  assert.equal(validateSvg(Buffer.from(svg)), true);
  for (const [xml, code] of [
    [svg.replace('<title>safe</title>', ''), 'LOGO_MISSING_TITLE'],
    [svg.replace('tiny-ps', 'full'), 'INVALID_BASE_PROFILE'],
    [svg.replace('<path d="M0 0 L10 10" />', '<script>alert(1)</script>'), 'LOGO_INVALID_ELEMENT'],
    [svg.replace('<path d="M0 0 L10 10" />',
      '<use xlink:href="https://foreign.test/logo.svg" />'), 'LOGO_INCLUDES_REFERENCE'],
    ['<svg><a ', 'INVALID_XML_FILE'],
  ]) assert.throws(() => validateSvg(Buffer.from(xml)), error => error.code === code);
  console.log('actual mailauth BIMI SVG positive and negative validation passed');
`;

test('repairs XML stop-node parsing with its required peers and preserves mailauth SVG checks', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-xml-runtime-'));
  try {
    // Preserve the published graph from the actual v2026.11.3 lock, including ESM peers.
    const selectedNames = ['is-unsafe', 'strnum', 'fast-xml-parser'];
    const selected = Object.fromEntries(selectedNames.map(name => [name, pins[name]]));
    const dependencies = {mailauth: '7.1.1', '@nodable/entities': '3.1.0', 'fast-xml-builder': '1.3.1',
      'path-expression-matcher': '1.6.2', 'xml-naming': '0.3.0', anynum: '1.0.1',
      ...Object.fromEntries(selectedNames.map(name => [name, selected[name].from[0]]))};
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    const links = new Map();
    for (const name of [...selectedNames, 'mailauth']) {
      const original = path.join(root, name);
      const version = dependencies[name];
      assert.equal(JSON.parse(fs.readFileSync(path.join(original, 'package.json'))).version, version);
      const directory = path.join(root, '.pnpm', `${name}@${version}`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      directories[name] = directory;
      links.set(original, fs.readlinkSync(original));
    }
    for (const [consumer, name] of [['fast-xml-parser', 'is-unsafe'], ['fast-xml-parser', 'strnum'],
      ['mailauth', 'fast-xml-parser']]) {
      const link = path.join(path.dirname(directories[consumer]), name);
      fs.symlinkSync(path.relative(path.dirname(link), directories[name]), link);
      links.set(link, fs.readlinkSync(link));
    }
    const svgEntry = path.join(directories.mailauth, 'lib/bimi/validate-svg.js');
    const originalSvgSource = fs.readFileSync(svgEntry);
    const mailauthPackage = fs.readFileSync(path.join(directories.mailauth, 'package.json'));
    checkPassed(run(mailauthSvgCompatibility, svgEntry), /actual mailauth BIMI SVG/);
    for (const mode of ['cjs', 'esm']) {
      const old = spawnSync(process.execPath, ['--input-type=module', '-e', fastXmlStopNodesRegression,
        directories['fast-xml-parser'], mode], {encoding: 'utf8', timeout: 2000});
      if (old.error) assert.equal(old.error.code, 'ETIMEDOUT', old.error.message);
      else {
        assert.equal(old.status, 1, old.stderr);
        assert.match(old.stderr, /XML stop-node parsing exceeded/);
      }
    }
    const badPins = structuredClone(selected);
    badPins['is-unsafe'].sha512 = '0'.repeat(128);
    await assert.rejects(patchRuntimePackages(root, badPins), {code: 'ERR_ASSERTION'});
    for (const name of selectedNames) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version,
        selected[name].from[0]);
    }
    await patchRuntimePackages(root, selected);
    for (const name of selectedNames) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directories[name], 'package.json'))).version,
        selected[name].version);
      verifyRuntimePackage(name, directories[name]);
    }
    for (const [link, original] of links) assert.equal(fs.readlinkSync(link), original);
    for (const mode of ['cjs', 'esm']) {
      checkPassed(run(fastXmlStopNodesRegression, directories['fast-xml-parser'], mode), /XML stop-node CPU bound passed/);
    }
    checkPassed(run(mailauthSvgCompatibility, svgEntry), /actual mailauth BIMI SVG/);
    assert.deepEqual(fs.readFileSync(svgEntry), originalSvgSource);
    assert.deepEqual(fs.readFileSync(path.join(directories.mailauth, 'package.json')), mailauthPackage);
    await patchRuntimePackages(root, selected);
    const packageFile = path.join(directories['fast-xml-parser'], 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    fs.writeFileSync(packageFile, JSON.stringify({...JSON.parse(originalPackage), version: '5.12.1'}));
    await assert.rejects(patchRuntimePackages(root, selected), /unreviewed fast-xml-parser version/);
    fs.writeFileSync(packageFile, originalPackage);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
