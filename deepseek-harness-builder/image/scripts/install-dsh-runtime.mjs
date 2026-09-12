#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

// Release families also contain opt-in plugins and test packages. Only promote
// the CLI's runtime closure to npm install roots, keeping every selected local
// tarball so unpublished releases and our source patches do not need npm copies.
export function selectRuntimePackages(packages) {
  const byName = new Map()
  for (const entry of packages) {
    const { name, version } = entry.manifest
    if (typeof name !== 'string' || !name || typeof version !== 'string' || !version) {
      throw new Error(`${entry.path}: packed package must declare name and version`)
    }
    if (byName.has(name)) throw new Error(`duplicate packed package: ${name}`)
    byName.set(name, entry)
  }

  const root = '@deepseek-ai/dsh'
  if (!byName.has(root)) throw new Error(`missing packed CLI: ${root}`)
  const selected = new Set()
  const pending = [root]
  while (pending.length > 0) {
    const name = pending.pop()
    if (selected.has(name)) continue
    selected.add(name)
    const manifest = byName.get(name).manifest
    const dependencies = new Set([
      ...Object.keys(manifest.dependencies ?? {}),
      ...Object.keys(manifest.optionalDependencies ?? {}),
    ])
    for (const peer of Object.keys(manifest.peerDependencies ?? {})) {
      if (manifest.peerDependenciesMeta?.[peer]?.optional !== true) dependencies.add(peer)
    }
    for (const dependency of dependencies) {
      if (byName.has(dependency)) pending.push(dependency)
    }
  }
  return [...selected].sort().map(name => byName.get(name))
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const packages = process.argv.slice(2).map(path => {
    path = resolve(path)
    // Read the packed manifest: pnpm has already resolved workspace: ranges.
    const manifest = JSON.parse(execFileSync('tar', ['-xOf', path, 'package/package.json'], {
      encoding: 'utf8',
    }))
    return { path, manifest }
  })
  const selected = selectRuntimePackages(packages)
  process.stdout.write(`[dsh-runtime] installing ${selected.length}/${packages.length} local packages from the CLI runtime closure\n`)
  execFileSync('npm', [
    'install', '--ignore-scripts', '--include=optional', '--omit=dev',
    '--no-audit', '--no-fund', '--package-lock=false',
    ...selected.map(entry => entry.path),
  ], { stdio: 'inherit' })
}
