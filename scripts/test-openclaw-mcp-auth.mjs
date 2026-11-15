import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { patchMcpPackages } from '../openclaw-builder/image/patch-vendored-deps.mjs';
import './test-openclaw-mcp-http-fetch.mjs';

const pins = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).mcp_packages;
const verifier = fileURLToPath(new URL('../openclaw-builder/image/verify-mcp-auth.mjs', import.meta.url));
const fromVersions = pin => Array.isArray(pin.from) ? pin.from : [pin.from];

test('upgrades the real MCP packages together and blocks cross-issuer credential requests', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-mcp-test-'));
  try {
    // Install only the old reviewed package versions; no lifecycle scripts run.
    const dependencies = Object.fromEntries(Object.entries(pins).map(([name, pin]) => [name, fromVersions(pin)[0]]));
    dependencies['current-sdk'] = 'npm:@modelcontextprotocol/sdk@1.32.1';
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    const root = path.join(temporary, 'node_modules');
    const directories = {};
    for (const [name, pin] of Object.entries(pins)) {
      const original = path.join(root, name);
      const directory = path.join(root, '.pnpm', name.replace('/', '+') + '@' + fromVersions(pin)[0], 'node_modules', name);
      fs.mkdirSync(path.dirname(directory), {recursive: true});
      fs.renameSync(original, directory);
      fs.symlinkSync(path.relative(path.dirname(original), directory), original);
      directories[name.split('/')[1]] = directory;
    }
    const currentSdk = path.join(root, '.pnpm', '@modelcontextprotocol+sdk@1.32.1', 'node_modules', '@modelcontextprotocol/sdk');
    fs.mkdirSync(path.dirname(currentSdk), {recursive: true});
    fs.renameSync(path.join(root, 'current-sdk'), currentSdk);
    fs.symlinkSync(path.relative(root, currentSdk), path.join(root, 'current-sdk'));
    for (const kind of ['sdk', 'client']) {
      const result = spawnSync(process.execPath, [verifier, directories[kind], kind], {encoding: 'utf8', timeout: 30000});
      const oldIssuerBug = fromVersions(pins['@modelcontextprotocol/' + kind])[0] === (kind === 'sdk' ? '1.30.0' : '2.0.0');
      assert.equal(result.status, oldIssuerBug ? 1 : 0, result.stderr || result.error?.message);
      if (oldIssuerBug) assert.match(result.stderr, /Missing expected rejection/);
    }
    const badPins = structuredClone(pins);
    badPins['@modelcontextprotocol/core'].sha512 = '0'.repeat(128);
    await assert.rejects(patchMcpPackages(root, badPins), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directories.core, 'package.json'))).version, fromVersions(pins['@modelcontextprotocol/core'])[0]);
    const scalarPins = structuredClone(pins);
    scalarPins['@modelcontextprotocol/sdk'].from = fromVersions(pins['@modelcontextprotocol/sdk'])[0];
    await patchMcpPackages(root, scalarPins);
    assert.equal(JSON.parse(fs.readFileSync(path.join(directories.sdk, 'package.json'))).version, pins['@modelcontextprotocol/sdk'].version);
    assert.equal(JSON.parse(fs.readFileSync(path.join(currentSdk, 'package.json'))).version, '1.32.1',
      'the scalar baseline unexpectedly selected current OpenClaw SDK');
    await patchMcpPackages(root, pins);
    for (const [name, pin] of Object.entries(pins)) {
      assert.ok(fs.lstatSync(path.join(root, name)).isSymbolicLink());
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, name, 'package.json'))).version, pin.version);
    }
    assert.equal(JSON.parse(fs.readFileSync(path.join(currentSdk, 'package.json'))).version, pins['@modelcontextprotocol/sdk'].version,
      'current OpenClaw SDK 1.32.1 was left unpatched');
    await patchMcpPackages(root, pins); // Verify already fixed packages without downloading again.
    const outside = path.join(temporary, 'outside-core');
    fs.renameSync(directories.core, outside);
    fs.symlinkSync(outside, directories.core);
    await assert.rejects(patchMcpPackages(root, pins), /unexpected MCP dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});

test('checks native redirects in SDK 1.32.2 and client 2.4.0 with an unsafe client control', {timeout: 180000}, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-mcp-redirect-'));
  try {
    fs.writeFileSync(path.join(temporary, 'package.json'), JSON.stringify({private: true, dependencies: {
      'tested-sdk': 'npm:@modelcontextprotocol/sdk@1.32.2',
      'tested-client': 'npm:@modelcontextprotocol/client@2.4.0',
      'unsafe-client': 'npm:@modelcontextprotocol/client@2.2.0',
    }}));
    execFileSync('npm', ['install', '--prefix', temporary, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    for (const mode of ['cjs', 'esm']) {
      const unsafe = spawnSync(process.execPath, [verifier, path.join(temporary, 'node_modules/unsafe-client'), 'client', mode],
        {encoding: 'utf8', timeout: 30000});
      assert.equal(unsafe.status, 1, unsafe.stderr);
      assert.match(unsafe.stderr, /MCP token redirect crossed an origin/);
      console.log('RED: original client 2.2.0 redirect request reached the other origin (' + mode + ')');
      for (const [name, kind] of [['tested-sdk', 'sdk'], ['tested-client', 'client']]) {
        const result = spawnSync(process.execPath, [verifier, path.join(temporary, 'node_modules', name), kind, mode],
          {encoding: 'utf8', timeout: 30000});
        assert.equal(result.status, 0, result.stderr || result.error?.message);
        assert.match(result.stdout, /Verified MCP OAuth issuer binding/);
        console.log(result.stdout.trim());
      }
    }
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
