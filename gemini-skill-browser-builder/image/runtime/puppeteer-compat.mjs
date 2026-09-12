// Puppeteer 25 replaced the deprecated Browser.isConnected() with .connected.
// Fail closed when upstream changes these call sites, so a new source ref is reviewed.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';

for (const file of ['src/browser.js', 'src/daemon/engine.js', 'src/daemon/handlers.js']) {
  const source = readFileSync(file, 'utf8');
  assert.equal(source.split('.isConnected()').length, 2, `review Puppeteer compatibility in ${file}`);
  writeFileSync(file, source.replace('.isConnected()', '.connected'));
}
