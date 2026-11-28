import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchSourceMaps, verifySourceMaps } from '../openclaw-builder/image/patch-vendored-deps.mjs';

const pin = JSON.parse(fs.readFileSync(new URL('../openclaw-builder/configs/components.json', import.meta.url))).source_map_js;

for (const version of ['1.2.1', '1.2.2']) test(`updates real source-map-js ${version}, retains pnpm links, and rejects escaping paths`, async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-source-map-test-'));
  try {
    const root = path.join(temporary, 'node_modules');
    const directory = path.join(root, `.pnpm/source-map-js@${version}/node_modules/source-map-js`);
    fs.mkdirSync(directory, {recursive: true});
    const response = await fetch(`https://registry.npmjs.org/source-map-js/-/source-map-js-${version}.tgz`,
      {redirect: 'error', signal: AbortSignal.timeout(60000)});
    assert.equal(response.status, 200);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.ok(bytes.length < 1024 * 1024);
    const integrity = version === '1.2.1' ?
      'sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==' :
      'sha512-' + Buffer.from('2868fff18e37c77e5a6550edb7e27898ad61a0b18750b3187d290e0c93508cd0c2de85b53ea3e8c4cc28d292d4b1633f5041b338dfcdc5e1f2c047cd5cd3f757', 'hex').toString('base64');
    assert.equal('sha512-' + createHash('sha512').update(bytes).digest('base64'), integrity);
    const archive = path.join(temporary, 'package.tgz');
    fs.writeFileSync(archive, bytes);
    execFileSync('tar', ['-xzf', archive, '--strip-components=1', '--no-same-owner', '--no-same-permissions', '-C', directory]);
    const link = path.join(root, 'source-map-js');
    fs.symlinkSync(path.relative(root, directory), link);
    const linkTarget = fs.readlinkSync(link);
    // The original package accepts malicious offsets; fail before attempting costly conversion.
    if (version === '1.2.1') assert.throws(() => verifySourceMaps(directory), /Missing expected exception/);
    else verifySourceMaps(directory); // The actual current upstream baseline is already safe.
    await assert.rejects(patchSourceMaps(root, {...pin, sha512: '0'.repeat(128)}), {code: 'ERR_ASSERTION'});
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'package.json'))).version, version);
    await patchSourceMaps(root, pin);
    assert.equal(fs.readlinkSync(link), linkTarget);
    assert.equal(JSON.parse(fs.readFileSync(path.join(link, 'package.json'))).version, pin.version);
    verifySourceMaps(directory);
    await patchSourceMaps(root, pin); // Already repaired: verify without another download.
    const packageFile = path.join(directory, 'package.json');
    const originalPackage = fs.readFileSync(packageFile);
    const unreviewed = JSON.parse(originalPackage);
    unreviewed.version = '1.99.99';
    fs.writeFileSync(packageFile, JSON.stringify(unreviewed));
    await assert.rejects(patchSourceMaps(root, pin), /unreviewed source-map-js version/);
    fs.writeFileSync(packageFile, originalPackage);
    const outside = path.join(temporary, 'outside');
    fs.renameSync(directory, outside);
    fs.symlinkSync(outside, directory);
    await assert.rejects(patchSourceMaps(root, pin), /unexpected source-map-js dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
