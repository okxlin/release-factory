import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { patchMcpPackages } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).mcp_packages;
const verifier = fileURLToPath(new URL('../openclaw-builder/image/verify-mcp-auth.mjs', import.meta.url));

test('upgrades the real MCP packages together and blocks cross-issuer credential requests', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-mcp-test-'));
  try {
    // Install only the old reviewed package versions; no lifecycle scripts run.
    const dependencies = Object.fromEntries(Object.entries(pins).map(([name, pin]) => [name, pin.from]));
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    for (const [name, pin] of Object.entries(pins)) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', `${name.replace('/', '+')}@${pin.from}`, 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(path.dirname(original), directory), original);
      directories[name.split('/')[1]] = directory;
    }
    for (const kind of ['sdk', 'client']) {
      const result = spawnSync(process.execPath, [verifier, directories[kind], kind], {encoding: 'utf8', timeout: 30000});
      assert.equal(result.status, 1);
      assert.match(result.stderr, /Missing expected rejection/);
    }
    const badPins = structuredClone(pins);
    badPins['@modelcontextprotocol/core'].sha512 = '0'.repeat(128);
    await assert.rejects(patchMcpPackages(root, badPins), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directories.core, 'package.json'))).version, '2.0.0');
    await patchMcpPackages(root, pins);
    for (const [name, pin] of Object.entries(pins)) {
      assert.ok(fs.lstatSync(path.join(root, name)).isSymbolicLink());
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, name, 'package.json'))).version, pin.version);
    }
    await patchMcpPackages(root, pins); // Verify already fixed packages without downloading again.
    const outside = path.join(temporary, 'outside-core');
    fs.renameSync(directories.core, outside);
    fs.symlinkSync(outside, directories.core);
    await assert.rejects(patchMcpPackages(root, pins), /unexpected MCP dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
