import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchSourceMaps, verifySourceMaps } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pin = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).source_map_js;

test('replaces the real vulnerable source-map package, retains pnpm links, and rejects escaping paths', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-source-map-test-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const directory = path.join(root, '.pnpm/source-map-js@1.2.1/node_modules/source-map-js');
    fs.mkdirSync(directory, {recursive: true});
    const response = await fetch('https://registry.npmjs.org/source-map-js/-/source-map-js-1.2.1.tgz',
      {redirect: 'error', signal: AbortSignal.timeout(60000)});
    assert.equal(response.status, 200);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.ok(bytes.length < 1024 * 1024);
    assert.equal('sha512-' + createHash('sha512').update(bytes).digest('base64'),
      'sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==');
    const archive = path.join(temporary, 'package.tgz');
    fs.writeFileSync(archive, bytes);
    execFileSync('tar', ['-xzf', archive, '--strip-components=1', '--no-same-owner', '--no-same-permissions', '-C', directory]);
    const link = path.join(root, 'source-map-js');
    fs.symlinkSync(path.relative(root, directory), link);
    const linkTarget = fs.readlinkSync(link);
    // The original package accepts malicious offsets; fail before attempting costly conversion.
    assert.throws(() => verifySourceMaps(directory), /Missing expected exception/);
    await assert.rejects(patchSourceMaps(root, {...pin, sha512: '0'.repeat(128)}), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, '1.2.1');
    await patchSourceMaps(root, pin);
    assert.equal(fs.readlinkSync(link), linkTarget);
    assert.equal(JSON.parse(fs.readFileSync(path.join(link, 'package.json'))).version, '1.2.2');
    verifySourceMaps(directory);
    await patchSourceMaps(root, pin); // Already repaired: verify without another download.
    const outside = path.join(temporary, 'outside');
    fs.renameSync(directory, outside);
    fs.symlinkSync(outside, directory);
    await assert.rejects(patchSourceMaps(root, pin), /unexpected source-map-js dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
