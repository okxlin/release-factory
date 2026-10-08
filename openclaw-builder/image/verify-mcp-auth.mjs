// Exercise the installed SDK, including its actual core dependency, without network I/O.
// https://github.com/modelcontextprotocol/typescript-sdk/security/advisories/GHSA-6qxp-vccf-f47h
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [directory, kind, mode = 'cjs'] = process.argv.slice(2);
assert.ok(['cjs', 'esm'].includes(mode));
assert.ok(['sdk', 'client'].includes(kind));
const require = createRequire(path.join(directory, 'package.json'));
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
const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json')));
console.log(`Verified MCP OAuth issuer binding: ${pkg.name} ${pkg.version} (${mode})`);
