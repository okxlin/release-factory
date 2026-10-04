// Run inside the candidate image; only container-local loopback sockets are used.
const assert = require('node:assert/strict');
const net = require('node:net');
const {once} = require('node:events');
const {createRequire} = require('node:module');
const requireCodeServer = createRequire('/usr/lib/code-server/package.json');
const {Client, parseList} = requireCodeServer('basic-ftp');
const {getUri} = requireCodeServer('get-uri');
const payload = 'code-server FTP fixture\n';
const valid = '-rw-r--r-- 1 user group 23 Feb 25 2026 fixture.txt';
// Upstream CVE-2026-102990 regression: a valid final line selects the Unix parser.
const hostile = '-rw-r--r-- 1 ' + 'a '.repeat(64 * 1024) + '!\r\n' + valid;
const sockets = new Set();
const dataServers = new Set();
function track(socket) {
  sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
  socket.on('error', () => {});
  return socket;
}
const server = net.createServer(control => {
  track(control);
  control.setEncoding('utf8');
  control.write('220 fixture ready\r\n');
  let pending = '';
  let dataSocket;
  control.on('data', chunk => {
    pending += chunk;
    while (pending.includes('\r\n')) {
      const index = pending.indexOf('\r\n');
      const line = pending.slice(0, index);
      pending = pending.slice(index + 2);
      const verb = line.split(' ')[0];
      if (verb === 'USER') control.write('331 password required\r\n');
      else if (verb === 'PASS') control.write('230 logged in\r\n');
      else if (verb === 'FEAT') control.write('211 End\r\n');
      else if (['TYPE', 'STRU', 'OPTS'].includes(verb)) control.write('200 OK\r\n');
      else if (verb === 'PWD') control.write('257 "/"\r\n');
      else if (verb === 'MDTM') control.write('213 20260225000000\r\n');
      else if (verb === 'EPSV') {
        const data = net.createServer(socket => {
          dataSocket = track(socket);
          data.close();
        });
        dataServers.add(data);
        data.on('close', () => dataServers.delete(data));
        data.listen(0, '127.0.0.1', () => {
          control.write(`229 Entering Extended Passive Mode (|||${data.address().port}|)\r\n`);
        });
      } else if (verb === 'LIST' || verb === 'RETR') {
        assert.ok(dataSocket, 'passive data socket connected');
        control.write('150 opening data connection\r\n');
        dataSocket.end(verb === 'LIST' ? hostile : payload, () => {
          control.write('226 transfer complete\r\n');
        });
      } else if (verb === 'QUIT') control.end('221 goodbye\r\n');
      else control.write('502 unsupported\r\n');
    }
  });
});
(async () => {
  const client = new Client(3000);
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await client.access({host: '127.0.0.1', port});
    assert.deepEqual((await client.list()).map(file => file.name), ['fixture.txt']);
    client.close();
    assert.deepEqual(parseList('x'.repeat(256 * 1024) + '\r\n12-05-96  05:03PM       <DIR>          folder').map(file => file.name), ['folder']);
    // Exercise code-server's existing consumer, not just the replacement module.
    const response = await getUri(`ftp://127.0.0.1:${port}/fixture.txt`);
    const chunks = [];
    for await (const chunk of response) chunks.push(chunk);
    assert.equal(Buffer.concat(chunks).toString(), payload);
    assert.equal(response.lastModified.toISOString(), '2026-02-25T00:00:00.000Z');
    console.log('PASS: FTP listing DoS regression and code-server get-uri download');
  } finally {
    client.close();
    for (const socket of sockets) socket.destroy();
    for (const data of dataServers) data.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
