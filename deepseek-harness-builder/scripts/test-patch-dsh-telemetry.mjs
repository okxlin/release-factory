#!/usr/bin/env node

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'

const script = fileURLToPath(new URL('../image/scripts/patch-dsh-telemetry.mjs', import.meta.url))
const names = ['@deepseek-ai/dsh-session-log-deepseek', '@deepseek-ai/dsh-plugin-package-inventory-deepseek']
const source = 'export function apply(ctx, config) { if (config.enabled !== true) return; ctx.register(); }\n'

async function fixture(t, dependencies = names) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-telemetry-test-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const name of ['@deepseek-ai/dsh', '@deepseek-ai/dsh-base', ...dependencies]) {
    const directory = join(root, 'node_modules', name)
    await mkdir(directory, { recursive: true })
    await writeFile(join(directory, 'package.json'), JSON.stringify({
      name, version: '0.1.6-alpha.2', type: 'module', main: 'index.js',
      dependencies: Object.fromEntries(dependencies.map(value => [value, '*'])),
    }))
    await writeFile(join(directory, 'index.js'), name === names[1] ? source.replace('!== true', '=== false') : source)
  }
  return root
}

function run(root) {
  return spawnSync(process.execPath, [script, root], { encoding: 'utf8' })
}

test('non-empty opt-out blocks both contributors even when their config enables upload', async t => {
  const root = await fixture(t)
  assert.equal(run(root).status, 0)
  assert.equal(run(root).status, 0, 'patch is idempotent')
  const previous = process.env.DSH_TELEMETRY_DISABLED
  t.after(() => {
    if (previous === undefined) delete process.env.DSH_TELEMETRY_DISABLED
    else process.env.DSH_TELEMETRY_DISABLED = previous
  })
  for (const name of names) {
    const { apply } = await import(pathToFileURL(join(root, 'node_modules', name, 'index.js')))
    for (const value of ['1', '0', 'false', '']) {
      process.env.DSH_TELEMETRY_DISABLED = value
      let registrations = 0
      apply({ register() { registrations++ } }, { enabled: true })
      assert.equal(registrations, value ? 0 : 1, `${name}: opt-out=${JSON.stringify(value)}`)
    }
    delete process.env.DSH_TELEMETRY_DISABLED
    let registrations = 0
    apply({ register() { registrations++ } }, { enabled: false })
    assert.equal(registrations, 0, 'explicit upstream disable still works')
  }
})

test('legacy releases without the request contributors remain supported', async t => {
  const root = await fixture(t, [])
  assert.equal(run(root).status, 0)
})

test('unknown activation code and missing declared packages fail closed', async t => {
  const root = await fixture(t)
  const target = join(root, 'node_modules', names[0], 'index.js')
  await writeFile(target, 'export function apply() {}\n')
  assert.notEqual(run(root).status, 0)
  assert.equal(await readFile(target, 'utf8'), 'export function apply() {}\n')
  await rm(target)
  assert.notEqual(run(root).status, 0)
})

test('a package symlink cannot redirect writes outside the runtime', async t => {
  const root = await fixture(t)
  const external = await mkdtemp(join(tmpdir(), 'dsh-telemetry-outside-'))
  t.after(() => rm(external, { recursive: true, force: true }))
  await writeFile(join(external, 'index.js'), source)
  const target = join(root, 'node_modules', names[0], 'index.js')
  await rm(target)
  await symlink(join(external, 'index.js'), target)
  assert.notEqual(run(root).status, 0)
  assert.equal(await readFile(join(external, 'index.js'), 'utf8'), source)
})
