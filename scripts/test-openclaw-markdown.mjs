import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchMarkdownPackages, verifyMarkdown } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).markdown_packages;

test('repairs the real Markdown denial of service and retains pnpm consumers and the CLI', {timeout: 120000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-markdown-test-'));
  try {
    const dependencies = {'markdown-it': pins['markdown-it'].from, argparse: pins.argparse.from,
      entities: '8.1.0', 'linkify-it': '6.1.0', mdurl: '2.1.0', 'punycode.js': '2.3.1', 'uc.micro': '3.0.0'};
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 90000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    for (const [name, pin] of Object.entries(pins)) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', `${name}@${pin.from}`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(root, directory), original);
      directories[name] = directory;
    }
    const directory = directories['markdown-it'];
    const unrelated = path.join(root, '.pnpm/argparse@2.0.1/node_modules/argparse');
    fs.mkdirSync(unrelated, {recursive: true});
    fs.writeFileSync(path.join(unrelated, 'package.json'), '{"name":"argparse","version":"2.0.1"}\n');
    const argparseLink = path.join(path.dirname(directory), 'argparse');
    fs.symlinkSync(path.relative(path.dirname(argparseLink), directories.argparse), argparseLink);
    const linkTarget = fs.readlinkSync(argparseLink);
    // The untouched advisory PoC exceeds the same deadline that the fixed package must meet.
    assert.throws(() => verifyMarkdown(directory), {code: 'ETIMEDOUT'});
    const badPins = structuredClone(pins);
    badPins.argparse.sha512 = '0'.repeat(128);
    await assert.rejects(patchMarkdownPackages(root, badPins), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directories.argparse, 'package.json'))).version, pins.argparse.from);
    badPins.argparse = pins.argparse;
    badPins['markdown-it'].sha512 = '0'.repeat(128);
    await assert.rejects(patchMarkdownPackages(root, badPins), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, pins['markdown-it'].from);
    await patchMarkdownPackages(root, pins);
    for (const [name, pin] of Object.entries(pins)) {
      assert.ok(fs.lstatSync(path.join(root, name)).isSymbolicLink());
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, name, 'package.json'))).version, pin.version);
    }
    assert.equal(fs.readlinkSync(argparseLink), linkTarget);
    assert.equal(JSON.parse(fs.readFileSync(path.join(unrelated, 'package.json'))).version, '2.0.1');
    await patchMarkdownPackages(root, pins); // Verify repaired packages without another download.
    const outside = path.join(temporary, 'outside');
    fs.renameSync(directory, outside);
    fs.symlinkSync(outside, directory);
    await assert.rejects(patchMarkdownPackages(root, pins), /unexpected Markdown dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
