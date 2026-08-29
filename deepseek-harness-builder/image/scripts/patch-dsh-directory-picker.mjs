#!/usr/bin/env node

import { lstat, readFile, readdir, realpath, writeFile } from 'node:fs/promises'
import { isAbsolute, join, relative, sep } from 'node:path'

const pnpmRoot = process.argv[2] ?? '/opt/dsh/node_modules/.pnpm'
const packagePrefix = '@deepseek-ai+dsh-host-directory-picker-browse@'
const packageName = '@deepseek-ai/dsh-host-directory-picker-browse'
const original = 'const home = homedir();'
const replacement = 'const home = process.env.DSH_WORKSPACE || homedir();'

async function findPackageRoot(root) {
  const directRoot = join(root, ...packageName.split('/'))
  try {
    const manifest = JSON.parse(await readFile(join(directRoot, 'package.json'), 'utf8'))
    if (manifest.name !== packageName) {
      throw new Error(`unexpected package at ${directRoot}: ${manifest.name}`)
    }
    return directRoot
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error
  }

  const entries = await readdir(root, { withFileTypes: true })
  const candidates = entries.filter(
    (entry) => entry.isDirectory() && entry.name.startsWith(packagePrefix),
  )

  if (candidates.length !== 1) {
    throw new Error(
      `expected exactly one ${packageName} package, found ${candidates.length}`,
    )
  }

  return join(
    root,
    candidates[0].name,
    'node_modules',
    '@deepseek-ai',
    'dsh-host-directory-picker-browse',
  )
}

const packageRoot = await findPackageRoot(pnpmRoot)
const manifest = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'))
if (manifest.name !== packageName) {
  throw new Error(`unexpected package at ${packageRoot}: ${manifest.name}`)
}

const target = join(packageRoot, 'lib', 'index.js')
const targetStat = await lstat(target)
if (!targetStat.isFile() || targetStat.isSymbolicLink()) {
  throw new Error(`patch target must be a regular file: ${target}`)
}

const canonicalRoot = await realpath(pnpmRoot)
const canonicalTarget = await realpath(target)
const targetRelative = relative(canonicalRoot, canonicalTarget)
if (
  targetRelative === '' ||
  isAbsolute(targetRelative) ||
  targetRelative === '..' ||
  targetRelative.startsWith(`..${sep}`)
) {
  throw new Error(`patch target escapes pnpm root: ${canonicalTarget}`)
}

const count = (source, needle) => source.split(needle).length - 1
const source = await readFile(canonicalTarget, 'utf8')
const originalCount = count(source, original)
const replacementCount = count(source, replacement)

if (originalCount === 0 && replacementCount === 1) {
  process.stdout.write(`[dsh-patch] directory picker already patched: ${canonicalTarget}\n`)
  process.exit(0)
}
if (originalCount !== 1 || replacementCount !== 0) {
  throw new Error(
    `unexpected directory picker source shape: original=${originalCount}, replacement=${replacementCount}`,
  )
}

await writeFile(canonicalTarget, source.replace(original, replacement), 'utf8')
const patched = await readFile(canonicalTarget, 'utf8')
if (count(patched, original) !== 0 || count(patched, replacement) !== 1) {
  throw new Error(`failed to verify directory picker patch: ${canonicalTarget}`)
}

process.stdout.write(`[dsh-patch] default directory now follows DSH_WORKSPACE: ${canonicalTarget}\n`)
