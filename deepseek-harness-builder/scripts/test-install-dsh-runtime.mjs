#!/usr/bin/env node

import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { selectRuntimePackages } from '../image/scripts/install-dsh-runtime.mjs'

const cli = '@deepseek-ai/dsh'
const codex = '@deepseek-ai/dsh-subagent-codex'
const claude = '@deepseek-ai/dsh-subagent-claude-code'
const hook = '@deepseek-ai/dsh-hooks-codex'
const fixture = (name, fields = {}) => ({
  path: `/packs/${name.replace('/', '-')}.tgz`,
  manifest: { name, version: '0.0.0-source-test.1', ...fields },
})
const names = packages => selectRuntimePackages(packages).map(p => p.manifest.name).sort()

test('keeps the CLI runtime closure, including local vendor, optional and required peers', () => {
  const packages = [
    fixture(cli, {
      dependencies: { base: '*', [hook]: '*' },
      devDependencies: { [codex]: '*' },
      peerDependencies: { [codex]: '*' },
      peerDependenciesMeta: { [codex]: { optional: true } },
    }),
    fixture('base', {
      dependencies: { vendor: '*', 'external-registry-package': '*' },
      optionalDependencies: { optional: '*' },
      peerDependencies: { peer: '*' },
    }),
    fixture('vendor', { peerDependencies: { base: '*' } }),
    fixture('optional'), fixture('peer'), fixture(hook),
    fixture(codex, { dependencies: { '@openai/codex': '*' } }),
    fixture(claude, { dependencies: { '@anthropic-ai/claude-agent-sdk': '*' } }),
  ]
  assert.deepEqual(names(packages), [cli, hook, 'base', 'optional', 'peer', 'vendor'].sort())
  assert.deepEqual(names(packages.toReversed()), names(packages))
})

test('selects a plugin if it becomes a real runtime dependency; no plugin denylist', () => {
  assert.deepEqual(names([
    fixture(cli, { dependencies: { [codex]: '*' } }),
    fixture(codex), fixture(claude),
  ]), [cli, codex].sort())
})

test('optional peer metadata does not hide a direct dependency', () => {
  assert.deepEqual(names([
    fixture(cli, {
      dependencies: { shared: '*' },
      peerDependencies: { shared: '*' },
      peerDependenciesMeta: { shared: { optional: true } },
    }),
    fixture('shared'),
  ]), [cli, 'shared'].sort())
})

test('rejects a missing CLI, duplicate package names and malformed identities', () => {
  assert.throws(() => selectRuntimePackages([fixture('other')]), /missing.*@deepseek-ai\/dsh/)
  assert.throws(() => selectRuntimePackages([fixture(cli), fixture(cli)]), /duplicate/)
  assert.throws(() => selectRuntimePackages([fixture(cli, { version: '' })]), /name and version/)
})

test('installs unpublished local tarballs offline without opt-in plugins or lifecycle scripts', t => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-runtime-tarballs-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const runtime = join(root, 'runtime')
  mkdirSync(runtime)
  writeFileSync(join(runtime, 'package.json'), '{"name":"runtime-test","private":true}\n')
  const version = '0.0.0-source-test.1'
  const packages = [
    fixture(cli, {
      dependencies: { [hook]: version, 'source-only-vendor': version },
      devDependencies: { [codex]: version },
      peerDependencies: { [claude]: version },
      peerDependenciesMeta: { [claude]: { optional: true } },
    }),
    fixture(hook),
    fixture('source-only-vendor', {
      peerDependencies: { [hook]: version },
      scripts: { postinstall: 'node -e "require(\'node:fs\').writeFileSync(\'install-ran\', \'yes\')"' },
    }),
    // A regression that selects these tries to resolve their payloads offline.
    fixture(codex, { dependencies: { '@openai/codex': '*' } }),
    fixture(claude, { dependencies: { '@anthropic-ai/claude-agent-sdk': '*' } }),
  ]
  const tarballs = packages.map(({ manifest }, index) => {
    const stage = join(root, `stage-${index}`)
    const payload = join(stage, 'package')
    mkdirSync(payload, { recursive: true })
    writeFileSync(join(payload, 'package.json'), JSON.stringify(manifest))
    writeFileSync(join(payload, 'index.js'), 'module.exports = "local-source-patch"\n')
    const tarball = join(root, `${index} local.tgz`)
    execFileSync('tar', ['-czf', tarball, '-C', stage, 'package'])
    return tarball
  })
  const installer = fileURLToPath(new URL('../image/scripts/install-dsh-runtime.mjs', import.meta.url))
  const output = execFileSync(process.execPath, [installer, ...tarballs], {
    cwd: runtime,
    encoding: 'utf8',
    env: {
      ...process.env,
      NPM_CONFIG_OFFLINE: 'true',
      NPM_CONFIG_CACHE: join(root, 'cache'),
      NPM_CONFIG_REGISTRY: 'http://127.0.0.1:9',
    },
  })
  assert.match(output, /installing 3\/5 local packages/)
  for (const name of [cli, hook, 'source-only-vendor']) {
    const installed = join(runtime, 'node_modules', name)
    assert.equal(JSON.parse(readFileSync(join(installed, 'package.json'))).version, version)
    assert.equal(readFileSync(join(installed, 'index.js'), 'utf8'), 'module.exports = "local-source-patch"\n')
    assert.equal(existsSync(join(installed, 'install-ran')), false)
  }
  for (const name of [codex, claude, '@openai/codex', '@anthropic-ai/claude-agent-sdk']) {
    assert.equal(existsSync(join(runtime, 'node_modules', name)), false, name)
  }
  const lock = JSON.parse(readFileSync(join(runtime, 'node_modules/.package-lock.json')))
  assert.equal(Object.keys(lock.packages).length, 3)
  assert.ok(Object.values(lock.packages).every(pkg => pkg.resolved.startsWith('file:')))
})
