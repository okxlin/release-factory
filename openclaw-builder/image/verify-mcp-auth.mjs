// Exercise the installed SDK and core using fixtures and loopback HTTP.
// https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-6qxp-vccf-f47h
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [directory, kind, mode = 'cjs'] = process.argv.slice(2);
assert.ok(['cjs', 'esm'].includes(mode));
assert.ok(['sdk', 'client'].includes(kind));
const require = createRequire(path.join(directory, 'package.json'));
const nativeFetch = globalThis.fetch;
const load = file => mode === 'esm' ? import(pathToFileURL(file)) : require(file);
const api = await load(path.join(directory, kind === 'sdk' ? `dist/${mode}/client/auth.js` : `dist/index.${mode === 'esm' ? 'mjs' : 'cjs'}`));
const schemas = kind === 'sdk' ? await load(path.join(directory, `dist/${mode}/shared/auth.js`)) :
  await load(path.join(path.dirname(require.resolve('@modelcontextprotocol/core')), `index.${mode === 'esm' ? 'mjs' : 'cjs'}`));
globalThis.fetch = () => { throw new Error('Unexpected network request in MCP regression'); };
const issuer = 'https://trusted-auth.example';
const attacker = 'https://attacker.example';
const metadata = base => ({
  issuer: base,
  authorization_endpoint: base + '/authorize',
  token_endpoint: base + '/token',
  response_types_supported: ['code'],
  token_endpoint_auth_methods_supported: ['client_secret_basic'],
});
let prepared = 0;
const calls = [];
const provider = {
  clientMetadata: {redirect_uris: [], grant_types: ['client_credentials']},
  clientInformation: () => ({client_id: 'fixture-client', client_secret: 'fixture-secret', issuer}),
  prepareTokenRequest: () => { prepared++; return new URLSearchParams({grant_type: 'client_credentials'}); },
};
const fetchFn = async (url, init) => {
  calls.push({url: String(url), authorization: new Headers(init.headers).get('authorization')});
  return Response.json({access_token: 'fixture-access', token_type: 'Bearer'});
};
// A mismatching issuer must be rejected before request preparation or sending credentials.
await assert.rejects(api.fetchToken(provider, attacker, {metadata: metadata(attacker), fetchFn}),
  /bound to|issuer|authorization server/i);
assert.equal(prepared, 0);
assert.equal(calls.length, 0);
// The same pre-provisioned credentials still work with their legitimate issuer.
const tokens = await api.fetchToken(provider, issuer, {metadata: metadata(issuer), fetchFn});
assert.equal(tokens.access_token, 'fixture-access');
assert.deepEqual(calls, [{url: issuer + '/token', authorization: 'Basic ' + Buffer.from('fixture-client:fixture-secret').toString('base64')}]);
assert.equal(prepared, 1);
// Storage schemas must not silently discard the issuer binding when reloading credentials.
assert.equal(schemas.OAuthTokensSchema.parse({access_token: 'fixture-access', token_type: 'Bearer', issuer}).issuer, issuer);
assert.equal(schemas.OAuthClientInformationSchema.parse({client_id: 'fixture-client', client_secret: 'fixture-secret', issuer}).issuer, issuer);
const {Client} = kind === 'sdk' ? await load(path.join(directory, `dist/${mode}/client/index.js`)) : api;
const client = new Client({name: 'release-factory-fixture', version: '1.0.0'}, {capabilities: {}});
const transport = {
  async start() {},
  async close() { this.onclose?.(); },
  async send(message) {
    if (!('id' in message)) return;
    const result = message.method === 'initialize' ? {
      protocolVersion: message.params.protocolVersion,
      capabilities: {tools: {}}, serverInfo: {name: 'fixture', version: '1.0.0'},
    } : {tools: [{name: 'fixture-tool', inputSchema: {type: 'object'}}]};
    queueMicrotask(() => this.onmessage({jsonrpc: '2.0', id: message.id, result}));
  },
};
try {
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools.map(tool => tool.name), ['fixture-tool']);
} finally {
  await client.close();
}
// A native 307/308 must never forward token credentials, custom headers, or
// session data to another origin, including through a DPoP fetch middleware.
// https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-6prh-2h8m-c8cw
globalThis.fetch = nativeFetch;
const {StreamableHTTPClientTransport} = kind === 'sdk' ?
  await load(path.join(directory, 'dist/' + mode + '/client/streamableHttp.js')) : api;
const {SSEClientTransport} = kind === 'sdk' ?
  await load(path.join(directory, 'dist/' + mode + '/client/sse.js')) : api;
let foreignRequests = 0;
const observed = [];
const observedRequest = (start, path) => {
  const request = observed.slice(start).find(item => item.path === path);
  assert.ok(request, 'MCP regression did not reach its loopback endpoint: ' + path);
  return request;
};
const reply = (request, response) => {
  if (request.url.startsWith('/sse')) {
    response.writeHead(200, {'content-type': 'text/event-stream'});
    response.end('event: endpoint\ndata: /messages\n\n');
  } else {
    response.writeHead(200, {'content-type': 'application/json'});
    response.end(JSON.stringify(request.url.startsWith('/token') ?
      {access_token: 'fixture-access', token_type: 'Bearer'} : {jsonrpc: '2.0', id: 1, result: {}}));
  }
};
const foreign = createServer((request, response) => {
  foreignRequests++;
  request.resume();
  reply(request, response);
});
const listen = server => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const stop = async server => {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
};
await listen(foreign);
const foreignOrigin = 'http://127.0.0.1:' + foreign.address().port;
const trusted = createServer((request, response) => {
  observed.push({path: request.url, dpop: request.headers.dpop, authorization: request.headers.authorization});
  request.resume();
  const status = Number(request.url.split('/')[2]);
  if ([307, 308].includes(status)) {
    response.writeHead(status, {location: foreignOrigin + '/' + request.url.split('/')[1]});
    response.end();
  } else reply(request, response);
});
try {
  await listen(trusted);
  const trustedOrigin = 'http://127.0.0.1:' + trusted.address().port;
  const session = kind === 'client' ? await api.DpopSession.create() : undefined;
  for (const dpop of kind === 'client' ? [false, true] : [false]) {
    const localProvider = {
      ...provider,
      clientInformation: () => ({client_id: 'fixture-client', client_secret: 'fixture-secret', issuer: trustedOrigin}),
      tokens: () => ({access_token: 'fixture-access', token_type: dpop ? 'DPoP' : 'Bearer'}),
      ...(dpop ? {dpop: () => session} : {}),
    };
    const options = {
      authProvider: localProvider,
      requestInit: {redirect: 'follow', headers: {'x-api-key': 'fixture-api-key'}},
      // EventSource has a separate configurable fetch path.
      eventSourceInit: {fetch: nativeFetch},
    };
    for (const status of [307, 308]) {
      const tokenStart = observed.length;
      const tokenMetadata = {...metadata(trustedOrigin), token_endpoint: trustedOrigin + '/token/' + status};
      let tokenRejected = false;
      try { await api.fetchToken(localProvider, trustedOrigin, {metadata: tokenMetadata}); }
      catch { tokenRejected = true; }
      assert.equal(foreignRequests, 0, 'MCP token redirect crossed an origin (' + status + ')');
      assert.equal(tokenRejected, true, 'redirect produced tokens');
      const tokenRequest = observedRequest(tokenStart, '/token/' + status);
      if (dpop) assert.ok(tokenRequest.dpop, 'token request did not exercise DPoP');
      const httpStart = observed.length;
      const http = new StreamableHTTPClientTransport(new URL(trustedOrigin + '/transport/' + status), options);
      try {
        await http.start();
        await assert.rejects(http.send({jsonrpc: '2.0', id: 1, method: 'ping'}));
        assert.equal(foreignRequests, 0, 'MCP HTTP transport forwarded custom headers across origins');
        const httpRequest = observedRequest(httpStart, '/transport/' + status);
        if (dpop) assert.ok(httpRequest.dpop, 'HTTP request did not exercise DPoP');
      } finally { await http.close(); }
      const sseStart = observed.length;
      const sse = new SSEClientTransport(new URL(trustedOrigin + '/sse/' + status), options);
      try {
        await assert.rejects(sse.start());
        assert.equal(foreignRequests, 0, 'MCP EventSource custom fetch crossed an origin');
        const sseRequest = observedRequest(sseStart, '/sse/' + status);
        if (dpop) assert.ok(sseRequest.dpop, 'SSE request did not exercise DPoP');
      } finally { await sse.close(); }
    }
    const successStart = observed.length;
    const tokens = await api.fetchToken(localProvider, trustedOrigin, {metadata: {
      ...metadata(trustedOrigin), token_endpoint: trustedOrigin + '/token/ok',
    }});
    assert.equal(tokens.access_token, 'fixture-access', 'legitimate token request failed');
    assert.equal(observedRequest(successStart, '/token/ok').authorization,
      'Basic ' + Buffer.from('fixture-client:fixture-secret').toString('base64'));
    const http = new StreamableHTTPClientTransport(new URL(trustedOrigin + '/transport/ok'), options);
    try {
      await http.start();
      await http.send({jsonrpc: '2.0', id: 1, method: 'ping'});
    } finally { await http.close(); }
    const sseStart = observed.length;
    const sse = new SSEClientTransport(new URL(trustedOrigin + '/sse/ok'), options);
    try {
      await sse.start();
      await sse.send({jsonrpc: '2.0', id: 1, method: 'ping'});
      for (const endpoint of ['/sse/ok', '/messages']) {
        const request = observedRequest(sseStart, endpoint);
        assert.equal(request.authorization, (dpop ? 'DPoP' : 'Bearer') + ' fixture-access');
        if (dpop) assert.ok(request.dpop, 'legitimate SSE request did not exercise DPoP');
      }
    } finally { await sse.close(); }
  }
} finally {
  await stop(trusted);
  await stop(foreign);
}
const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
console.log(`Verified MCP OAuth issuer binding: ${pkg.name} ${pkg.version} (${mode})`);
