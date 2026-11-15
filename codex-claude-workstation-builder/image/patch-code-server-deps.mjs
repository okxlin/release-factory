import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const targets = [
  {relative: 'node_modules/body-parser', name: 'body-parser', from: '2.3.0', version: '2.4.0'},
  {relative: 'node_modules/follow-redirects', name: 'follow-redirects', from: ['1.16.0', '1.16.2'], version: '1.16.3'},
  {relative: 'lib/vscode/node_modules/zod', name: 'zod', from: '4.4.3', version: '4.6.7', api: 'v4'},
  {relative: 'lib/vscode/node_modules/@github/copilot-sdk/node_modules/zod', name: 'zod', from: '4.3.6', version: '4.6.7', api: 'v4'},
  {relative: 'lib/vscode/node_modules/@vscode/sandbox-runtime/node_modules/zod', name: 'zod', from: '3.25.76', version: '4.6.7', api: 'v3'},
];

function packageAt(directory, name) {
  assert.equal(fs.realpathSync(directory), directory, 'unexpected dependency path');
  const file = path.join(directory, 'package.json');
  assert.equal(fs.realpathSync(file), file, 'unexpected package manifest path');
  const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(pkg.name, name);
  return pkg;
}

function editorConfigAt(extensions, requested) {
  const required = requested.split(/\s+/).some(id => id.split('@')[0].toLowerCase() === 'editorconfig.editorconfig');
  const directories = fs.readdirSync(extensions).filter(name => name.toLowerCase().startsWith('editorconfig.editorconfig-'));
  assert.ok(directories.length <= 1, 'unreviewed multiple EditorConfig extension versions');
  if (!directories.length) {
    assert.ok(!required, 'requested EditorConfig extension is missing');
    return;
  }
  assert.equal(directories[0], 'editorconfig.editorconfig-0.18.2-universal', 'unreviewed EditorConfig extension layout');
  const directory = path.join(extensions, directories[0]);
  assert.equal(packageAt(directory, 'EditorConfig').version, '0.18.2', 'unreviewed EditorConfig extension version');
  const consumer = packageAt(path.join(directory, 'node_modules/editorconfig'), 'editorconfig');
  assert.equal(consumer.version, '3.0.2', 'unreviewed editorconfig consumer version');
  assert.equal(consumer.dependencies.minimatch, '~10.2.4');
  const minimatch = packageAt(path.join(directory, 'node_modules/editorconfig/node_modules/minimatch'), 'minimatch');
  assert.equal(minimatch.version, '10.2.5', 'unreviewed EditorConfig minimatch version');
  assert.equal(minimatch.dependencies['brace-expansion'], '^5.0.5');
  return directory;
}

export function verifyEditorConfigDeps(directory) {
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import fs from 'node:fs';
    import os from 'node:os';
    import path from 'node:path';
    import {pathToFileURL} from 'node:url';
    const directory = process.argv[1];
    const require = createRequire(path.join(directory, 'package.json'));
    const consumerDirectory = path.join(directory, 'node_modules/editorconfig');
    assert.ok(require.resolve('editorconfig').startsWith(consumerDirectory + path.sep));
    const consumerRequire = createRequire(path.join(consumerDirectory, 'package.json'));
    const minimatchDirectory = path.join(consumerDirectory, 'node_modules/minimatch');
    assert.ok(consumerRequire.resolve('minimatch').startsWith(minimatchDirectory + path.sep));
    const minimatchRequire = createRequire(path.join(minimatchDirectory, 'package.json'));
    const braceDirectory = path.join(consumerDirectory, 'node_modules/brace-expansion');
    assert.ok(minimatchRequire.resolve('brace-expansion').startsWith(braceDirectory + path.sep));
    assert.equal(JSON.parse(fs.readFileSync(path.join(braceDirectory, 'package.json'))).version, '5.0.13');
    const braceRequire = createRequire(path.join(braceDirectory, 'package.json'));
    const balancedDirectory = path.join(braceDirectory, 'node_modules/balanced-match');
    assert.ok(braceRequire.resolve('balanced-match').startsWith(balancedDirectory + path.sep));
    assert.equal(JSON.parse(fs.readFileSync(path.join(balancedDirectory, 'package.json'))).version, '4.0.4');
    const bracePackage = JSON.parse(fs.readFileSync(path.join(braceDirectory, 'package.json')));
    for (const brace of [minimatchRequire('brace-expansion'), await import(pathToFileURL(path.join(braceDirectory, bracePackage.module)))]) {
      assert.deepEqual(brace.expand('file{1..3}.{js,ts}'), ['file1.js', 'file1.ts', 'file2.js', 'file2.ts', 'file3.js', 'file3.ts']);
      assert.deepEqual(brace.expand('{1..100}', {max: 4}), ['1', '2', '3', '4']);
      assert.deepEqual(brace.expand('{a,b}', {maxSteps: 0}), ['{a,b}']);
    }
    const {Minimatch} = consumerRequire('minimatch');
    const glob = new Minimatch('{src,test}/**/*.{js,ts}');
    assert.equal(glob.match('src/main.ts'), true);
    assert.equal(glob.match('test/nested/a.js'), true);
    assert.equal(glob.match('doc/readme.md'), false);
    const editorconfig = require('editorconfig');
    const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'editorconfig-parse-'));
    try {
      fs.mkdirSync(path.join(fixture, 'src/nested'), {recursive: true});
      fs.writeFileSync(path.join(fixture, '.editorconfig'), 'root = true\\n[*.{js,ts}]\\nindent_style = space\\nindent_size = 2\\n[src/file{1..3}.ts]\\nindent_size = 4\\n');
      fs.writeFileSync(path.join(fixture, 'src/nested/.editorconfig'), '[*.ts]\\nindent_size = 8\\n');
      for (const [name, size] of [['src/main.ts', 2], ['src/file2.ts', 4], ['src/file4.ts', 2], ['src/nested/main.ts', 8], ['doc/readme.md', undefined]]) {
        const file = path.join(fixture, name);
        fs.mkdirSync(path.dirname(file), {recursive: true});
        fs.writeFileSync(file, '');
        const expected = size === undefined ? {} : {indent_style: 'space', indent_size: size, tab_width: size};
        assert.deepEqual(editorconfig.parseSync(file), expected);
        assert.deepEqual(await editorconfig.parse(file), expected);
      }
    } finally {fs.rmSync(fixture, {recursive: true});}
  `, directory], {timeout: 15000, stdio: 'pipe'});
  console.log('Verified real EditorConfig parser, nested minimatch/brace-expansion CJS/ESM and bounded expansion');
}

function prepareZod(directory, api) {
  // Match the reviewed OpenClaw backport, packaged locally for this build context.
  // https://github.com/colinhacks/zod/pull/6652
  const pkg = packageAt(directory, 'zod');
  assert.equal(pkg.version, '4.6.7');
  if (api === 'v3') {
    pkg.exports['.'] = structuredClone(pkg.exports['./v3']);
    pkg.main = './v3/index.cjs';
    pkg.module = './v3/index.js';
    pkg.types = './v3/index.d.cts';
  }
  pkg['release-factory'] = {source: 'zod@4.6.7', root: api, patches: ['v3-bounded-container-gate']};
  fs.writeFileSync(path.join(directory, 'package.json'), `${JSON.stringify(pkg, null, 2)}\n`);
  for (const [relative, invalid] of [
    ['v3/types.js', 'INVALID'],
    ['v3/types.cjs', 'parseUtil_js_1.INVALID'],
    ['src/v3/types.ts', 'INVALID'],
  ]) {
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
}

export function verifyZod(directory, api) {
  // New processes verify both entry modes without retaining pre-replacement caches.
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import path from 'node:path';
    import {pathToFileURL} from 'node:url';
    const [directory, api] = process.argv.slice(1);
    const require = createRequire(path.join(directory, 'package.json'));
    const pkg = require('./package.json');
    async function check(z, api) {
      const object = z.object({name: z.string()});
      assert.deepEqual(object.parse({name: 'code-server'}), {name: 'code-server'});
      assert.equal(object.safeParse({name: 42}).success, false);
      assert.equal(object._def.typeName, api === 'v3' ? 'ZodObject' : undefined);
      assert.deepEqual(z.record(z.string(), z.string()).parse({safe: 'value'}), {safe: 'value'});
      let visited = 0;
      const element = z.string().refine(() => {visited++; return true;});
      for (const schema of [z.array(element).max(2), z.array(element).length(2)]) {
        const result = schema.safeParse(new Array(10000).fill('x'));
        assert.equal(result.success, false);
        assert.equal(visited, 0, 'bounded zod container parsed oversized elements');
        assert.equal(result.error.issues.length, 1);
        assert.equal(result.error.issues[0].code, 'too_big');
      }
      assert.deepEqual(z.array(element).max(2).parse(['x']), ['x']);
      assert.equal(visited, 1);
      assert.equal(z.array(z.string()).safeParse([1, 2, 3]).error.issues.length, 3);
      const nested = z.object({items: z.array(z.string()).max(1)}).safeParse({items: [1, 2]});
      assert.equal(nested.error.issues.length, 1);
      assert.deepEqual(nested.error.issues[0].path, ['items']);
      const set = z.set(z.string()).max(1).safeParse(new Set([1, 2]));
      assert.equal(set.error.issues.length, 1);
      assert.equal(set.error.issues[0].code, 'too_big');
      let asyncVisited = 0;
      const asyncSchema = z.array(z.string().refine(async () => {asyncVisited++; return true;})).max(1);
      assert.equal((await asyncSchema.safeParseAsync(['x', 'y'])).error.issues.length, 1);
      assert.equal(asyncVisited, 0);
      assert.deepEqual(await asyncSchema.parseAsync(['x']), ['x']);
      assert.equal(asyncVisited, 1);
    }
    await check(require(directory), api);
    await check(await import(pathToFileURL(path.join(directory, pkg.module))), api);
    for (const mode of ['v3', 'v4']) {
      await check(require(path.join(directory, mode, 'index.cjs')), mode);
      await check(await import(pathToFileURL(path.join(directory, mode, 'index.js'))), mode);
    }
  `, directory, api], {timeout: 15000, stdio: 'pipe'});
}

export function verifyCodeServerDeps(root, editorConfig) {
  for (const target of targets) {
    const directory = path.join(root, target.relative);
    assert.equal(packageAt(directory, target.name).version, target.version);
    if (target.api) verifyZod(directory, target.api);
  }
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {createRequire} from 'node:module';
    import {once} from 'node:events';
    import fs from 'node:fs';
    import path from 'node:path';
    import {pathToFileURL} from 'node:url';
    const root = process.argv[1];
    const require = createRequire(path.join(root, 'package.json'));
    const expressRequire = createRequire(require.resolve('express'));
    assert.equal(expressRequire('body-parser/package.json').version, '2.4.0');
    const parserRequire = createRequire(require.resolve('body-parser'));
    const parserDirectory = path.dirname(require.resolve('body-parser'));
    for (const [name, version] of [['qs', '6.16.1'], ['content-type', '2.1.0'], ['iconv-lite', '0.7.3']]) {
      const directory = path.join(parserDirectory, 'node_modules', name);
      assert.ok(parserRequire.resolve(name).startsWith(directory + path.sep));
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, version);
    }
    const express = require('express');
    const app = express();
    app.use(express.json({limit: 1024}));
    app.use(express.urlencoded({extended: true, limit: 1024}));
    app.post('/', (req, res) => res.json(req.body));
    app.get('/redirect', (_req, res) => res.redirect('/target'));
    app.get('/target', (_req, res) => res.send('redirect works'));
    app.get('/loop', (_req, res) => res.redirect('/loop'));
    app.use((err, _req, res, _next) => res.status(err.status || 500).end());
    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const base = 'http://127.0.0.1:' + server.address().port;
    try {
      for (const [type, body, status, expected] of [
        ['application/json', '{"safe":"value"}', 200, {safe: 'value'}],
        ['application/x-www-form-urlencoded', 'safe=value&nested[key]=value', 200, {safe: 'value', nested: {key: 'value'}}],
        ['application/json', '{', 400],
        ['application/json', JSON.stringify({text: 'x'.repeat(2048)}), 413],
      ]) {
        const response = await fetch(base, {method: 'POST', headers: {'Content-Type': type}, body});
        assert.equal(response.status, status);
        if (expected) assert.deepEqual(await response.json(), expected);
        else await response.text();
      }
      const {http} = require('follow-redirects');
      const redirected = await new Promise((resolve, reject) => {
        http.get(base + '/redirect', response => {
          let text = ''; response.on('data', chunk => text += chunk);
          response.on('end', () => resolve(text)); response.on('error', reject);
        }).on('error', reject);
      });
      assert.equal(redirected, 'redirect works');
      await assert.rejects(new Promise((resolve, reject) => {
        http.get(base + '/loop', {maxRedirects: 2}, resolve).on('error', reject);
      }), {code: 'ERR_FR_TOO_MANY_REDIRECTS'});
    } finally {server.closeAllConnections(); await new Promise(resolve => server.close(resolve));}
    const sandbox = await import(pathToFileURL(path.join(root, 'lib/vscode/node_modules/@vscode/sandbox-runtime/dist/index.js')));
    const config = {network: {allowedDomains: ['github.com'], deniedDomains: []},
      filesystem: {denyRead: [], allowWrite: ['/workspace'], denyWrite: []}};
    assert.deepEqual(sandbox.SandboxRuntimeConfigSchema.parse(config), config);
    assert.equal(sandbox.SandboxRuntimeConfigSchema._def.typeName, 'ZodObject');
    assert.equal(sandbox.SandboxRuntimeConfigSchema.safeParse({...config,
      network: {...config.network, allowedDomains: ['*.com']}}).success, false);
    assert.equal(sandbox.SandboxRuntimeConfigSchema.safeParse({...config,
      filesystem: {...config.filesystem, allowWrite: ['']}}).success, false);
    assert.deepEqual(sandbox.IgnoreViolationsConfigSchema.parse({'git status': ['/workspace']}), {'git status': ['/workspace']});
  `, root], {timeout: 15000, stdio: 'pipe'});
  if (editorConfig) verifyEditorConfigDeps(editorConfig);
  console.log('Verified code-server Express, redirects, Zod CJS/ESM and Sandbox Runtime schemas');
}

export function patchCodeServerDeps(root, staging, extensions, requested) {
  root = fs.realpathSync(root);
  staging = fs.realpathSync(staging);
  assert.ok(root !== staging && !root.startsWith(staging + path.sep) && !staging.startsWith(root + path.sep),
    'security staging root must be separate from code-server');
  packageAt(root, 'code-server');
  let editorConfig;
  if (extensions !== undefined) {
    assert.equal(typeof requested, 'string', 'extension request list is required');
    extensions = fs.realpathSync(extensions);
    assert.ok(extensions !== staging && !extensions.startsWith(staging + path.sep) && !staging.startsWith(extensions + path.sep),
      'security staging root must be separate from extensions');
    editorConfig = editorConfigAt(extensions, requested);
  }
  const selected = [...targets];
  if (editorConfig) selected.push({
    relative: 'extensions/editorconfig.editorconfig-0.18.2-universal/node_modules/editorconfig/node_modules/brace-expansion',
    directory: path.join(editorConfig, 'node_modules/editorconfig/node_modules/brace-expansion'),
    name: 'brace-expansion', from: '5.0.5', version: '5.0.13',
  });
  // Validate all targets and sources before constructing or replacing any tree.
  const plans = selected.map(target => {
    const directory = target.directory || path.join(root, target.relative);
    const pkg = packageAt(directory, target.name);
    assert.ok([target.from, target.version].flat().includes(pkg.version), `unreviewed ${target.name} version: ${pkg.version}`);
    const source = path.join(staging, 'node_modules', target.name);
    assert.equal(packageAt(source, target.name).version, target.version);
    return {...target, directory, source};
  });
  const temporary = fs.mkdtempSync(path.join(root, '.release-factory-security-'));
  const replaced = [];
  try {
    for (const [index, plan] of plans.entries()) {
      plan.candidate = path.join(temporary, `candidate-${index}`);
      plan.backup = path.join(temporary, `original-${index}`);
      fs.cpSync(plan.source, plan.candidate, {recursive: true, dereference: false});
      if (plan.api) {prepareZod(plan.candidate, plan.api); verifyZod(plan.candidate, plan.api);}
      // overlayfs rejects renaming directories from a previous image layer.
      // Copy every backup before replacing any target; backups live in this layer.
      fs.cpSync(plan.directory, plan.backup, {recursive: true, dereference: false});
    }
    for (const plan of plans) {
      console.log(`Replacing ${plan.relative} with ${plan.name}@${plan.version}${plan.api ? ' (' + plan.api + ')' : ''}`);
      replaced.push(plan);
      fs.rmSync(plan.directory, {recursive: true});
      fs.renameSync(plan.candidate, plan.directory);
    }
    verifyCodeServerDeps(root, editorConfig);
  } catch (error) {
    for (const plan of replaced.reverse()) {
      if (fs.existsSync(plan.directory)) fs.rmSync(plan.directory, {recursive: true});
      fs.renameSync(plan.backup, plan.directory);
    }
    throw error;
  } finally {fs.rmSync(temporary, {recursive: true, force: true});}
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 6, 'usage: patch-code-server-deps.mjs CODE_SERVER_ROOT STAGING_ROOT EXTENSIONS_ROOT REQUESTED_EXTENSIONS');
  patchCodeServerDeps(...process.argv.slice(2));
}
