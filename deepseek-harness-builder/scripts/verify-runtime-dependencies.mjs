#!/usr/bin/env node

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { PassThrough } from 'node:stream'
import { execFileSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'

const root = resolve(process.argv[2] ?? '/opt/dsh')
const component = process.argv[3] ?? 'all'
assert.ok(['all', 'zod', 'undici', 'fflate', 'mcp-server', 'cua-profile'].includes(component), 'expected all, zod, undici, fflate, mcp-server or cua-profile')
const consumerRequire = name => createRequire(join(root, 'node_modules', name, 'package.json'))

let hasCuaAdapter = false
if (['all', 'mcp-server', 'cua-profile'].includes(component)) {
  const cli = JSON.parse(readFileSync(join(root, 'node_modules/@deepseek-ai/dsh/package.json'), 'utf8'))
  assert.ok(cli.dependencies && typeof cli.dependencies === 'object' && !Array.isArray(cli.dependencies),
    'DSH CLI must declare its runtime dependencies')
  hasCuaAdapter = Object.hasOwn(cli.dependencies, '@deepseek-ai/dsh-cua-mcp')
  if (hasCuaAdapter) {
    const adapter = JSON.parse(readFileSync(join(root, 'node_modules/@deepseek-ai/dsh-cua-mcp/package.json'), 'utf8'))
    assert.equal(adapter.name, '@deepseek-ai/dsh-cua-mcp', 'the declared CUA adapter must be installed')
  } else {
    console.log('SKIP: DSH CLI does not declare the CUA MCP adapter')
  }
}

if (hasCuaAdapter && (component === 'all' || component === 'mcp-server')) {
  const require = consumerRequire('@deepseek-ai/dsh-cua-mcp')
  const directory = dirname(dirname(require.resolve('@modelcontextprotocol/server')))
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
  for (const mode of ['cjs', 'esm']) {
    const load = entry => mode === 'cjs' ? require(entry) : import(pathToFileURL(entry))
    const { Server } = await load(join(directory, `dist/index.${mode === 'cjs' ? 'cjs' : 'mjs'}`))
    const { StdioServerTransport } = await load(join(directory, `dist/stdio.${mode === 'cjs' ? 'cjs' : 'mjs'}`))
    const connections = []
    const connection = async name => {
      const input = new PassThrough()
      const output = new PassThrough()
      const server = new Server({ name, version: '1.0.0' }, { capabilities: { tools: {} } })
      const transport = new StdioServerTransport(input, output)
      const pending = new Map()
      let buffer = ''
      output.setEncoding('utf8')
      output.on('data', chunk => {
        buffer += chunk
        while (buffer.includes('\n')) {
          const newline = buffer.indexOf('\n')
          const message = JSON.parse(buffer.slice(0, newline))
          buffer = buffer.slice(newline + 1)
          pending.get(message.id)?.(message)
        }
      })
      const request = (id, method, params) => new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error(`MCP stdio request timed out: ${method}`)), 5000)
        pending.set(id, message => {
          clearTimeout(timeout)
          pending.delete(id)
          if (message.error) reject(new Error(JSON.stringify(message.error)))
          else resolve(message.result)
        })
        input.write(JSON.stringify({ jsonrpc: '2.0', id, method, ...(params ? { params } : {}) }) + '\n')
      })
      // The DSH CUA adapter uses the low-level Server and string-method API.
      server.setRequestHandler('tools/list', () => ({
        tools: [{ name: name + '-tool', inputSchema: { type: 'object' } }],
      }))
      connections.push({ server, input, output })
      await server.connect(transport)
      return { server, input, request }
    }
    try {
      const first = await connection('first')
      const second = await connection('second')
      // https://github.com/advisories/GHSA-jm63-cq47-j5jp
      // A shared Server used to replace its connection and mix colliding IDs.
      await assert.rejects(first.server.connect({ async start() {}, async close() {}, async send() {} }),
        /already.connected|ALREADY_CONNECTED/i)
      for (const client of [first, second]) {
        const initialized = await client.request(1, 'initialize', {
          protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'fixture-client', version: '1.0.0' },
        })
        assert.equal(initialized.protocolVersion, '2025-11-25')
        client.input.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')
      }
      const [firstTools, secondTools] = await Promise.all([
        first.request(2, 'tools/list'), second.request(2, 'tools/list'),
      ])
      assert.deepEqual(firstTools.tools.map(tool => tool.name), ['first-tool'])
      assert.deepEqual(secondTools.tools.map(tool => tool.name), ['second-tool'])
      console.log(`Verified MCP server ${manifest.version} ${mode}: isolated stdio connections and tool discovery`)
    } finally {
      for (const { server, input, output } of connections) {
        await server.close()
        input.destroy()
        output.destroy()
      }
    }
  }
}

if (hasCuaAdapter && component === 'cua-profile') {
  const help = execFileSync(process.execPath,
    [join(root, 'node_modules/.bin/dsh'), '--profile', 'cua-mcp', '--help'],
    { encoding: 'utf8', timeout: 30000 })
  assert.ok(help.includes('Serve DeepSeek Harness Computer Use to an MCP client over stdio.'),
    'the compiled CUA profile must load')
  console.log('Verified compiled CUA stdio profile help')
}

if (component === 'all' || component === 'zod') {
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

if (component === 'all' || component === 'undici') {
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

if (component === 'all' || component === 'fflate') {
  const require = consumerRequire('@deepseek-ai/libreoffice-kit')
  const directory = dirname(dirname(require.resolve('fflate')))
  const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
  assert.equal(manifest.name, 'fflate')

  // Keep the stored file tiny. ZIP64 sentinels plus its real footer reach the
  // old parser's unbounded extra-field scan without inflating any large data.
  // https://github.com/advisories/GHSA-px8p-9vwx-vf98
  function zip64Fixture(archive, includeExtra) {
    archive = Buffer.from(archive)
    const end = archive.length - 22
    assert.equal(archive.readUInt32LE(end), 0x06054b50)
    const central = archive.readUInt32LE(end + 16)
    assert.equal(archive.readUInt32LE(central), 0x02014b50)
    assert.equal(archive.readUInt16LE(central + 30), 0)
    assert.equal(archive.readUInt16LE(central + 32), 0)
    const extra = Buffer.alloc(includeExtra ? 28 : 0)
    if (includeExtra) {
      extra.writeUInt16LE(1, 0)
      extra.writeUInt16LE(24, 2)
      extra.writeBigUInt64LE(BigInt(archive.readUInt32LE(central + 24)), 4)
      extra.writeBigUInt64LE(BigInt(archive.readUInt32LE(central + 20)), 12)
      extra.writeBigUInt64LE(BigInt(archive.readUInt32LE(central + 42)), 20)
    }
    const zip = Buffer.concat([archive.subarray(0, end), extra, Buffer.alloc(76), archive.subarray(end)])
    zip.writeUInt16LE(45, central + 6)
    zip.writeUInt32LE(0xffffffff, central + 20)
    zip.writeUInt32LE(0xffffffff, central + 24)
    zip.writeUInt32LE(0xffffffff, central + 42)
    zip.writeUInt16LE(extra.length, central + 30)
    const zip64End = end + extra.length
    zip.writeUInt32LE(0x06064b50, zip64End)
    zip.writeBigUInt64LE(44n, zip64End + 4)
    zip.writeUInt16LE(45, zip64End + 12)
    zip.writeUInt16LE(45, zip64End + 14)
    zip.writeBigUInt64LE(1n, zip64End + 24)
    zip.writeBigUInt64LE(1n, zip64End + 32)
    zip.writeBigUInt64LE(BigInt(archive.readUInt32LE(end + 12) + extra.length), zip64End + 40)
    zip.writeBigUInt64LE(BigInt(central), zip64End + 48)
    zip.writeUInt32LE(0x07064b50, zip64End + 56)
    zip.writeBigUInt64LE(BigInt(zip64End), zip64End + 64)
    zip.writeUInt32LE(1, zip64End + 72)
    const ordinaryEnd = zip64End + 76
    zip.writeUInt16LE(0xffff, ordinaryEnd + 8)
    zip.writeUInt16LE(0xffff, ordinaryEnd + 10)
    zip.writeUInt32LE(0xffffffff, ordinaryEnd + 12)
    zip.writeUInt32LE(0xffffffff, ordinaryEnd + 16)
    return zip
  }

  async function verifyMalformedZip64(entry, mode, zip) {
    // CI uses --input-type=module for stdin; this bounded eval worker is CJS.
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads')
      const { pathToFileURL } = require('node:url')
      ;(async () => {
        const fflate = workerData.mode === 'cjs' ? require(workerData.entry) :
          await import(pathToFileURL(workerData.entry).href)
        parentPort.postMessage({ ready: true })
        try {
          fflate.unzipSync(workerData.zip)
          parentPort.postMessage({ accepted: true })
        } catch (error) {
          parentPort.postMessage({ code: error.code, message: error.message })
        }
      })().catch(error => { throw error })
    `, { eval: true, execArgv: [], workerData: { entry, mode, zip: new Uint8Array(zip) },
      resourceLimits: { maxOldGenerationSizeMb: 64, maxYoungGenerationSizeMb: 8 } })
    let timer
    try {
      const result = await new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error('fflate ZIP64 worker failed to start')), 5000)
        worker.once('error', reject)
        worker.once('exit', code => reject(new Error(`fflate ZIP64 worker exited without a result: ${code}`)))
        worker.on('message', message => {
          if (message.ready) {
            clearTimeout(timer)
            timer = setTimeout(() => reject(new Error('fflate ZIP64 parser exceeded two seconds')), 2000)
          } else resolve(message)
        })
      })
      assert.equal(result.code, 13, 'malformed ZIP64 must be rejected as invalid zip data')
      assert.equal(result.message, 'invalid zip data')
    } finally {
      clearTimeout(timer)
      await worker.terminate()
    }
  }

  for (const [mode, entry] of [['cjs', join(directory, 'lib/node.cjs')], ['esm', join(directory, 'esm/index.mjs')]]) {
    const fflate = mode === 'cjs' ? require(entry) : await import(pathToFileURL(entry))
    const data = fflate.strToU8('deepseek-office-fixture')
    const zip = fflate.zipSync({ 'fixture.txt': [data, { mtime: new Date('2020-01-01T00:00:00Z') }] }, { level: 0 })
    assert.deepEqual(fflate.unzipSync(zip)['fixture.txt'], data)
    assert.deepEqual(fflate.unzipSync(zip64Fixture(zip, true))['fixture.txt'], data)
    await verifyMalformedZip64(entry, mode, zip64Fixture(zip, false))
    console.log(`Verified fflate ${manifest.version} ${mode}: ZIP/ZIP64 roundtrips and bounded malformed ZIP64 rejection`)
  }
}
