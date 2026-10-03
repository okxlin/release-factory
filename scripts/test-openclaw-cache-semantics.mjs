import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchCacheSemantics, verifyCacheSemantics } from '../openclaw-builder/image/patch-vendored-deps.mjs';

test('repairs the official cache implementation, preserves normal reuse, and rejects source drift', async () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-cache-test-'));
  try {
    const response = await fetch('https://registry.npmjs.org/http-cache-semantics/-/http-cache-semantics-4.2.0.tgz',
      {redirect: 'error', signal: AbortSignal.timeout(60000)});
    assert.equal(response.status, 200);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.ok(bytes.length < 1024 * 1024);
    assert.equal('sha512-' + createHash('sha512').update(bytes).digest('base64'), 'sha512-dTxcvPXqPvXBQpq5dUr6mEMJX4oIEFv6bwom3FDwKRDsuIjjJGANqhBuoAn9c1RQJIdAKav33ED65E2ys+87QQ==');
    const archive = path.join(temporary, 'package.tgz');
    fs.writeFileSync(archive, bytes);
    execFileSync('tar', ['-xzf', archive, '--no-same-owner', '--no-same-permissions', '-C', temporary,
      'package/index.js', 'package/package.json']);
    const directory = path.join(temporary, 'package');
    // Positive control: the exact public advisory fails against the untouched official release.
    assert.throws(() => verifyCacheSemantics(directory), /unsafe cached response reused/);
    patchCacheSemantics(directory);
    verifyCacheSemantics(directory);
    const file = path.join(directory, 'index.js');
    const patched = fs.readFileSync(file, 'utf8');
    patchCacheSemantics(directory);
    assert.equal(fs.readFileSync(file, 'utf8'), patched);
    fs.appendFileSync(file, '\n// unreviewed source change\n');
    assert.throws(() => patchCacheSemantics(directory), /unreviewed http-cache-semantics source/);
    fs.writeFileSync(file, patched);
    fs.symlinkSync(directory, path.join(temporary, 'redirect'));
    assert.throws(() => patchCacheSemantics(path.join(temporary, 'redirect')), /unexpected cache dependency path/);
  } finally {
    fs.rmSync(temporary, {recursive: true});
  }
});
