#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const root = process.argv[2] ?? '/opt/dsh'
const version = process.argv[3]
if (version === undefined) {
  throw new Error('usage: patch-dsh-runtime-package.mjs <runtime-root> <version>')
}

const packagePath = join(root, 'package.json')
const packageManifest = JSON.parse(await readFile(packagePath, 'utf8'))
const installedPath = join(root, 'node_modules', '@deepseek-ai', 'dsh', 'package.json')
const installedManifest = JSON.parse(await readFile(installedPath, 'utf8'))
if (installedManifest.name !== '@deepseek-ai/dsh' || installedManifest.version !== version) {
  throw new Error(
    `installed @deepseek-ai/dsh does not match ${version}: ${installedManifest.name}@${installedManifest.version}`,
  )
}

packageManifest.name = 'deepseek-harness-runtime'
packageManifest.version = version
packageManifest.dependencies = { '@deepseek-ai/dsh': version }
delete packageManifest.allowScripts
await writeFile(packagePath, `${JSON.stringify(packageManifest, null, 2)}\n`, 'utf8')
process.stdout.write(`[dsh-patch] runtime manifest normalized to @deepseek-ai/dsh ${version}\n`)
