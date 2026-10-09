import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import {pruneNativeTypeScript} from '../openclaw-builder/image/prune-native-typescript.mjs';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-native-typescript-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const write = (name, data) => {
    fs.mkdirSync(path.dirname(path.join(root, name)), {recursive: true});
    fs.writeFileSync(path.join(root, name), data);
  };
  const pkg = (name, version) => {
    const entry = `node_modules/.pnpm/${name.replace('/', '+')}@${version}`;
    const directory = `${entry}/node_modules/${name}`;
    write(`${directory}/package.json`, JSON.stringify({name, version}));
    write(`${directory}/lib/tsc`, 'compiler');
    return {entry, directory};
  };
  const link = (name, target) => {
    fs.mkdirSync(path.dirname(path.join(root, name)), {recursive: true});
    fs.symlinkSync(path.relative(path.dirname(path.join(root, name)), path.join(root, target)), path.join(root, name));
  };
  write('package.json', JSON.stringify({devDependencies: {typescript: '7.1.0-dev.20260920.1'}}));
  const native = pkg('typescript', '7.1.0-dev.20260920.1');
  const x64 = pkg('@typescript/typescript-linux-x64', '7.1.0-dev.20260920.1');
  const arm64 = pkg('@typescript/typescript-linux-arm64', '7.1.0-dev.20260920.1');
  const legacy = pkg('typescript', '5.9.3');
  const peer = pkg('cosmiconfig', '9.0.2');
  const unrelated = pkg('@typescript-eslint/parser', '7.0.0');
  link('node_modules/typescript', native.directory);
  link('node_modules/.pnpm/node_modules/typescript', native.directory);
  link('node_modules/@typescript/typescript-linux-x64', x64.directory);
  link('node_modules/.pnpm/node_modules/@typescript/typescript-linux-arm64', arm64.directory);
  link(`${peer.entry}/node_modules/typescript`, native.directory);
  link(`${unrelated.entry}/node_modules/typescript`, legacy.directory);
  write('node_modules/.bin/tsc', 'native compiler launcher');
  write(`${unrelated.entry}/node_modules/.bin/tsc`, 'legacy compiler launcher');
  return {root, write, native, x64, arm64, legacy, peer, unrelated};
}

test('prunes native compiler payloads, peers and launcher while retaining TypeScript 5 and unrelated packages', t => {
  const f = fixture(t);
  assert.equal(pruneNativeTypeScript(f.root), 3);
  for (const name of [f.native.entry, f.x64.entry, f.arm64.entry, 'node_modules/typescript',
    'node_modules/@typescript/typescript-linux-x64', 'node_modules/.pnpm/node_modules/@typescript/typescript-linux-arm64',
    'node_modules/.pnpm/node_modules/typescript', `${f.peer.entry}/node_modules/typescript`, 'node_modules/.bin/tsc']) {
    assert.equal(fs.existsSync(path.join(f.root, name)), false, name);
    assert.throws(() => fs.lstatSync(path.join(f.root, name)), {code: 'ENOENT'});
  }
  for (const name of [f.legacy.directory, f.peer.directory, f.unrelated.directory,
    `${f.unrelated.entry}/node_modules/typescript`, `${f.unrelated.entry}/node_modules/.bin/tsc`]) {
    assert.ok(fs.existsSync(path.join(f.root, name)), name);
  }
  assert.equal(pruneNativeTypeScript(f.root), 0, 'cleanup must be idempotent');
});

test('refuses direct runtime TypeScript dependencies before removing anything', t => {
  const f = fixture(t);
  for (const section of ['dependencies', 'optionalDependencies']) {
    f.write('package.json', JSON.stringify({[section]: {typescript: '7.1.0-dev.20260920.1'}}));
    assert.throws(() => pruneNativeTypeScript(f.root), /direct runtime dependency/);
    assert.ok(fs.existsSync(path.join(f.root, f.x64.directory, 'lib/tsc')));
  }
});

test('rejects a compiler directory symlink before changing packages', t => {
  const f = fixture(t);
  const entry = path.join(f.root, f.x64.entry);
  fs.renameSync(entry, path.join(f.root, 'outside-store'));
  fs.symlinkSync(path.join(f.root, 'outside-store'), entry);
  assert.throws(() => pruneNativeTypeScript(f.root), /store entry must not be a symlink/);
  assert.ok(fs.existsSync(path.join(f.root, f.native.directory, 'lib/tsc')));
  assert.ok(fs.existsSync(path.join(f.root, f.x64.directory, 'lib/tsc')));
});

test('rejects a pnpm store symlink', t => {
  const f = fixture(t);
  const store = path.join(f.root, 'node_modules/.pnpm');
  fs.renameSync(store, path.join(f.root, 'outside-store'));
  fs.symlinkSync(path.join(f.root, 'outside-store'), store);
  assert.throws(() => pruneNativeTypeScript(f.root), /pnpm store must not be a symlink/);
});
