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
  let bundles;
  if (fs.existsSync(store)) {
    bundles = fs.readdirSync(store).filter(entry => /^npm@\d/.test(entry))
      .map(entry => path.join(store, entry, 'node_modules/npm/node_modules'));
  } else {
    const npm = path.join(root, 'npm');
    assert.equal(fs.realpathSync(npm), npm, 'unexpected bundled npm root path');
    assert.equal(JSON.parse(fs.readFileSync(path.join(npm, 'package.json'))).name, 'npm');
    bundles = [path.join(npm, 'node_modules')];
  }
  for (const [name, pin] of Object.entries(pins)) {
    assert.ok(['brace-expansion', 'undici', 'ip-address', 'postcss-selector-parser'].includes(name));
    assert.match(pin.version, /^\d+\.\d+\.\d+$/);
    assert.equal(pin.url, `https://registry.npmjs.org/${name}/-/${name}-${pin.version}.tgz`);
    assert.match(pin.sha512, /^[a-f0-9]{128}$/);
    const outdated = [];
    const directories = [];
    for (const bundle of bundles) {
      const directory = path.join(bundle, name);
      if (!fs.existsSync(directory)) continue;
      assert.equal(fs.realpathSync(directory), directory, 'unexpected bundled npm dependency path');
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.name, name);
      directories.push(directory);
      if (pinFromVersions(pin).includes(pkg.version)) outdated.push(directory);
      else assert.equal(pkg.version, pin.version, `unreviewed bundled ${name} version`);
    }
    await replaceVerifiedDependency(name, pin, outdated);
    // Selector parsing needs the original sibling dependencies from npm.
    for (const directory of directories) {
      if (name === 'ip-address') verifyIpAddress(directory);
      else if (name === 'postcss-selector-parser') verifySelectorParser(directory);
    }
  }
}

function pinFromVersions(pin) {
  const versions = Array.isArray(pin.from) ? pin.from : [pin.from];
  assert.ok(versions.length > 0);
  for (const version of versions) assert.match(version, /^\d+\.\d+\.\d+$/);
  return versions;
}

function assertDependencyPin(name, pin) {
  assert.match(pin.version, /^\d+\.\d+\.\d+$/);
  assert.equal(pin.url, `https://registry.npmjs.org/${name}/-/${name.split('/').at(-1)}-${pin.version}.tgz`);
  assert.match(pin.sha512, /^[a-f0-9]{128}$/);
  pinFromVersions(pin);
}

function packageDirectory(store, entry, name, message) {
  const directory = path.join(store, entry, 'node_modules', name);
  assert.equal(fs.realpathSync(directory), directory, message);
  return directory;
}

function prepareZod(directory, compatibility, version) {
  // The reviewed v4 package fixes bounded containers; A2UI still consumes the v3 API.
  // Keep its entry contract and backport the same early size rejection to v3.
  // https://github.com/colinhacks/zod/pull/6652
  const packageFile = path.join(directory, 'package.json');
  const pkg = JSON.parse(fs.readFileSync(packageFile));
  assert.equal(pkg.name, 'zod');
  assert.equal(pkg.version, version);
  assert.ok(pkg.exports && typeof pkg.exports === 'object');
  if (compatibility === 'v3') {
    pkg.exports['.'] = structuredClone(pkg.exports['./v3']);
    pkg.main = './v3/index.cjs';
    pkg.module = './v3/index.js';
    pkg.types = './v3/index.d.cts';
  }
  pkg['release-factory'] = {source: `zod@${version}`, root: compatibility ?? 'v4', patches: ['v3-bounded-container-gate']};
  fs.writeFileSync(packageFile, `${JSON.stringify(pkg, null, 2)}\n`);

  const patches = [
    ['v3/types.js', 'INVALID'],
    ['v3/types.cjs', 'parseUtil_js_1.INVALID'],
    ['src/v3/types.ts', 'INVALID'],
  ];
  for (const [relative, invalid] of patches) {
    const file = path.join(directory, relative);
    assert.equal(fs.realpathSync(file), file, 'unexpected zod v3 source path');
    let source = fs.readFileSync(file, 'utf8');
    for (const field of ['exactLength', 'maxLength', 'maxSize']) {
      const anchor = new RegExp(`message: def\\.${field}\\.message,\\n[ \\t]*}\\);\\n([ \\t]*)status\\.dirty\\(\\);`, 'g');
      assert.equal([...source.matchAll(anchor)].length, 1, `missing zod v3 ${field} patch anchor: ${relative}`);
      source = source.replace(anchor, (matched, indent) => matched + '\n' + indent +
        (field === 'exactLength' ? `if (tooBig) return ${invalid};` : `return ${invalid};`));
    }
    fs.writeFileSync(file, source);
  }
  return pkg;
}

export function verifyZod(directory, compatibility = 'v4') {
  // A fresh process also avoids Node's package-entry cache after an in-place replacement.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    const directory = process.argv[1];
    const zod = createRequire(path.join(directory, 'package.json'))(directory);
    const object = zod.object({name: zod.string()});
    assert.deepEqual(object.parse({name: 'openclaw'}), {name: 'openclaw'});
    assert.equal(object.safeParse({name: 42}).success, false);
    if (process.argv[2] === 'v3') assert.equal(object._def.typeName, 'ZodObject');
    const result = zod.array(zod.string()).max(2).safeParse(new Array(10000).fill(1));
    assert.equal(result.success, false);
    assert.equal(result.error.issues.length, 1, 'bounded zod container parsed every oversized element');
  `, directory, compatibility], {timeout: 10000, stdio: 'pipe'});
  console.log(`Verified CVE-2023-54404 bounded container guard (${compatibility}): ${directory}`);
}

export function verifyJoi(directory) {
  // https://github.com/hapijs/joi/security/advisories/GHSA-4528-x5fx-h6hg
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    import {performance} from 'node:perf_hooks';
    const joi = createRequire(path.join(process.argv[1], 'package.json'))(process.argv[1]);
    const object = joi.object({name: joi.string().required()});
    assert.deepEqual(object.validate({name: 'openclaw'}).value, {name: 'openclaw'});
    assert.ok(object.validate({name: 42}).error);
    for (const options of [{}, {separator: ';'}]) {
      const email = joi.string().email({multiple: true, ...options});
      const separator = options.separator || ',';
      assert.equal(email.validate('joe@example.com' + separator + ' jane@example.org').error, undefined);
      const start = performance.now();
      const result = email.max(64).validate(' '.repeat(100000), {abortEarly: false});
      assert.ok(result.error.details.some(item => item.type === 'string.email'));
      assert.ok(performance.now() - start < 1000, 'Joi multiple-email split exceeded one second');
    }
  `, directory], {timeout: 10000, stdio: 'pipe'});
  console.log(`Verified CVE-2026-118772 linear multiple-email splitting: ${directory}`);
}

export function verifyIpAddress(directory) {
  // GHSA-rxp7-6hxx-x8q5, GHSA-rpw4-54j3-4h4q, GHSA-2vr4-cq9g-pvrc and GHSA-j6r3-76f7-8jcv.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import {performance} from 'node:perf_hooks';
    const {Address4, Address6} = createRequire(import.meta.url)(process.argv[1]);
    for (const host of ['fe80::1', 'fe81::1', 'febf::1', 'fe80:0:0:1::1']) {
      assert.equal(new Address6(host).isLinkLocal(), true, 'IPv6 link-local address escaped classification');
    }
    assert.equal(new Address6('fec0::1').isLinkLocal(), false);
    for (const host of ['64:ff9b:1:7f00:0:100::', '64:ff9b:1::7f00:1']) {
      assert.equal(new Address6(host).isPrivate(), true, 'NAT64 local-use range escaped classification');
    }
    const network = new Address6('2001:db8::/32');
    assert.equal(new Address6('2001:db8::1').isInSubnet(network), true);
    for (const method of ['isInSubnet', 'isHostInSubnet']) {
      assert.equal(new Address4('32.1.13.184')[method](network), false, 'cross-family subnet admitted');
    }
    assert.equal(new Address6('2001:db8::1').correctForm(), '2001:db8::1');
    assert.equal(new Address6('fe80::1%eth0').zone, '%eth0');
    const start = performance.now();
    assert.equal(Address6.isValid('%'.repeat(200000) + '\\n'), false);
    assert.ok(performance.now() - start < 1500, 'IPv6 zone parsing exceeded 1.5 seconds');
    console.log('ip-address classification and bounded parsing passed');
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifySelectorParser(directory) {
  // https://github.com/postcss/postcss-selector-parser/security/advisories/GHSA-rj75-hqrm-r3gf
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import {performance} from 'node:perf_hooks';
    const parser = createRequire(import.meta.url)(process.argv[1]);
    const selector = 'svg|a:hover > .safe[data-value="a,b"], #id';
    assert.equal(parser().processSync(selector), selector);
    const count = 100000;
    const start = performance.now();
    const ast = parser().astSync('.a'.repeat(count));
    assert.equal(ast.first.nodes.length, count);
    assert.ok(performance.now() - start < 1500, 'flat selector parsing exceeded 1.5 seconds');
    assert.throws(() => parser().astSync('[unclosed'));
    console.log('selector-parser linear parsing and selector compatibility passed');
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifyHono(directory) {
  // Hono 4.13.16 fixes CSRF, multipart validation, mount and wildcard routing.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    const require = createRequire(path.join(process.argv[1], 'package.json'));
    const {Hono} = require('hono');
    const {csrf} = require('hono/csrf');
    const {validator} = require('hono/validator');
    const {RegExpRouter} = require('hono/router/reg-exp-router');
    const csrfApp = new Hono();
    csrfApp.use('*', csrf());
    csrfApp.post('/change', c => c.text('changed'));
    for (const [origin, status] of [['https://foreign.test', 403], ['https://hono.test', 200]]) {
      assert.equal((await csrfApp.request('https://hono.test/change', {method: 'POST',
        headers: {'content-type': 'text/ping', origin}, body: 'PING'})).status, status,
        'text/ping skipped the origin check');
    }
    const formApp = new Hono();
    formApp.post('/form', validator('form', (value, c) => value.forbidden ? c.text('rejected', 400) : value),
      c => c.json(c.req.valid('form')));
    for (const [field, status] of [['forbidden', 400], ['safe', 200]]) {
      const body = '--fixture\\r\\nContent-Disposition: form-data; name="' + field +
        '"\\r\\n\\r\\nvalue\\r\\n--fixture--\\r\\n';
      const response = await formApp.request('https://hono.test/form', {method: 'POST',
        headers: {'content-type': 'multipart/form-data; charset=utf-8; boundary=fixture'}, body});
      assert.equal(response.status, status, 'multipart parameters skipped form validation');
      if (status === 200) assert.deepEqual(await response.json(), {safe: 'value'});
    }
    const inner = new Hono();
    inner.get('/admin/secret', c => c.text('secret'));
    inner.get('/public', c => c.text('public'));
    for (const [prefix, unsafe, positive] of [
      ['/app', '/app/public%5C..%5Cadmin/secret', '/app/public'],
      ['/api/:tenant', '/api/a/xxxxx/admin/secret', '/api/long-tenant/public'],
    ]) {
      const outer = new Hono();
      outer.use(prefix + '/admin/*', c => c.text('blocked', 401));
      outer.mount(prefix, inner.fetch);
      assert.equal((await outer.request('https://hono.test' + unsafe)).status, 404,
        'mounted path bypassed scoped middleware');
      assert.equal(await (await outer.request('https://hono.test' + positive)).text(), 'public');
    }
    for (const [middleware, route, request] of [
      ['/api/:tenant{[^/]+}/admin/*', '/api/:tenant/admin/:id', '/api/team/admin/secret'],
      ['/admin/*', '/admin*', '/admin/secret'],
      ['*', '/normal', '/other%0Apath'],
    ]) {
      const app = new Hono({router: new RegExpRouter()});
      app.use(middleware, c => c.text('blocked', 401));
      app.get(route, c => c.text('secret'));
      assert.equal((await app.request('https://hono.test' + request)).status, 401,
        'wildcard middleware skipped an equivalent path');
    }
    console.log('Hono origin, form and route protections passed');
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifyHonoNodeServer(directory) {
  // https://github.com/honojs/node-server/security/advisories/GHSA-jpvv-r467-5p4w
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {once} from 'node:events';
    import {createRequire} from 'node:module';
    import {createConnection} from 'node:net';
    const {createAdaptorServer} = createRequire(import.meta.url)(process.argv[1]);
    const server = createAdaptorServer({fetch: request => new Response(new URL(request.url).pathname)});
    await once(server.listen(0, '127.0.0.1'), 'listening');
    const exchange = target => new Promise((resolve, reject) => {
      const socket = createConnection(server.address().port, '127.0.0.1');
      let response = '';
      socket.once('connect', () => socket.end('GET ' + target +
        ' HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n'));
      socket.setEncoding('utf8');
      socket.on('data', chunk => { response += chunk; });
      socket.once('end', () => resolve(response));
      socket.once('error', reject);
    });
    try {
      for (const target of ['/admin\\\\secret', '/public\\\\..\\\\admin/secret',
        'http://localhost/admin\\\\secret']) {
        assert.match(await exchange(target), /^HTTP\\/1\\.1 400 /, 'raw backslash path was normalized');
      }
      for (const target of ['/public', '/admin%5Csecret', '/public?q=\\\\value']) {
        assert.match(await exchange(target), /^HTTP\\/1\\.1 200 /);
      }
      console.log('node-server raw path rejection and HTTP compatibility passed');
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifySeroval(directory) {
  // GHSA-9wx9-5pv9-3349 and GHSA-f86p-h4j2-7qgj; compact buffers need the standard atob decoder.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import vm from 'node:vm';
    const {serialize} = createRequire(import.meta.url)(process.argv[1]);
    const expression = new RegExp('(?<word>a)(?<=a)</script>', 'g');
    const source = serialize(expression);
    assert.equal(source.includes('<'), false, 'RegExp serialization can close an HTML script');
    const revived = vm.runInNewContext('(' + source + ')');
    assert.equal(revived.source, expression.source);
    assert.equal(revived.flags, expression.flags);
    const value = new Uint8Array([1, 2, 3]);
    value.constructor = {name: 'Uint8Array([0]);globalThis.serovalInjection=1;//'};
    for (const options of [{}, {compactArrayBufferViews: true}]) {
      const output = serialize(value, options);
      assert.equal(output.includes('serovalInjection'), false, 'typed array constructor injected code');
      assert.deepEqual(Array.from(vm.runInNewContext('(' + output + ')', {atob})), [1, 2, 3]);
    }
    console.log('seroval script escaping and intrinsic typed array serialization passed');
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

function verifyXmlDependency(name, directory) {
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import fs from 'node:fs';
    import path from 'node:path';
    import {pathToFileURL} from 'node:url';
    const name = process.argv[1], directory = process.argv[2];
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    const api = await import(pathToFileURL(path.join(directory, pkg.module || pkg.main)));
    if (name === 'is-unsafe') {
      assert.equal(api.isUnsafe('safe &amp; text', api.XML), false);
      assert.equal(api.isUnsafe('<!DOCTYPE root SYSTEM "https://foreign.test/xxe">', api.XML), true);
    } else {
      assert.equal(api.default('42'), 42);
      assert.equal(api.default(' 0.5 '), 0.5);
      assert.equal(api.default('001', {leadingZeros: false}), '001');
      assert.equal(api.default('text'), 'text');
    }
  `, name, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifyFastXmlParser(directory) {
  // https://github.com/NaturalIntelligence/fast-xml-parser/security/advisories/GHSA-474x-hrwr-fgx4
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import fs from 'node:fs';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    import {performance} from 'node:perf_hooks';
    import {pathToFileURL} from 'node:url';
    const directory = process.argv[1];
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    const require = createRequire(path.join(directory, 'package.json'));
    const unsafePackage = path.join(path.dirname(require.resolve('is-unsafe')), '..', 'package.json');
    assert.equal(JSON.parse(fs.readFileSync(unsafePackage)).version, '2.0.3');
    assert.equal(JSON.parse(fs.readFileSync(require.resolve('strnum/package.json'))).version, '2.5.1');
    for (const {XMLParser, XMLBuilder, XMLValidator} of [require(directory),
      await import(pathToFileURL(path.join(directory, pkg.module)))]) {
      const options = {ignoreAttributes: false, attributeNamePrefix: '@_'};
      const parser = new XMLParser(options);
      const svg = '<svg baseProfile="tiny-ps"><title>A &amp; B</title><rect width="32" /></svg>';
      const parsed = parser.parse(svg);
      assert.equal(parsed.svg.title, 'A & B');
      assert.equal(parsed.svg.rect['@_width'], '32');
      assert.deepEqual(parser.parse(new XMLBuilder(options).build(parsed)), parsed);
      assert.equal(XMLValidator.validate(svg), true);
      assert.notEqual(XMLValidator.validate('<root><unclosed></root>'), true);
      const stop = new XMLParser({stopNodes: ['root.stop']});
      for (const raw of ['before <a href=">">one</a> after',
        'if (a < b) "<a unclosed text <b>raw', 'before<stop>nested</stop>after']) {
        assert.deepEqual(stop.parse('<root><stop>' + raw + '</stop><count>42</count></root>'),
          {root: {stop: raw, count: 42}});
      }
      const hostile = new XMLParser({stopNodes: ['stop']});
      const start = performance.now();
      assert.throws(() => hostile.parse('<stop>' + '<a '.repeat(100000)), /Unexpected end/);
      assert.ok(performance.now() - start < 1500, 'XML stop-node parsing exceeded 1.5 seconds');
    }
    console.log('fast-xml-parser CJS/ESM XML and bounded stop-node parsing passed');
  `, directory], {timeout: 10000, stdio: 'pipe'});
}

export function verifyRuntimePackage(name, directory, compatibility) {
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
  assert.equal(pkg.name, name);
  const require = createRequire(path.join(directory, 'package.json'));
  if (name === 'qs') {
    assert.equal(require(directory).parse('safe=value').safe, 'value');
  } else if (name === 'body-parser') {
    const parser = require(directory);
    assert.equal(typeof parser.json, 'function');
    assert.equal(typeof parser.urlencoded, 'function');
    assert.equal(typeof parser.json(), 'function');
    assert.equal(JSON.parse(fs.readFileSync(require.resolve('qs/package.json'))).version, '6.16.1');
  } else if (name === 'dompurify') {
    const createDOMPurify = require(directory);
    assert.equal(typeof createDOMPurify, 'function');
    assert.equal(createDOMPurify.version, pkg.version);
  } else if (name === 'undici') {
    const undici = require(directory);
    assert.equal(typeof undici.fetch, 'function');
    assert.equal(typeof undici.request, 'function');
  } else if (name === 'zod') {
    verifyZod(directory, compatibility);
  } else if (name === 'joi') {
    verifyJoi(directory);
  } else if (name === 'hono') {
    verifyHono(directory);
  } else if (name === '@hono/node-server') {
    verifyHonoNodeServer(directory);
  } else if (name === 'ip-address') {
    verifyIpAddress(directory);
  } else if (name === 'seroval') {
    verifySeroval(directory);
  } else if (name === 'is-unsafe' || name === 'strnum') {
    verifyXmlDependency(name, directory);
  } else if (name === 'fast-xml-parser') {
    verifyFastXmlParser(directory);
  } else {
    assert.fail(`unreviewed runtime dependency: ${name}`);
  }
}

export async function patchRuntimePackages(root, pins) {
  root = fs.realpathSync(root);
  const store = path.join(root, '.pnpm');
  const evidence = [];
  for (const [name, pin] of Object.entries(pins)) {
    assert.ok(['qs', 'body-parser', 'dompurify', 'undici', 'zod', 'joi', 'hono', '@hono/node-server', 'ip-address', 'seroval', 'is-unsafe', 'strnum', 'fast-xml-parser'].includes(name), `unreviewed runtime dependency: ${name}`);
    assertDependencyPin(name, pin);
    const fromVersions = pinFromVersions(pin);
    const directories = [];
    const outdated = new Map(fromVersions.map(version => [version, []]));
    const prefix = `${name.replaceAll('/', '+')}@`;
    for (const entry of fs.readdirSync(store)) {
      if (!entry.startsWith(prefix)) continue;
      const directory = packageDirectory(store, entry, name, `unexpected ${name} dependency path`);
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.name, name);
      directories.push({directory, entry});
      if (outdated.has(pkg.version)) outdated.get(pkg.version).push(directory);
      else assert.equal(pkg.version, pin.version, `unreviewed ${name} version`);
    }
    for (const from of fromVersions) {
      const targets = outdated.get(from);
      if (!targets.length) continue;
      await replaceVerifiedDependency(name, pin, targets, directory => {
        // These packages need their existing sibling dependencies in the pnpm store.
        if (!['body-parser', 'qs', 'joi', '@hono/node-server', 'strnum', 'fast-xml-parser'].includes(name)) verifyRuntimePackage(name, directory, pin.compatibility?.[from]);
      }, directory => {
        if (name === 'zod') prepareZod(directory, pin.compatibility?.[from], pin.version);
      });
    }
    for (const target of directories) {
      const compatibility = pin.compatibility?.[target.entry.match(/^[^@]+@([^_]+)/)?.[1]];
      verifyRuntimePackage(name, target.directory, compatibility);
      const pkg = JSON.parse(fs.readFileSync(path.join(target.directory, 'package.json')));
      evidence.push({name, version: pkg.version, source: pin.url, sha512: pin.sha512,
        path: path.relative(root, target.directory), changes: pkg['release-factory'] ?? null});
    }
  }
  return evidence;
}

async function replaceVerifiedDependency(name, pin, outdated, verify = () => {}, prepare = () => {}) {
  assertDependencyPin(name, pin);
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
    prepare(replacement);
    verify(replacement);
    for (const directory of outdated) {
      const from = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version;
      const {uid, gid} = fs.statSync(directory);
      fs.rmSync(directory, {recursive: true});
      fs.cpSync(replacement, directory, {recursive: true});
      execFileSync('chown', ['-R', `${uid}:${gid}`, directory]);
      verify(directory);
      console.log(`Replace verified dependency ${name} ${from} -> ${pin.version}: ${directory}`);
    }
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
}

export async function patchMcpPackages(root, pins) {
  const store = path.join(fs.realpathSync(root), '.pnpm');
  const packages = new Map();
  // Upgrade core first: the client must resolve the matching issuer-preserving schemas.
  for (const kind of ['core', 'client', 'sdk']) {
    const name = `@modelcontextprotocol/${kind}`;
    const pin = pins[name];
    const outdated = [];
    const originals = [];
    const directories = [];
    for (const entry of fs.readdirSync(store)) {
      if (!entry.startsWith(`@modelcontextprotocol+${kind}@`)) continue;
      const directory = path.join(store, entry, 'node_modules', name);
      assert.equal(fs.realpathSync(directory), directory, 'unexpected MCP dependency path');
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.name, name);
      directories.push(directory);
      if (pinFromVersions(pin).includes(pkg.version)) { outdated.push(directory); originals.push(pkg); }
    }
    await replaceVerifiedDependency(name, pin, outdated, directory => {
      const replacement = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      for (const original of originals) {
        const dependencies = {...original.dependencies};
        if (kind === 'client') dependencies['@modelcontextprotocol/core'] = pins['@modelcontextprotocol/core'].version;
        assert.deepEqual(replacement.dependencies, dependencies, 'MCP dependency graph changed beyond the reviewed core upgrade');
        assert.deepEqual(replacement.peerDependencies, original.peerDependencies);
        assert.deepEqual(replacement.engines, original.engines);
      }
    });
    packages.set(kind, directories);
  }
  for (const kind of ['client', 'sdk']) {
    for (const directory of packages.get(kind)) {
      if (kind === 'client') {
        const require = createRequire(path.join(directory, 'package.json'));
        const coreFile = path.join(path.dirname(require.resolve('@modelcontextprotocol/core')), '../package.json');
        const core = JSON.parse(fs.readFileSync(coreFile));
        const client = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
        assert.equal(core.version, client.dependencies['@modelcontextprotocol/core'], 'MCP client resolved the wrong core version');
      }
      for (const mode of ['cjs', 'esm']) {
        execFileSync(process.execPath, [fileURLToPath(new URL('./verify-mcp-auth.mjs', import.meta.url)), directory, kind, mode],
          {stdio: 'inherit', timeout: 30000});
      }
    }
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

// https://github.com/markdown-it/markdown-it/security/advisories/GHSA-gfr2-rv44-r23c
export function verifyMarkdown(directory) {
  // Bound the actual hostile render in a child: a vulnerable copy must not hang the build.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import fs from 'node:fs';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    import {pathToFileURL} from 'node:url';
    const directory = process.argv[1];
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
    const require = createRequire(path.join(directory, 'package.json'));
    for (const MarkdownIt of [require(directory),
      (await import(pathToFileURL(path.join(directory, pkg.module)))).default]) {
      const md = new MarkdownIt();
      assert.equal(md.render('**safe**'), '<p><strong>safe</strong></p>\\n');
      assert.equal(md.render('[a]: /url "title"\\n\\n[a]'),
        '<p><a href="/url" title="title">a</a></p>\\n');
      assert.equal(md.render('[a]: /url "open\\nclose"\\n\\n[a]'),
        '<p><a href="/url" title="open\\nclose">a</a></p>\\n');
      for (const input of ['[a]: /u "' + 'x\\n'.repeat(300000),
        '[a]: /u "' + 'x\\n'.repeat(300000) + '"', '[' + 'a\\n'.repeat(300000)]) {
        assert.equal(typeof md.render(input), 'string');
      }
    }
  `, directory], {timeout: 5000, stdio: 'pipe'});
  const version = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version;
  assert.equal(execFileSync(process.execPath, [path.join(directory, 'bin/markdown-it.mjs'), '--version'],
    {timeout: 5000, encoding: 'utf8'}).trim(), version);
  console.log(`Verified CVE-2026-111758 Markdown rendering and CLI (${version}): ${directory}`);
}

export async function patchMarkdownPackages(root, pins) {
  const store = path.join(fs.realpathSync(root), '.pnpm');
  const markdown = [];
  // The fixed Markdown CLI requires argparse >=3.0.3, with no new dependencies.
  for (const name of ['argparse', 'markdown-it']) {
    const pin = pins[name];
    const outdated = [];
    for (const entry of fs.readdirSync(store)) {
      if (!entry.startsWith(`${name}@`)) continue;
      if (name === 'argparse' && !entry.startsWith('argparse@3.')) continue;
      const directory = path.join(store, entry, 'node_modules', name);
      assert.equal(fs.realpathSync(directory), directory, 'unexpected Markdown dependency path');
      const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
      assert.equal(pkg.name, name);
      if (pinFromVersions(pin).includes(pkg.version)) outdated.push(directory);
      else assert.equal(pkg.version, pin.version, `unreviewed ${name} version`);
      if (name === 'markdown-it') markdown.push(directory);
    }
    await replaceVerifiedDependency(name, pin, outdated);
  }
  for (const directory of markdown) {
    const require = createRequire(path.join(directory, 'package.json'));
    const argparse = JSON.parse(fs.readFileSync(require.resolve('argparse/package.json')));
    assert.equal(argparse.version, pins.argparse.version, 'Markdown CLI resolved the wrong argparse version');
    verifyMarkdown(directory);
  }
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

export function patchMcpHttpFetch(root) {
  // Reviewed v2026.11.3 and v2026.11.6 wrap the SDK's manual fetch with a redirect loop.
  // Reuse its OAuth policy so a tool's POST body stays on the resource origin.
  const file = path.join(fs.realpathSync(root), 'src/agents/mcp-http-fetch.ts');
  assert.equal(fs.realpathSync(file), file, 'unexpected MCP HTTP fetch source path');
  const source = fs.readFileSync(file, 'utf8');
  const original = '  return buildMcpHttpFetchWithRedirectPolicy(params, "replay");';
  const replacement = '  return buildMcpHttpFetchWithRedirectPolicy(params, "reject");';
  const reviewedHashes = new Map([
    ['f144f2e0707d4a81077c759b5cfc3dd9fa432fc6c5317c3599ee9462d8866f26',
      'e88a9f6501cf5897289a8141e32b4a0ea096e35bf70dd6ed73a73820e0ebf7bd'],
    ['12bb94f5831176e608650ab8ccb56ee024216065eadefa4a6df43b8f4d4c56b9',
      '859f813f697bf09ae785bced98445237df41581ebb86ed443fadcc179e5a9db6'],
  ]);
  const sha256 = value => createHash('sha256').update(value).digest('hex');
  const sourceHash = sha256(source);
  if ([...reviewedHashes.values()].includes(sourceHash)) {
    assert.equal(source.split(replacement).length, 2, 'missing MCP HTTP fetch patch anchor');
    return;
  }
  const patchedHash = reviewedHashes.get(sourceHash);
  assert.ok(patchedHash, 'unreviewed MCP HTTP fetch source');
  assert.equal(source.split(original).length, 2, 'missing MCP HTTP fetch patch anchor');
  const patched = source.replace(original, replacement);
  assert.equal(sha256(patched), patchedHash, 'unexpected MCP HTTP fetch patch result');
  fs.writeFileSync(file, patched);
  console.log(`Patched MCP cross-origin tool body replay: ${file}`);
}

async function main() {
  const components = JSON.parse(fs.readFileSync(new URL('./components.json', import.meta.url)));
  if (process.argv[2] === '--build') {
    assert.equal(process.argv.length, 3, 'unexpected dependency patch argument');
    patchMcpHttpFetch('/app');
    // Vite/Rolldown inline these packages into the browser assets before runtime COPY.
    await patchRuntimePackages('/app/node_modules', components.runtime_packages);
    await patchMarkdownPackages('/app/node_modules', components.markdown_packages);
    return;
  }
  assert.equal(process.argv.length, 2, 'unexpected dependency patch argument');
  await patchNpmBundles('/app/node_modules', components.npm_bundled);
  await patchNpmBundles('/usr/local/lib/node_modules', components.npm_bundled);
  const runtimePatches = await patchRuntimePackages('/app/node_modules', components.runtime_packages);
  fs.mkdirSync('/usr/share/doc/release-factory', {recursive: true});
  fs.writeFileSync('/usr/share/doc/release-factory/openclaw-runtime-deps.json', JSON.stringify(runtimePatches, null, 2) + '\n');
  await patchSourceMaps('/app/node_modules', components.source_map_js);
  await patchMcpPackages('/app/node_modules', components.mcp_packages);
  await patchMarkdownPackages('/app/node_modules', components.markdown_packages);
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
    if (['0.5.17', '0.6.0'].includes(pkg.version)) outdated.push(directory);
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
      const from = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version;
      console.log(`Replace verified vendored adm-zip ${from} -> ${pin.version}: ${directory}`);
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
