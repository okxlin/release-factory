import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchNpmBundles } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).npm_bundled;

test('repairs only the two vulnerable dependencies inside bundled npm', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-npm-test-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const npm = path.join(root, '.pnpm/npm@11.20.0/node_modules/npm');
    fs.mkdirSync(npm, {recursive: true});
    fs.writeFileSync(path.join(npm, 'package.json'), '{"name":"npm","version":"11.20.0"}\n');
    for (const [name, pin] of Object.entries(pins)) {
      const directory = path.join(npm, 'node_modules', name);
      fs.mkdirSync(directory, {recursive: true});
      fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify({name, version: pin.from}));
    }
    const unrelated = path.join(root, 'unrelated');
    fs.mkdirSync(unrelated);
    fs.writeFileSync(path.join(unrelated, 'package.json'), '{"name":"undici","version":"6.28.0"}');
    await patchNpmBundles(root, pins);
    for (const [name, pin] of Object.entries(pins)) {
      const pkg = JSON.parse(fs.readFileSync(path.join(npm, 'node_modules', name, 'package.json')));
      assert.equal(pkg.version, pin.version);
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
