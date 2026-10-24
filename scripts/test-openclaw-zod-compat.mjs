import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchRuntimePackages, verifyZod } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pin = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).runtime_packages.zod;

const consumerProbe = `
  import assert from 'node:assert/strict';
  import {createRequire} from 'node:module';
  import path from 'node:path';
  const require = createRequire(path.join(process.cwd(), 'package.json'));
  const load = process.argv[1] === 'cjs' ? name => require(name) : name => import(name);
  async function check(z, compatibility) {
    const object = z.object({name: z.string(), count: z.number().optional()});
    assert.deepEqual(object.parse({name: 'openclaw'}), {name: 'openclaw'});
    assert.equal(object.safeParse({name: 42}).success, false);
    assert.equal(object._def.typeName, compatibility === 'v3' ? 'ZodObject' : undefined);
    assert.deepEqual(z.record(z.string(), z.string()).parse({safe: 'value'}), {safe: 'value'});
    assert.equal(z.union([z.string(), z.number()]).parse(42), 42);
    assert.deepEqual(z.object({name: z.string().default('default')}).parse({}), {name: 'default'});
    assert.equal(z.array(z.string()).safeParse([1, 2, 3]).error.issues.length, 3);
    let parsed = 0;
    let refined = 0;
    const element = z.string().refine(() => { parsed++; return true; });
    for (const schema of [z.array(element).max(2), z.array(element).length(2)]) {
      const result = schema.refine(() => { refined++; return true; }).safeParse(new Array(10000).fill('x'));
      assert.equal(result.success, false);
      assert.equal(result.error.issues.length, 1);
      assert.equal(result.error.issues[0].code, 'too_big');
      assert.deepEqual(result.error.issues[0].path, []);
    }
    const nested = z.object({items: z.array(element).max(1)}).safeParse({items: ['x', 'y']});
    assert.deepEqual(nested.error.issues[0].path, ['items']);
    assert.deepEqual([parsed, refined], [0, 0]);
    assert.deepEqual(z.array(z.string()).min(1).parse(['x', 'y', 'z']), ['x', 'y', 'z']);
    assert.deepEqual(z.array(z.string().transform(value => value.toUpperCase())).max(2).parse(['x']), ['X']);
    let asyncParsed = 0;
    const asyncSchema = z.array(z.string().refine(async () => { asyncParsed++; return true; })).max(1);
    const asyncResult = await asyncSchema.safeParseAsync(['x', 'y']);
    assert.equal(asyncResult.error.issues.length, 1);
    assert.equal(asyncParsed, 0);
    assert.deepEqual(await asyncSchema.parseAsync(['x']), ['x']);
    assert.equal(asyncParsed, 1);
    const set = z.set(z.string()).max(1).safeParse(new Set([1, 2]));
    assert.equal(set.success, false);
    assert.equal(set.error.issues.length, 1);
    assert.equal(set.error.issues[0].code, 'too_big');
    assert.deepEqual([...z.set(z.string()).max(2).parse(new Set(['x']))], ['x']);
    if (compatibility === 'v4') {
      const map = z.map(z.string(), z.string()).max(1).safeParse(new Map([[1, 1], [2, 2]]));
      assert.equal(map.error.issues.length, 1);
      assert.equal(map.error.issues[0].code, 'too_big');
    }
    return object;
  }
  const v3 = await load('zod');
  const v4 = await load('zod4');
  const object = await check(v3, 'v3');
  await check(v4, 'v4');
  for (const name of ['zod', 'zod4']) {
    await check(await load(name + '/v3'), 'v3');
    await check(await load(name + '/v4'), 'v4');
  }
  const {zodToJsonSchema} = await load('zod-to-json-schema');
  const json = zodToJsonSchema(object);
  assert.equal(json.type, 'object');
  assert.deepEqual(json.properties, {name: {type: 'string'}, count: {type: 'number'}});
  assert.deepEqual(json.required, ['name']);
  const {getKnownSchemaKeys, scrapeSchemaBehavior} = await import('@a2ui/web_core');
  assert.deepEqual([...getKnownSchemaKeys(object)].sort(), ['count', 'name']);
  assert.deepEqual(scrapeSchemaBehavior(object), {
    type: 'OBJECT', shape: {name: {type: 'STATIC'}, count: {type: 'STATIC'}},
  });
  const wrapped = object.refine(() => true).optional();
  assert.deepEqual([...getKnownSchemaKeys(wrapped)].sort(), ['count', 'name']);
`;

test('repairs real Zod packages while retaining v3 and v4 pnpm consumers', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-zod-test-'));
  try {
    const dependencies = {zod: '3.25.76', zod4: 'npm:zod@4.6.5',
      '@a2ui/web_core': '0.12.0', 'zod-to-json-schema': '3.25.2'};
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    const links = [];
    for (const [name, version] of [['zod', '3.25.76'], ['zod4', '4.6.5']]) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', `zod@${version}`, 'node_modules/zod');
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      directories[version] = directory;
      links.push([original, fs.readlinkSync(original)]);
    }
    for (const name of ['@a2ui/web_core', 'zod-to-json-schema']) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', `${name.replace('/', '+')}@fixture`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(path.dirname(original), directory), original);
      const link = path.join(root, '.pnpm', `${name.replace('/', '+')}@fixture`, 'node_modules/zod');
      fs.symlinkSync(path.relative(path.dirname(link), directories['3.25.76']), link);
      links.push([original, fs.readlinkSync(original)], [link, fs.readlinkSync(link)]);
    }
    for (const [version, directory] of Object.entries(directories)) {
      assert.throws(() => verifyZod(directory, version.startsWith('3.') ? 'v3' : 'v4'),
        /bounded zod container parsed every oversized element/);
    }
    await assert.rejects(patchRuntimePackages(root, {zod: {...pin, sha512: '0'.repeat(128)}}),
      {code: 'ERR_ASSERTION'});
    for (const [version, directory] of Object.entries(directories)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, version);
    }
    const packageFile = path.join(directories['3.25.76'], 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    fs.writeFileSync(packageFile, JSON.stringify({...JSON.parse(originalPackage), version: '3.25.75'}));
    await assert.rejects(patchRuntimePackages(root, {zod: pin}), /unreviewed zod version/);
    fs.writeFileSync(packageFile, originalPackage);
    await patchRuntimePackages(root, {zod: pin});
    for (const [link, target] of links) {
      assert.equal(fs.lstatSync(link).isSymbolicLink(), true);
      assert.equal(fs.readlinkSync(link), target);
    }
    for (const directory of Object.values(directories)) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, pin.version);
    }
    const compatible = JSON.parse(fs.readFileSync(packageFile));
    assert.equal(compatible.main, './v3/index.cjs');
    assert.equal(compatible.module, './v3/index.js');
    assert.equal(compatible.types, './v3/index.d.cts');
    assert.equal(compatible.exports['.'].require, './v3/index.cjs');
    assert.equal(compatible.exports['.'].import, './v3/index.js');
    for (const mode of ['cjs', 'esm']) {
      execFileSync(process.execPath, ['--input-type=module', '-e', consumerProbe, mode],
        {cwd: temporary, timeout: 30000, stdio: 'pipe'});
    }
    await patchRuntimePackages(root, {zod: pin});
    const outside = path.join(temporary, 'outside-zod');
    fs.renameSync(directories['3.25.76'], outside);
    fs.symlinkSync(outside, directories['3.25.76']);
    await assert.rejects(patchRuntimePackages(root, {zod: pin}), /unexpected zod dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
