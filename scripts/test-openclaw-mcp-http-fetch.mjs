import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchMcpHttpFetch } from '../openclaw-builder/image/patch-vendored-deps.mjs';

// Bind the executable upstream fixture to the reviewed OpenClaw release.
const revision = '847611dcaa3bf0e2783335f961dd1fd0580e4d9f';
const sources = {
  'src/agents/mcp-http-fetch.ts': 'f144f2e0707d4a81077c759b5cfc3dd9fa432fc6c5317c3599ee9462d8866f26',
  'src/infra/net/fetch-guard.ts': '03843d1c80972be77675903b6b90db065b9627f364fc08672d5e1378a3b87a9b',
  'src/infra/net/redirect-headers.ts': 'edd641d428ff0fd5c051d9f6d16bc12b526e8c16ea0dae90e252ea2a5972eefd',
};

async function copyReviewedSources(root) {
  // Local diagnosis reuses the exact raw bytes already retrieved for the audit.
  // CI retrieves only these three small files from the fixed commit.
  const evidence = process.env.OPENCLAW_MCP_SOURCE_EVIDENCE ?
    JSON.parse(fs.readFileSync(process.env.OPENCLAW_MCP_SOURCE_EVIDENCE)) : undefined;
  if (evidence) assert.equal(evidence.revision, revision);
  await Promise.all(Object.entries(sources).map(async ([relative, sha256]) => {
    let bytes;
    if (evidence) {
      const entry = evidence.sources.find(item => item.path === relative);
      assert.ok(entry, 'missing reviewed MCP source: ' + relative);
      bytes = Buffer.from(entry.raw_bytes_base64, 'base64');
    } else {
      const response = await fetch('https://raw.githubusercontent.com/openclaw/openclaw/' + revision + '/' + relative,
        {redirect: 'error', signal: AbortSignal.timeout(30000)});
      assert.equal(response.status, 200);
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        assert.ok(size <= 64 * 1024, 'MCP fixture source exceeds expected size');
        chunks.push(chunk);
      }
      bytes = Buffer.concat(chunks);
    }
    assert.ok(bytes.length <= 64 * 1024);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), sha256, 'unreviewed MCP fixture source');
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, bytes);
  }));
}

// Isolate transport admission and lifecycle helpers, not the redirect loop.
// These fixtures permit only loopback and do not prove production SSRF policy.
const fixtureModules = {
  'node_modules/@openclaw/normalization-core/package.json':
    '{"name":"@openclaw/normalization-core","type":"module","exports":{"./promise-like":"./promise-like.js"}}\n',
  'node_modules/@openclaw/normalization-core/promise-like.js':
    'export const isPromiseLike = value => value != null && typeof value.then === "function";\n',
  'src/logger.js': 'export const logWarn = () => {};\n',
  'src/shared/effect-authority.js':
    'export const captureEffectAuthority = () => ({initiate: invoke => invoke()});\n',
  'src/utils/fetch-timeout.js': `
    export const buildTimeoutAbortSignal = ({signal, timeoutMs}) => ({
      signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(timeoutMs ?? 10000)]),
      cleanup() {}, refresh() {},
    });
  `,
  'src/infra/fetch-headers.js': `
    export const normalizeHeadersInitForFetch = headers => new Headers(headers);
    export const normalizeRequestInitHeadersForFetch = init => init ? {
      ...init, ...(init.headers ? {headers: new Headers(init.headers)} : {}),
    } : init;
  `,
  'src/infra/http-body.js': `
    export const cancelUnreadResponseBody = async response => {
      if (response?.body && !response.bodyUsed) await response.body.cancel().catch(() => {});
    };
  `,
  'src/infra/net/configured-local-origin-bypass.js': `
    const unexpected = () => { throw new Error('unexpected managed proxy in MCP fixture'); };
    export const shouldUseConfiguredLocalOriginManagedProxyBypass = unexpected;
    export const shouldResolveConfiguredLocalOriginManagedProxyBypass = unexpected;
  `,
  'src/infra/net/fetch-request-authority.js':
    'export const captureGuardedFetchRequestAuthority = () => undefined;\n',
  'src/infra/net/guarded-body-stream.js': `
    export const responseWithAbortSignal = response => response;
    export function wrapGuardedBodyStream({body, cleanup}) {
      const reader = body.getReader();
      return new ReadableStream({
        async pull(controller) {
          try {
            const {done, value} = await reader.read();
            if (done) { controller.close(); await cleanup(); }
            else controller.enqueue(value);
          } catch (error) { controller.error(error); await cleanup(); }
        },
        async cancel(reason) { await reader.cancel(reason); await cleanup(); },
      });
    }
  `,
  'src/infra/net/pinned-dispatcher-pool.js':
    'export class PinnedDispatcherPool { constructor() { throw new Error("unexpected dispatcher pool"); } }\n',
  'src/infra/net/proxy-env.js': 'export const shouldUseEnvHttpProxyForUrl = () => false;\n',
  'src/infra/net/runtime-fetch.js': `
    export const isMockedFetch = () => false;
    export const fetchWithRuntimeDispatcher = () => { throw new Error('unexpected runtime dispatcher'); };
  `,
  'src/infra/net/ssrf.js': `
    import assert from 'node:assert/strict';
    export class SsrFBlockedError extends Error {}
    export const assertHostnameAllowedWithPolicy = hostname => assert.equal(hostname, '127.0.0.1');
    export const resolveSsrFPolicyForUrl = url => {
      assert.equal(url.protocol, 'http:');
      assertHostnameAllowedWithPolicy(url.hostname);
      return undefined;
    };
    export const ssrfPolicyFromHttpBaseUrlAllowedOrigin = url => resolveSsrFPolicyForUrl(new URL(url));
    export const resolvePinnedHostnameWithPolicy = async hostname => {
      assertHostnameAllowedWithPolicy(hostname);
      return {hostname, addresses: ['127.0.0.1']};
    };
    export const matchesHostnameAllowlist = (hostname, allowed) => allowed.includes(hostname);
    export const createPinnedDispatcher = () => null;
    export const closeDispatcher = async () => {};
  `,
  'src/infra/net/undici-dispatcher-options.js':
    'export const globalUndiciStreamTimeoutMs = undefined;\n',
  'src/infra/net/undici-family-policy.js':
    'export const resolveUndiciAutoSelectFamilyConnectOptions = () => undefined;\n',
  'src/infra/net/undici-runtime.js': `
    export const loadUndiciRuntimeDeps = () => ({fetch: globalThis.fetch});
    const unexpected = () => { throw new Error('unexpected proxy/HTTP1 agent in MCP fixture'); };
    export const createHttp1Agent = unexpected;
    export const createHttp1EnvHttpProxyAgent = unexpected;
    export const createHttp1ProxyAgent = unexpected;
  `,
};

function compileFixture(root) {
  for (const relative of Object.keys(sources)) {
    const file = path.join(root, relative);
    fs.writeFileSync(file.slice(0, -3) + '.js',
      stripTypeScriptTypes(fs.readFileSync(file, 'utf8'), {sourceUrl: file}));
  }
}

// Execute in a fresh process after recompiling, so a source patch cannot be
// hidden by Node's module cache. Both servers use real loopback sockets.
async function exerciseBodyRedirects() {
  const assert = (await import('node:assert/strict')).default;
  const {createServer} = await import('node:http');
  const {buildMcpHttpFetch} = await import('./src/agents/mcp-http-fetch.js');
  const sdk = {
    ...(await import('tested-sdk/client/index.js')),
    ...(await import('tested-sdk/client/streamableHttp.js')),
    ...(await import('tested-sdk/client/sse.js')),
  };
  const apis = {sdk, client: await import('tested-client')};
  const mode = process.argv[2];
  assert.ok(['native', 'replay', 'reject'].includes(mode));
  const configurations = new Map();
  const streams = new Map();
  const trustedRequests = [];
  const foreignRequests = [];
  const failures = [];
  let counter = 0;
  let foreignOrigin;
  const listen = server => new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const stop = async server => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  };
  const readRequest = async request => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    return {path: request.url, method: request.method, headers: request.headers,
      message: body ? JSON.parse(body) : undefined};
  };
  const resultFor = message => message.method === 'initialize' ? {
    protocolVersion: message.params.protocolVersion,
    capabilities: {tools: {}}, serverInfo: {name: 'fixture', version: '1.0.0'},
  } : message.method === 'tools/list' ? {
    tools: [{name: 'fixture-tool', inputSchema: {type: 'object', properties: {privateValue: {type: 'string'}}}}],
  } : {content: [{type: 'text', text: 'fixture-ok'}]};
  const reply = (record, response, id) => {
    const config = configurations.get(id);
    assert.ok(config, 'unexpected MCP fixture request');
    const message = record.message;
    if (message?.id === undefined) {
      response.writeHead(202);
      response.end();
      return;
    }
    const bytes = JSON.stringify({jsonrpc: '2.0', id: message.id, result: resultFor(message)});
    if (config.transport === 'sse') {
      const stream = streams.get(id);
      assert.ok(stream, 'SSE fixture has no active endpoint stream');
      response.writeHead(202);
      response.end();
      stream.write('event: message\ndata: ' + bytes + '\n\n');
    } else {
      response.writeHead(200, {'content-type': 'application/json'});
      response.end(bytes);
    }
  };
  const handler = (foreign, records) => (request, response) => {
    void (async () => {
      const record = await readRequest(request);
      records.push(record);
      const id = request.url.split('/').at(-1);
      const config = configurations.get(id);
      assert.ok(config);
      if (!foreign && request.method === 'GET' && request.url.startsWith('/sse/')) {
        streams.set(id, response);
        response.once('close', () => streams.delete(id));
        response.writeHead(200, {'content-type': 'text/event-stream'});
        response.write('event: endpoint\ndata: /messages/' + id + '\n\n');
      } else if (!foreign && record.message?.method === 'tools/call' &&
          !request.url.startsWith('/finish/') && config.destination !== 'ok') {
        response.writeHead(config.status, {
          location: (config.destination === 'cross' ? foreignOrigin : '') + '/finish/' + id,
        });
        response.end();
      } else reply(record, response, id);
    })().catch(error => {
      console.error(error);
      response.writeHead(500);
      response.end();
    });
  };
  const foreign = createServer(handler(true, foreignRequests));
  const trusted = createServer(handler(false, trustedRequests));
  try {
    await listen(foreign);
    foreignOrigin = 'http://127.0.0.1:' + foreign.address().port;
    await listen(trusted);
    const trustedOrigin = 'http://127.0.0.1:' + trusted.address().port;
    for (const [kind, api] of Object.entries(apis)) {
      for (const transportKind of ['http', 'sse']) {
        for (const destination of ['ok', 'same', 'cross']) {
          for (const status of destination === 'ok' ? [200] : [307, 308]) {
            const id = String(++counter);
            const privateValue = 'fixture-private-tool-argument-' + id;
            configurations.set(id, {transport: transportKind, destination, status});
            const url = new URL(trustedOrigin + '/' + transportKind + '/' + id);
            const fetch = mode === 'native' ? globalThis.fetch :
              buildMcpHttpFetch({resourceUrl: url.toString(), timeoutMs: 10000});
            const options = {
              fetch,
              eventSourceInit: {fetch},
              requestInit: {redirect: 'follow', headers: {
                authorization: 'Bearer fixture-access', 'x-api-key': 'fixture-api-key',
                dpop: 'fixture-dpop', 'mcp-session-id': 'fixture-session',
              }},
            };
            const transport = transportKind === 'http' ?
              new api.StreamableHTTPClientTransport(url, options) : new api.SSEClientTransport(url, options);
            const client = new api.Client({name: 'release-factory-loopback', version: '1.0.0'}, {capabilities: {}});
            let rejected = false;
            let result;
            try {
              await client.connect(transport);
              await client.listTools();
              try {
                result = await client.callTool({name: 'fixture-tool', arguments: {privateValue}},
                  undefined, {timeout: 5000});
              } catch (error) {
                rejected = true;
                assert.match(String(error), /cross-origin|redirect|30[78]/i, 'unrelated tool failure');
              }
            } finally { await client.close(); }
            const sourceCall = trustedRequests.find(record => record.path.endsWith('/' + id) &&
              record.message?.method === 'tools/call');
            assert.ok(sourceCall, 'private tool call never reached the trusted endpoint');
            assert.equal(sourceCall.message.params.arguments.privateValue, privateValue);
            const received = foreignRequests.filter(record => record.path.endsWith('/' + id));
            for (const record of received) {
              assert.equal(record.method, 'POST');
              assert.equal(record.message.params.arguments.privateValue, privateValue);
              for (const header of ['authorization', 'x-api-key', 'dpop', 'mcp-session-id']) {
                assert.equal(record.headers[header], undefined, 'sensitive redirect header was retained');
              }
            }
            console.log(JSON.stringify({mode, kind, transport: transportKind, destination, status,
              rejected, foreignRequests: received.length, privateBodyReceived: received.length > 0}));
            if (destination === 'cross' && mode !== 'replay') {
              if (received.length !== 0 || !rejected) failures.push({kind, transport: transportKind, status,
                foreignRequests: received.length, rejected});
            } else {
              assert.equal(rejected, false, 'legitimate or unsafe-control tool call failed');
              assert.equal(result.content[0].text, 'fixture-ok');
              if (destination === 'cross') assert.equal(received.length, 1, 'unsafe source control did not replay its body');
              if (destination === 'same') {
                const final = trustedRequests.find(record => record.path === '/finish/' + id);
                assert.ok(final, 'same-origin redirect did not reach its endpoint');
                assert.equal(final.message.params.arguments.privateValue, privateValue);
                assert.equal(final.headers.authorization, 'Bearer fixture-access');
              }
            }
          }
        }
      }
    }
    assert.deepEqual(failures, [], 'OpenClaw custom fetch replayed private MCP tool arguments across origins');
    console.log('Verified actual MCP Client.callTool body redirects: ' + mode);
  } finally {
    await stop(trusted);
    await stop(foreign);
  }
}

function runFixture(root, mode) {
  return spawnSync(process.execPath, [path.join(root, 'experiment.mjs'), mode], {
    encoding: 'utf8', timeout: 45000,
    env: {...process.env, OPENCLAW_PROXY_ACTIVE: '', OPENCLAW_DEBUG_PROXY_ENABLED: ''},
  });
}

test('blocks private tool body replay through the actual OpenClaw HTTP/SSE fetch', {timeout: 180000}, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openclaw-mcp-fetch-'));
  try {
    fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({private: true, type: 'module', dependencies: {
      'tested-sdk': 'npm:@modelcontextprotocol/sdk@1.32.2',
      'tested-client': 'npm:@modelcontextprotocol/client@2.4.0',
    }}));
    execFileSync('npm', ['install', '--prefix', root, '--ignore-scripts', '--package-lock=false',
      '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
    await copyReviewedSources(root);
    for (const [relative, content] of Object.entries(fixtureModules)) {
      const file = path.join(root, relative);
      fs.mkdirSync(path.dirname(file), {recursive: true});
      fs.writeFileSync(file, content);
    }
    fs.writeFileSync(path.join(root, 'experiment.mjs'),
      '(' + exerciseBodyRedirects.toString() + ')().catch(error => { console.error(error); process.exitCode = 1; });\n');
    compileFixture(root);
    const native = runFixture(root, 'native');
    assert.equal(native.error, undefined, native.error?.message);
    assert.equal(native.status, 0, native.stderr || native.stdout);
    assert.match(native.stdout, /Verified actual MCP Client.callTool body redirects: native/);
    console.log(native.stdout.trim());

    const replay = runFixture(root, 'replay');
    assert.equal(replay.error, undefined, replay.error?.message);
    assert.equal(replay.status, 0, replay.stderr || replay.stdout);
    assert.match(replay.stdout, /Verified actual MCP Client.callTool body redirects: replay/);
    console.log(replay.stdout.trim());

    const file = path.join(root, 'src/agents/mcp-http-fetch.ts');
    const original = fs.readFileSync(file);
    const drifted = Buffer.concat([original, Buffer.from('// source drift\n')]);
    fs.writeFileSync(file, drifted);
    assert.throws(() => patchMcpHttpFetch(root), /unreviewed MCP HTTP fetch source/);
    assert.deepEqual(fs.readFileSync(file), drifted, 'unreviewed source was partially patched');
    fs.writeFileSync(file, original);
    const linkedFile = path.join(root, 'linked-source.ts');
    fs.renameSync(file, linkedFile);
    fs.symlinkSync(linkedFile, file);
    assert.throws(() => patchMcpHttpFetch(root), /unexpected MCP HTTP fetch source path/);
    assert.deepEqual(fs.readFileSync(linkedFile), original, 'symlink target was changed');
    fs.unlinkSync(file);
    fs.renameSync(linkedFile, file);
    patchMcpHttpFetch(root);
    const patched = fs.readFileSync(file);
    patchMcpHttpFetch(root);
    assert.deepEqual(fs.readFileSync(file), patched, 'MCP HTTP fetch patch is not idempotent');
    compileFixture(root);
    const hardened = runFixture(root, 'reject');
    console.log(hardened.stdout.trim());
    assert.equal(hardened.error, undefined, hardened.error?.message);
    assert.equal(hardened.status, 0, hardened.stderr || hardened.stdout);
    assert.match(hardened.stdout, /Verified actual MCP Client.callTool body redirects: reject/);
  } finally {
    fs.rmSync(root, {recursive: true});
  }
});
