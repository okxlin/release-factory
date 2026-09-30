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
// https://github.com/deepseek-ai/deepseek-harness/tree/dsh-v0.2.0-rc.2/packages/session/session-log-deepseek
const guards = [
  ['@deepseek-ai/dsh-session-log-deepseek', ['config.enabled !== true', '!config.enabled.get()']],
  ['@deepseek-ai/dsh-plugin-package-inventory-deepseek', ['config.enabled === false']],
]
for (const [name, supportedGuards] of guards) {
  if (!Object.hasOwn(base.dependencies ?? {}, name)) continue // Older npm releases have neither contributor.
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
  const matches = supportedGuards.map(guard => [
    `if (${guard})`, `if (${guard} || process.env.DSH_TELEMETRY_DISABLED)`,
  ]).filter(([original, replacement]) => count(original) + count(replacement) > 0)
  if (matches.length !== 1) throw new Error(`unexpected telemetry activation guard in ${name}`)
  const [original, replacement] = matches[0]
  if (count(original) + count(replacement) !== 1) {
    throw new Error(`unexpected telemetry activation guard in ${name}`)
  }
  let patched = source.replace(original, replacement)
  // 0.2 registers first and reads the volatile switch inside prepare(). Keep the
  // image opt-out at plugin activation as well as at request preparation.
  if (original.includes('config.enabled.get()')) {
    const entry = 'export function apply(ctx, config) {'
    const activation = `${entry}\n    if (process.env.DSH_TELEMETRY_DISABLED) return;`
    if (count(entry) !== 1) throw new Error(`unexpected telemetry plugin entry in ${name}`)
    if (!patched.includes(activation)) patched = patched.replace(entry, activation)
  }
  if (patched === source) continue
  await writeFile(target, patched, 'utf8')
  process.stdout.write(`[dsh-patch] ${name} honors DSH_TELEMETRY_DISABLED\n`)
}
