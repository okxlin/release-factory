#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const root = resolve(process.argv[2] ?? '/opt/dsh')
const component = process.argv[3] ?? 'all'
assert.ok(['all', 'zod', 'undici'].includes(component), 'expected all, zod or undici')
const consumerRequire = name => createRequire(join(root, 'node_modules', name, 'package.json'))

if (component !== 'undici') {
  const require = consumerRequire('@deepseek-ai/dsh-agent-loop')
  const directory = dirname(require.resolve('zod/package.json'))
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
  assert.match(manifest.version, /^4\./, 'DeepSeek requires the Zod 4 API')
  for (const [mode, z] of [
    ['cjs', require('zod')],
    ['esm', await import(pathToFileURL(join(directory, manifest.module)))],
  ]) {
    const schema = z.object({ name: z.string() })
    assert.deepEqual(schema.parse({ name: 'deepseek' }), { name: 'deepseek' })
    assert.equal(schema.safeParse({ name: 42 }).success, false)
    assert.equal(z.toJSONSchema(schema).properties.name.type, 'string')
    let visited = 0
    const element = z.string().refine(() => { visited++; return true })
    // https://github.com/advisories/GHSA-mrhx-c7xc-m3w5
    for (const bounded of [z.array(element).max(2), z.array(element).length(2)]) {
      const result = bounded.safeParse(new Array(10000).fill('x'))
      assert.equal(result.success, false)
      assert.equal(visited, 0, 'bounded Zod container parsed oversized elements')
      assert.equal(result.error.issues.length, 1)
      assert.equal(result.error.issues[0].code, 'too_big')
    }
    assert.deepEqual(z.array(element).max(2).parse(['x']), ['x'])
    assert.equal(visited, 1)
    assert.equal(z.array(z.string()).safeParse([1, 2, 3]).error.issues.length, 3)
    let asyncVisited = 0
    const asyncSchema = z.array(z.string().refine(async () => { asyncVisited++; return true })).max(1)
    assert.equal((await asyncSchema.safeParseAsync(['x', 'y'])).error.issues.length, 1)
    assert.equal(asyncVisited, 0)
    assert.deepEqual(await asyncSchema.parseAsync(['x']), ['x'])
    assert.equal(asyncVisited, 1)
    console.log(`Verified Zod ${manifest.version} ${mode}: schemas and bounded collection parsing`)
  }
}

if (component !== 'zod') {
  const checked = new Set()
  for (const consumer of ['@deepseek-ai/dsh-web-fetch-http', '@deepseek-ai/dsh-http-proxy']) {
    const require = consumerRequire(consumer)
    const entry = require.resolve('undici')
    if (checked.has(entry)) continue
    checked.add(entry)
    const undici = await import(pathToFileURL(entry))
    for (const name of ['Agent', 'Pool', 'ProxyAgent', 'fetch', 'getGlobalDispatcher', 'setGlobalDispatcher']) {
      assert.equal(typeof undici[name], 'function', `${consumer}: missing ${name}`)
    }
    const body = 'deepseek-runtime'
    const server = createServer((_request, response) => response.end(body))
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
    const url = `http://127.0.0.1:${server.address().port}/`
    const dispatcher = new undici.Agent()
    const previous = undici.getGlobalDispatcher()
    undici.setGlobalDispatcher(dispatcher)
    try {
      assert.equal(await (await fetch(url, { signal: AbortSignal.timeout(5000) })).text(), body)
      const digest = createHash('sha256').update(body).digest('base64')
      const wrong = createHash('sha256').update('different-body').digest('base64')
      // https://github.com/advisories/GHSA-f72v-6w45-q472
      for (const algorithm of ['sha256', 'SHA256', 'Sha256']) {
        const response = await undici.fetch(url, {
          integrity: `${algorithm}-${digest}`, signal: AbortSignal.timeout(5000),
        })
        assert.equal(await response.text(), body)
        await assert.rejects(undici.fetch(url, {
          integrity: `${algorithm}-${wrong}`, signal: AbortSignal.timeout(5000),
        }), error => error.cause?.message === 'integrity mismatch')
      }
      console.log(`Verified ${consumer}: shared HTTP dispatcher and case-insensitive response integrity`)
    } finally {
      undici.setGlobalDispatcher(previous)
      await dispatcher.close()
      await new Promise((done, reject) => server.close(error => error ? reject(error) : done()))
    }
  }
}
