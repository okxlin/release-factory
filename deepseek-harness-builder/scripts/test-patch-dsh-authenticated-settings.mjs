#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const script = fileURLToPath(new URL('../image/scripts/patch-dsh-authenticated-settings.mjs', import.meta.url))
const bootstrap = '<script src="/dsh-deployment.js"></script>'

async function fixture(t, source) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-settings-test-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const [name, directory] of [['dsh-client-ui-settings', 'lib'], ['dsh-web-frontend', 'dist']]) {
    const target = join(root, '@deepseek-ai', name)
    await mkdir(join(target, directory), { recursive: true })
    await writeFile(join(target, 'package.json'), JSON.stringify({ name: `@deepseek-ai/${name}` }))
  }
  const client = join(root, '@deepseek-ai/dsh-client-ui-settings/lib/client.js')
  const html = join(root, '@deepseek-ai/dsh-web-frontend/dist/index.html')
  await writeFile(client, source)
  await writeFile(html, '  <script type="module" src="/main.js"></script>\n')
  return { root, client, html }
}

function run(root) {
  return spawnSync(process.execPath, [script, root], { encoding: 'utf8' })
}

for (const [expression, occurrences] of [
  ['connection.isLoopback', 2], ['ctx.remote.$host.isLoopback', 1],
]) {
  test(`legacy ${expression} requires a strict authenticated capability`, async t => {
    const source = Array(occurrences).fill(`${expression} ? "host" : "memory"`).join(';\n')
    const f = await fixture(t, source)
    assert.equal(run(f.root).status, 0)
    const patched = await readFile(f.client, 'utf8')
    assert.equal(run(f.root).status, 0)
    assert.equal(await readFile(f.client, 'utf8'), patched)
    for (const loopback of [false, true]) {
      for (const flag of [undefined, false, true, 'true']) {
        const context = { connection: { isLoopback: loopback }, ctx: { remote: { $host: { isLoopback: loopback } } },
          __DSH_AUTHENTICATED_SETTINGS__: flag }
        assert.equal(vm.runInNewContext(patched, context), loopback || flag === true ? 'host' : 'memory')
      }
    }
    assert.equal((await readFile(f.html, 'utf8')).split(bootstrap).length, 2)
  })
}

// Only framework services and the remote transport are doubles. The complete
// official browser bundle supplies the actual mirror, forms, and write queue.
function loadClient(source, ctx) {
  let exports
  const dependencies = {
    '@deepseek-ai/cordis': { Service: class { constructor(context, name) { this.ctx = context; context[name] = this } } },
    '@deepseek-ai/dsh-client-store': {
      createSnapshotStore(initial) {
        let snapshot = initial
        const listeners = new Set()
        const store = {
          getSnapshot: () => snapshot,
          subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener) },
          set(value) { snapshot = value; for (const listener of listeners) listener() },
          update(callback) { const value = structuredClone(snapshot); callback(value); store.set(value) },
        }
        return store
      },
    },
  }
  vm.runInNewContext(source, { structuredClone, window: { __ModuleLoader__: { load(module) {
    assert.equal(module.id, '@deepseek-ai/dsh-client-ui-settings')
    exports = module.factory(name => { assert.ok(Object.hasOwn(dependencies, name)); return dependencies[name] })
  } } } }, { timeout: 5000 })
  exports.apply(ctx)
}

test('reviewed upstream bundle persists remote preferences and preserves Host rejection', async t => {
  const response = await fetch('https://registry.npmjs.org/@deepseek-ai/dsh-client-ui-settings/-/dsh-client-ui-settings-0.2.1-rc.2.tgz',
    { redirect: 'error', signal: AbortSignal.timeout(60000) })
  assert.equal(response.status, 200)
  const archive = Buffer.from(await response.arrayBuffer())
  assert.ok(archive.length < 1024 * 1024)
  assert.equal(createHash('sha512').update(archive).digest('base64'),
    'oU8f/0+DsdbgF0XhM+Po7W4PDJmTbhifQVwIoAcKfj29JN/4tLxKqIKS0IRcMbIGD39BGFITne78KIMgrGJy3Q==')
  const source = execFileSync('tar', ['-xzOf', '-', 'package/lib/client.js'], { input: archive, encoding: 'utf8' })
  const f = await fixture(t, source)
  let result = run(f.root)
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /verified upstream Host settings/)
  assert.equal(await readFile(f.client, 'utf8'), source, 'upstream fix remains unchanged')
  assert.equal(run(f.root).status, 0)
  assert.equal((await readFile(f.html, 'utf8')).split(bootstrap).length, 2)

  let stored = false
  let revision = 1
  let accept = true
  const writes = []
  const view = () => ({ ns: 'ui-settings', schema: { type: 'object', dict: { enabled: { type: 'boolean' } } },
    value: { enabled: stored }, revision, autoGenerate: true, applies: 'live', secrets: [] })
  const ctx = {
    effect(callback) { callback() }, on() { return () => {} },
    remote: {
      $host: { isLoopback: false }, $on() { return () => {} },
      settings: {
        async describe() { return { ok: true, value: { writable: true, hasDocument: true, namespaces: [view()] } } },
        async mutate(ns, ops, expected) {
          writes.push([ns, ops, expected])
          if (!accept) return { ok: false, error: { message: 'denied by Host' } }
          assert.equal(expected, revision)
          stored = ops[0].value; revision++
          return { ok: true, value: view() }
        },
      },
    },
  }
  loadClient(source, ctx)
  await ctx.configForms.describe().ensure()
  const preference = ctx.configForms.developerTools
  assert.equal(preference.enabled.getSnapshot(), false)
  await preference.setEnabled(true)
  assert.equal(stored, true)
  assert.equal(preference.enabled.getSnapshot(), true)
  assert.equal(writes.length, 1)
  assert.equal(writes[0][0], 'ui-settings')
  assert.equal(writes[0][1][0].path[0], 'enabled')
  accept = false
  await assert.rejects(preference.setEnabled(false), /not saved/)
  assert.equal(stored, true)
  assert.equal(preference.enabled.getSnapshot(), true, 'rejected write recovers accepted Host state')

  await writeFile(f.client, source.replace('new SettingsDescribeMirror(ctx)', 'new SettingsDescribeMirror({})'))
  result = run(f.root)
  assert.notEqual(result.status, 0, 'unreviewed upstream source drift must fail closed')
  assert.match(result.stderr, /unexpected settings client source shape/)
})
