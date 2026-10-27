import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchCodeServerDeps, verifyZod } from '../image/patch-code-server-deps.mjs';

function install(directory, dependencies) {
  fs.mkdirSync(directory, {recursive: true});
  fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify({name: 'code-server', private: true, dependencies}));
  execFileSync('npm', ['install', '--prefix', directory, '--ignore-scripts', '--package-lock=false',
    '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
}

test('repairs real code-server dependency layouts and preserves the sandbox v3 contract', {timeout: 240000}, () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'code-server-deps-test-'));
  const root = path.join(temporary, 'code-server');
  const staging = path.join(temporary, 'security');
  const vscode = path.join(root, 'lib/vscode');
  const versions = new Map([
    ['node_modules/body-parser', '2.3.0'],
    ['node_modules/follow-redirects', '1.16.0'],
    ['lib/vscode/node_modules/zod', '4.4.3'],
    ['lib/vscode/node_modules/@github/copilot-sdk/node_modules/zod', '4.3.6'],
    ['lib/vscode/node_modules/@vscode/sandbox-runtime/node_modules/zod', '3.25.76'],
  ]);
  function unchanged() {
    for (const [relative, version] of versions) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, relative, 'package.json'))).version, version);
    }
    assert.equal(fs.readdirSync(root).some(name => name.startsWith('.release-factory-security-')), false);
  }
  try {
    install(root, {'body-parser': '2.3.0', 'follow-redirects': '1.16.0', express: '5.2.1'});
    install(vscode, {zod: '4.4.3', 'copilot-zod': 'npm:zod@4.3.6', '@vscode/sandbox-runtime': '0.0.1'});
    const copilot = path.join(vscode, 'node_modules/@github/copilot-sdk/node_modules');
    fs.mkdirSync(copilot, {recursive: true});
    fs.renameSync(path.join(vscode, 'node_modules/copilot-zod'), path.join(copilot, 'zod'));
    unchanged();
    for (const [relative, version] of [...versions].filter(([relative]) => relative.endsWith('/zod'))) {
      assert.throws(() => verifyZod(path.join(root, relative), version.startsWith('3.') ? 'v3' : 'v4'),
        /bounded zod container parsed oversized elements/);
    }
    fs.mkdirSync(staging);
    for (const name of ['package.json', 'package-lock.json']) {
      fs.copyFileSync(new URL('../image/code-server-security/' + name, import.meta.url),
        path.join(staging, name));
    }
    execFileSync('npm', ['ci', '--prefix', staging, '--install-strategy=nested', '--omit=dev',
      '--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'],
    {timeout: 120000, stdio: 'pipe'});

    const zodPackage = path.join(vscode, 'node_modules/zod/package.json');
    const originalZod = fs.readFileSync(zodPackage);
    fs.writeFileSync(zodPackage, JSON.stringify({...JSON.parse(originalZod), version: '4.4.2'}));
    assert.throws(() => patchCodeServerDeps(root, staging), /unreviewed zod version/);
    fs.writeFileSync(zodPackage, originalZod);
    unchanged();

    const parser = path.join(root, 'node_modules/body-parser');
    const outside = path.join(temporary, 'outside-body-parser');
    fs.renameSync(parser, outside);
    fs.symlinkSync(outside, parser);
    assert.throws(() => patchCodeServerDeps(root, staging), /unexpected dependency path/);
    fs.unlinkSync(parser);
    fs.renameSync(outside, parser);
    unchanged();

    // A deliberately mismatched resolved dependency must roll back every replacement.
    const contentTypePackage = path.join(staging, 'node_modules/body-parser/node_modules/content-type/package.json');
    const originalContentType = fs.readFileSync(contentTypePackage);
    fs.writeFileSync(contentTypePackage, JSON.stringify({...JSON.parse(originalContentType), version: '2.0.0'}));
    assert.throws(() => patchCodeServerDeps(root, staging), /2\.0\.0/);
    fs.writeFileSync(contentTypePackage, originalContentType);
    unchanged();

    patchCodeServerDeps(root, staging);
    const sandboxPackage = JSON.parse(fs.readFileSync(path.join(root,
      'lib/vscode/node_modules/@vscode/sandbox-runtime/node_modules/zod/package.json')));
    assert.equal(sandboxPackage.main, './v3/index.cjs');
    assert.equal(sandboxPackage.module, './v3/index.js');
    assert.equal(sandboxPackage.types, './v3/index.d.cts');
    assert.deepEqual(sandboxPackage.exports['.'], sandboxPackage.exports['./v3']);
    patchCodeServerDeps(root, staging);
  } finally {fs.rmSync(temporary, {recursive: true, force: true});}
});
