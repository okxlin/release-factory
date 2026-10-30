import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {patchRuntimePackages, verifyRuntimePackage} from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).runtime_packages;
const names = ['qs', 'body-parser', 'dompurify', 'undici'];
const run = (source, ...arguments_) => spawnSync(process.execPath, ['--input-type=module', '-e', source, ...arguments_],
  {encoding: 'utf8', timeout: 15000});

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
