#!/usr/bin/env node

import { lstat, readFile, realpath, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { isAbsolute, join, relative, sep } from 'node:path'

const root = await realpath(process.argv[2] ?? '/opt/dsh')
const runtimeRequire = createRequire(join(root, 'package.json'))
const cliRequire = createRequire(runtimeRequire.resolve('@deepseek-ai/dsh/package.json'))
const basePath = cliRequire.resolve('@deepseek-ai/dsh-base/package.json')
const base = JSON.parse(await readFile(basePath, 'utf8'))
if (base.name !== '@deepseek-ai/dsh-base') throw new Error('unexpected DSH base package')
const baseRequire = createRequire(basePath)

// These 0.1.6 request contributors are independent of the CLI's OTel switch.
// Preserve the image's opt-out for every profile, including explicit overlays.
// https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.1.6-alpha.2/packages/session/session-log-deepseek
const guards = [
  ['@deepseek-ai/dsh-session-log-deepseek', 'config.enabled !== true'],
  ['@deepseek-ai/dsh-plugin-package-inventory-deepseek', 'config.enabled === false'],
]
for (const [name, guard] of guards) {
  if (!Object.hasOwn(base.dependencies ?? {}, name)) continue // Older npm releases have neither contributor.
  const original = `if (${guard})`
  const replacement = `if (${guard} || process.env.DSH_TELEMETRY_DISABLED)`
  const target = baseRequire.resolve(name)
  const stat = await lstat(target)
  const canonical = await realpath(target)
  const offset = relative(root, canonical)
  if (!stat.isFile() || stat.isSymbolicLink() || offset === '' || isAbsolute(offset)
      || offset === '..' || offset.startsWith(`..${sep}`)) {
    throw new Error(`telemetry patch target escapes runtime: ${target}`)
  }
  const source = await readFile(target, 'utf8')
  const count = needle => source.split(needle).length - 1
  if (count(original) === 0 && count(replacement) === 1) continue
  if (count(original) !== 1 || count(replacement) !== 0) {
    throw new Error(`unexpected telemetry activation guard in ${name}`)
  }
  await writeFile(target, source.replace(original, replacement), 'utf8')
  process.stdout.write(`[dsh-patch] ${name} honors DSH_TELEMETRY_DISABLED\n`)
}
