#!/usr/bin/env node

import { lstat, readFile, readdir, realpath, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, sep } from 'node:path'

const pnpmRoot = process.argv[2] ?? '/opt/dsh/node_modules/.pnpm'
const AUTHENTICATED_SETTINGS_FLAG = 'globalThis.__DSH_AUTHENTICATED_SETTINGS__ === true'
const settingsPrefix = '@deepseek-ai+dsh-client-ui-settings@'
const settingsName = '@deepseek-ai/dsh-client-ui-settings'
const frontendPrefix = '@deepseek-ai+dsh-web-frontend@'
const frontendName = '@deepseek-ai/dsh-web-frontend'

const entries = await readdir(pnpmRoot, { withFileTypes: true }).catch((error) => {
  if (error?.code === 'ENOENT') return null
  throw error
})

async function packagePath(prefix, packageName) {
  const directRoot = join(pnpmRoot, ...packageName.split('/'))
  try {
    const manifest = JSON.parse(await readFile(join(directRoot, 'package.json'), 'utf8'))
    if (manifest.name !== packageName) {
      throw new Error(`unexpected package at ${directRoot}: ${manifest.name}`)
    }
    return directRoot
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }

  if (entries === null) {
    throw new Error(`cannot find ${packageName} under ${pnpmRoot}`)
  }
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
  const packageRoot = await packagePath(settingsPrefix, settingsName)
  const manifest = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'))
  if (manifest.name !== settingsName) {
    throw new Error(`unexpected package at ${packageRoot}: ${manifest.name}`)
  }

  const target = join(packageRoot, 'lib', 'client.js')
  await assertTarget(target, 'settings client patch target')
  const source = await readFile(target, 'utf8')
  const patchShapes = [
    {
      name: 'connection loopback',
      original: 'connection.isLoopback ? "host" : "memory"',
      replacement: `connection.isLoopback || ${AUTHENTICATED_SETTINGS_FLAG} ? "host" : "memory"`,
      occurrences: 2,
    },
    {
      name: 'remote host loopback',
      original: 'ctx.remote.$host.isLoopback ? "host" : "memory"',
      replacement: `ctx.remote.$host.isLoopback || ${AUTHENTICATED_SETTINGS_FLAG} ? "host" : "memory"`,
      occurrences: 1,
    },
  ]
  const alreadyPatched = patchShapes.filter(({ original, replacement, occurrences }) => (
    count(source, original) === 0 && count(source, replacement) === occurrences
  ))
  if (alreadyPatched.length === 1) {
    process.stdout.write(`[dsh-patch] authenticated settings client already patched: ${target}\n`)
    return
  }
  const candidates = patchShapes.filter(({ original, replacement, occurrences }) => (
    count(source, original) === occurrences && count(source, replacement) === 0
  ))
  if (candidates.length !== 1) {
    const shapeSummary = patchShapes.map(({ name, original, replacement }) => (
      `${name}[original=${count(source, original)}, replacement=${count(source, replacement)}]`
    )).join(', ')
    throw new Error(`unexpected settings client source shape: ${shapeSummary}`)
  }

  const { original, replacement, occurrences } = candidates[0]
  const patched = source.replaceAll(original, replacement)
  if (count(patched, original) !== 0 || count(patched, replacement) !== occurrences) {
    throw new Error(`failed to verify authenticated settings client patch: ${target}`)
  }
  await writeFile(target, patched, 'utf8')
  process.stdout.write(`[dsh-patch] settings scopes accept authenticated proxy capability: ${target}\n`)
}

async function patchFrontendBootstrap() {
  const packageRoot = await packagePath(frontendPrefix, frontendName)
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
