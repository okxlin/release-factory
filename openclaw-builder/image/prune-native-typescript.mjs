// The native TypeScript 7 compiler is a development dependency pulled into the
// production pnpm store by optional peers. Keep the TypeScript 5 runtime API.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function pruneNativeTypeScript(root) {
  root = fs.realpathSync(root);
  const modules = path.join(root, 'node_modules');
  const store = path.join(modules, '.pnpm');
  assert.equal(fs.realpathSync(modules), modules, 'node_modules must not be a symlink');
  assert.equal(fs.realpathSync(store), store, 'pnpm store must not be a symlink');
  const entries = fs.readdirSync(store);
  const candidates = entries.filter(name => /^(typescript@7\.|@typescript\+typescript-[a-z0-9-]+@7\.)/.test(name));
  if (!candidates.length) return 0;
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json')));
  for (const section of ['dependencies', 'optionalDependencies']) {
    assert.ok(!manifest[section]?.typescript, 'native TypeScript is now a direct runtime dependency');
  }
  // Validate the entire removal set before touching any files.
  const directories = candidates.map(name => {
    const directory = path.join(store, name);
    assert.equal(fs.realpathSync(directory), directory, 'compiler store entry must not be a symlink');
    const packageName = name.split('@7.')[0].replace('+', '/');
    const packageRoot = path.join(directory, 'node_modules', packageName);
    assert.equal(fs.realpathSync(packageRoot), packageRoot, 'compiler package must not be a symlink');
    const pkg = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json')));
    assert.equal(pkg.name, packageName);
    assert.match(pkg.version, /^7\./);
    return directory;
  });
  const links = [];
  const shims = [];
  const packageNames = [...new Set(candidates.map(name => name.split('@7.')[0].replace('+', '/')))];
  for (const location of [modules, path.join(store, 'node_modules'),
    ...entries.filter(name => name !== 'node_modules' && !candidates.includes(name))
      .map(name => path.join(store, name, 'node_modules'))]) {
    for (const name of packageNames) {
      const alias = path.join(location, name);
      if (!fs.existsSync(alias)) continue;
      assert.equal(fs.realpathSync(path.dirname(alias)), path.dirname(alias), 'dependency directory must not be a symlink');
      const resolved = fs.realpathSync(alias);
      if (!directories.some(directory => resolved.startsWith(directory + path.sep))) continue;
      assert.ok(fs.lstatSync(alias).isSymbolicLink(), 'compiler alias must be a symlink');
      links.push(alias);
      const shim = path.join(location, '.bin/tsc');
      if (name === 'typescript' && fs.existsSync(shim)) {
        assert.equal(fs.realpathSync(path.dirname(shim)), path.dirname(shim), 'binary directory must not be a symlink');
        shims.push(shim);
      }
    }
  }
  console.log(`Prune native TypeScript from ${root}: ${directories.length} package directories, ${links.length} aliases, ${shims.length} launchers`);
  for (const file of [...shims, ...links]) fs.unlinkSync(file);
  for (const directory of directories) fs.rmSync(directory, {recursive: true});
  return directories.length;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  pruneNativeTypeScript(process.argv[2] || '/app');
}
