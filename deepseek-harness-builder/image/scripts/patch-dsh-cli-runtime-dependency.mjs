#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises'

const packagePath = process.argv[2]
if (packagePath === undefined) {
  throw new Error('usage: patch-dsh-cli-runtime-dependency.mjs <apps/cli/package.json>')
}

const packageName = '@deepseek-ai/dsh'
const requiredDependency = '@deepseek-ai/cordis-plugin-group'
const manifest = JSON.parse(await readFile(packagePath, 'utf8'))
if (manifest.name !== packageName) {
  throw new Error(`unexpected CLI package: ${manifest.name}`)
}

manifest.dependencies ??= {}
const current = manifest.dependencies[requiredDependency]
if (current !== undefined && current !== 'workspace:^') {
  throw new Error(
    `${requiredDependency} must be declared as workspace:^ when present; got ${JSON.stringify(current)}`,
  )
}

if (current === 'workspace:^') {
  process.stdout.write(`[dsh-patch] CLI already declares ${requiredDependency}\n`)
  process.exit(0)
}

manifest.dependencies = {
  [requiredDependency]: 'workspace:^',
  ...manifest.dependencies,
}
await writeFile(packagePath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')
process.stdout.write(`[dsh-patch] CLI runtime dependency added: ${requiredDependency}\n`)
