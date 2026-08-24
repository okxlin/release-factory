#!/usr/bin/env node

import { lstat, readFile, readdir, realpath, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, sep } from 'node:path'

const pnpmRoot = process.argv[2] ?? '/opt/dsh/node_modules/.pnpm'
const AUTHENTICATED_SETTINGS_FLAG = 'globalThis.__DSH_AUTHENTICATED_SETTINGS__ === true'
const settingsPrefix = '@deepseek-ai+dsh-client-ui-settings@'
const settingsName = '@deepseek-ai/dsh-client-ui-settings'
const frontendPrefix = '@deepseek-ai+dsh-web-frontend@'
const frontendName = '@deepseek-ai/dsh-web-frontend'

const entries = await readdir(pnpmRoot, { withFileTypes: true })

function packagePath(prefix, packageName) {
  const candidates = entries.filter(
    (entry) => entry.isDirectory() && entry.name.startsWith(prefix),
  )
  if (candidates.length !== 1) {
    throw new Error(`expected exactly one ${packageName} package, found ${candidates.length}`)
  }
  return join(pnpmRoot, candidates[0].name, 'node_modules', ...packageName.split('/'))
}

async function assertTarget(target, label) {
  const stat = await lstat(target)
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a regular file: ${target}`)
  }
  const canonicalRoot = await realpath(pnpmRoot)
  const canonicalTarget = await realpath(target)
  const targetRelative = relative(canonicalRoot, canonicalTarget)
  if (
    targetRelative === ''
    || isAbsolute(targetRelative)
    || targetRelative === '..'
    || targetRelative.startsWith(`..${sep}`)
  ) {
    throw new Error(`${label} escapes pnpm root: ${canonicalTarget}`)
  }
}

function count(source, needle) {
  return source.split(needle).length - 1
}

async function patchSettingsMirror() {
  const packageRoot = packagePath(settingsPrefix, settingsName)
  const manifest = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'))
  if (manifest.name !== settingsName) {
    throw new Error(`unexpected package at ${packageRoot}: ${manifest.name}`)
  }

  const target = join(packageRoot, 'lib', 'client.js')
  await assertTarget(target, 'settings client patch target')
  const source = await readFile(target, 'utf8')
  const replacements = [
    {
      label: 'settings scope',
      original: 'new SettingsScopeController(connection.api, spec, this.mirror, connection.isLoopback ? "host" : "memory", this.schema)',
      replacement: `new SettingsScopeController(connection.api, spec, this.mirror, connection.isLoopback || ${AUTHENTICATED_SETTINGS_FLAG} ? "host" : "memory", this.schema)`,
    },
    {
      label: 'settings mirror',
      original: 'new SettingsDescribeMirror(connection.api, connection.isLoopback ? "host" : "memory")',
      replacement: `new SettingsDescribeMirror(connection.api, connection.isLoopback || ${AUTHENTICATED_SETTINGS_FLAG} ? "host" : "memory")`,
    },
  ]

  const shapes = replacements.map(({ label, original, replacement }) => ({
    label,
    original: count(source, original),
    replacement: count(source, replacement),
  }))
  if (shapes.every((shape) => shape.original === 0 && shape.replacement === 1)) {
    process.stdout.write(`[dsh-patch] authenticated settings client already patched: ${target}\n`)
    return
  }
  if (!shapes.every((shape) => shape.original === 1 && shape.replacement === 0)) {
    throw new Error(`unexpected settings client source shape: ${shapes.map((shape) => `${shape.label}[original=${shape.original}, replacement=${shape.replacement}]`).join(', ')}`)
  }

  const patched = replacements.reduce(
    (result, { original, replacement }) => result.replace(original, replacement),
    source,
  )
  if (!replacements.every(({ original, replacement }) => (
    count(patched, original) === 0 && count(patched, replacement) === 1
  ))) {
    throw new Error(`failed to verify authenticated settings client patch: ${target}`)
  }
  await writeFile(target, patched, 'utf8')
  process.stdout.write(`[dsh-patch] settings scopes accept authenticated proxy capability: ${target}\n`)
}

async function patchFrontendBootstrap() {
  const packageRoot = packagePath(frontendPrefix, frontendName)
  const manifest = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'))
  if (manifest.name !== frontendName) {
    throw new Error(`unexpected package at ${packageRoot}: ${manifest.name}`)
  }

  const target = join(packageRoot, 'dist', 'index.html')
  await assertTarget(target, 'web frontend bootstrap patch target')
  const source = await readFile(target, 'utf8')
  const bootstrap = '<script src="/dsh-deployment.js"></script>'
  const moduleScript = /  <script type="module"[^>]*><\/script>/u
  const bootstrapCount = count(source, bootstrap)
  const moduleMatch = source.match(moduleScript)

  if (bootstrapCount === 1) {
    process.stdout.write(`[dsh-patch] deployment bootstrap already installed: ${target}\n`)
    return
  }
  if (bootstrapCount !== 0 || moduleMatch === null || count(source, moduleMatch[0]) !== 1) {
    throw new Error(`unexpected web frontend HTML shape: bootstrap=${bootstrapCount}, module=${moduleMatch === null ? 0 : 1}`)
  }

  const patched = source.replace(moduleMatch[0], `  ${bootstrap}\n${moduleMatch[0]}`)
  if (count(patched, bootstrap) !== 1 || !patched.includes(`${bootstrap}\n${moduleMatch[0]}`)) {
    throw new Error(`failed to verify deployment bootstrap patch: ${target}`)
  }
  await writeFile(target, patched, 'utf8')
  process.stdout.write(`[dsh-patch] deployment capability bootstrap installed: ${target}\n`)
}

await patchSettingsMirror()
await patchFrontendBootstrap()
