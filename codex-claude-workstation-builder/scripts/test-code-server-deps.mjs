import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { patchCodeServerDeps, verifyEditorConfigDeps, verifyZod } from '../image/patch-code-server-deps.mjs';

function install(directory, dependencies) {
  fs.mkdirSync(directory, {recursive: true});
  fs.writeFileSync(path.join(directory, 'package.json'), JSON.stringify({name: 'code-server', private: true, dependencies}));
  execFileSync('npm', ['install', '--prefix', directory, '--ignore-scripts', '--package-lock=false',
    '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'], {timeout: 120000, stdio: 'pipe'});
}

function installEditorConfig(extensions) {
  const vsix = process.env.CODE_SERVER_TEST_EDITORCONFIG_VSIX || path.join(path.dirname(extensions), 'editorconfig.vsix');
  if (!process.env.CODE_SERVER_TEST_EDITORCONFIG_VSIX) {
    execFileSync('curl', ['--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
      '--retry', '3', '--connect-timeout', '20', '--max-time', '120', '-fsSLo', vsix,
      'https://open-vsx.org/api/EditorConfig/EditorConfig/0.18.2/file/EditorConfig.EditorConfig-0.18.2.vsix'],
    {timeout: 130000, stdio: 'pipe'});
  }
  assert.equal(createHash('sha256').update(fs.readFileSync(vsix)).digest('hex'),
    'cbc0370ff204bc16d84a3ee6830536fc04355856fa0e895ab064e1a03cfcb84a');
  const directory = path.join(extensions, 'editorconfig.editorconfig-0.18.2-universal');
  execFileSync('python3', ['-c', `
import pathlib, stat, sys, zipfile
source = pathlib.Path(sys.argv[1]).resolve(strict=True)
destination = pathlib.Path(sys.argv[2]).resolve()
assert not destination.exists()
with zipfile.ZipFile(source) as archive:
    members = [entry for entry in archive.infolist() if entry.filename.startswith('extension/') and not entry.is_dir()]
    assert len({entry.filename for entry in members}) == len(members)
    assert 0 < len(members) < 200 and sum(entry.file_size for entry in members) < 1000000
    for entry in members:
        relative = pathlib.PurePosixPath(entry.filename).relative_to('extension')
        assert '..' not in relative.parts and chr(92) not in entry.filename
        assert not stat.S_ISLNK(entry.external_attr >> 16)
        assert (destination / pathlib.Path(*relative.parts)).resolve().is_relative_to(destination)
    print(f'EditorConfig VSIX: source={source}; target={destination}; files={len(members)}; bytes={sum(entry.file_size for entry in members)}', flush=True)
    for entry in members:
        relative = pathlib.PurePosixPath(entry.filename).relative_to('extension')
        target = destination / pathlib.Path(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(archive.read(entry))
`, vsix, directory], {timeout: 15000, stdio: 'inherit'});
  return directory;
}

function treeDigest(directory) {
  const hash = createHash('sha256');
  function visit(relative) {
    const file = path.join(directory, relative);
    const stat = fs.lstatSync(file);
    hash.update(JSON.stringify([relative, stat.mode]));
    if (stat.isSymbolicLink()) hash.update(fs.readlinkSync(file));
    else if (stat.isDirectory()) for (const name of fs.readdirSync(file).sort()) visit(path.join(relative, name));
    else hash.update(fs.readFileSync(file));
  }
  visit('');
  return hash.digest('hex');
}

test('repairs real code-server dependency layouts and preserves the sandbox v3 contract', {timeout: 240000}, () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'code-server-deps-test-'));
  const root = path.join(temporary, 'code-server');
  const staging = path.join(temporary, 'security');
  const extensions = path.join(temporary, 'extensions');
  const editorConfig = path.join(extensions, 'editorconfig.editorconfig-0.18.2-universal');
  const bracePackage = path.join(editorConfig, 'node_modules/editorconfig/node_modules/brace-expansion/package.json');
  const vscode = path.join(root, 'lib/vscode');
  const versions = new Map([
    ['node_modules/body-parser', '2.3.0'],
    ['node_modules/follow-redirects', '1.16.0'],
    ['lib/vscode/node_modules/zod', '4.4.3'],
    ['lib/vscode/node_modules/@github/copilot-sdk/node_modules/zod', '4.3.6'],
    ['lib/vscode/node_modules/@vscode/sandbox-runtime/node_modules/zod', '3.25.76'],
  ]);
  const patch = (requested = 'editorconfig.editorconfig') => patchCodeServerDeps(root, staging, extensions, requested);
  const trees = () => [treeDigest(root), treeDigest(extensions)];
  let originalTrees;
  function unchanged() {
    for (const [relative, version] of versions) {
      assert.equal(JSON.parse(fs.readFileSync(path.join(root, relative, 'package.json'))).version, version);
    }
    assert.equal(JSON.parse(fs.readFileSync(bracePackage)).version, '5.0.5');
    assert.equal(fs.readdirSync(root).some(name => name.startsWith('.release-factory-security-')), false);
    if (originalTrees) assert.deepEqual(trees(), originalTrees, 'rejected input or rollback changed an installed tree');
  }
  try {
    assert.equal(installEditorConfig(extensions), editorConfig);
    install(root, {'body-parser': '2.3.0', 'follow-redirects': '1.16.0', express: '5.2.1'});
    install(vscode, {zod: '4.4.3', 'copilot-zod': 'npm:zod@4.3.6', '@vscode/sandbox-runtime': '0.0.1'});
    const copilot = path.join(vscode, 'node_modules/@github/copilot-sdk/node_modules');
    fs.mkdirSync(copilot, {recursive: true});
    fs.renameSync(path.join(vscode, 'node_modules/copilot-zod'), path.join(copilot, 'zod'));
    unchanged();
    for (const [relative, version] of [...versions].filter(([relative]) => relative.endsWith('/zod'))) {
      assert.throws(() => verifyZod(path.join(root, relative), version.startsWith('3.') ? 'v3' : 'v4'),
        /bounded zod container parsed oversized elements/);
    }
    fs.mkdirSync(staging);
    for (const name of ['package.json', 'package-lock.json']) {
      fs.copyFileSync(new URL('../image/code-server-security/' + name, import.meta.url),
        path.join(staging, name));
    }
    execFileSync('npm', ['ci', '--prefix', staging, '--install-strategy=nested', '--omit=dev',
      '--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'],
    {timeout: 120000, stdio: 'pipe'});
    originalTrees = trees();
    assert.throws(() => verifyEditorConfigDeps(editorConfig), /5\.0\.5/);

    for (const [file, version, expected] of [
      [path.join(editorConfig, 'package.json'), '0.18.3', /unreviewed EditorConfig extension version/],
      [path.join(editorConfig, 'node_modules/editorconfig/package.json'), '3.0.3', /unreviewed editorconfig consumer version/],
      [bracePackage, '5.0.12', /unreviewed brace-expansion version/],
    ]) {
      const original = fs.readFileSync(file);
      fs.writeFileSync(file, JSON.stringify({...JSON.parse(original), version}));
      assert.throws(patch, expected);
      fs.writeFileSync(file, original);
      unchanged();
    }
    const unknownEditorConfig = path.join(extensions, 'editorconfig.editorconfig-0.18.3-universal');
    fs.renameSync(editorConfig, unknownEditorConfig);
    assert.throws(patch, /unreviewed EditorConfig extension layout/);
    fs.renameSync(unknownEditorConfig, editorConfig);
    unchanged();
    const absentEditorConfig = path.join(temporary, 'absent-editorconfig');
    fs.renameSync(editorConfig, absentEditorConfig);
    assert.throws(patch, /requested EditorConfig extension is missing/);
    fs.renameSync(absentEditorConfig, editorConfig);
    unchanged();

    const zodPackage = path.join(vscode, 'node_modules/zod/package.json');
    const originalZod = fs.readFileSync(zodPackage);
    fs.writeFileSync(zodPackage, JSON.stringify({...JSON.parse(originalZod), version: '4.4.2'}));
    assert.throws(patch, /unreviewed zod version/);
    fs.writeFileSync(zodPackage, originalZod);
    unchanged();

    const parser = path.join(root, 'node_modules/body-parser');
    const outside = path.join(temporary, 'outside-body-parser');
    fs.renameSync(parser, outside);
    fs.symlinkSync(outside, parser);
    assert.throws(patch, /unexpected dependency path/);
    fs.unlinkSync(parser);
    fs.renameSync(outside, parser);
    unchanged();

    const brace = path.dirname(bracePackage);
    const outsideBrace = path.join(temporary, 'outside-brace-expansion');
    fs.renameSync(brace, outsideBrace);
    fs.symlinkSync(outsideBrace, brace);
    assert.throws(patch, /unexpected dependency path/);
    fs.unlinkSync(brace);
    fs.renameSync(outsideBrace, brace);
    unchanged();

    // A deliberately mismatched resolved dependency must roll back every replacement.
    const contentTypePackage = path.join(staging, 'node_modules/body-parser/node_modules/content-type/package.json');
    const originalContentType = fs.readFileSync(contentTypePackage);
    fs.writeFileSync(contentTypePackage, JSON.stringify({...JSON.parse(originalContentType), version: '2.0.0'}));
    assert.throws(patch, /2\.0\.0/);
    fs.writeFileSync(contentTypePackage, originalContentType);
    unchanged();

    const balancedPackage = path.join(staging, 'node_modules/brace-expansion/node_modules/balanced-match/package.json');
    const originalBalanced = fs.readFileSync(balancedPackage);
    fs.writeFileSync(balancedPackage, JSON.stringify({...JSON.parse(originalBalanced), version: '4.0.3'}));
    assert.throws(patch, /4\.0\.3/);
    fs.writeFileSync(balancedPackage, originalBalanced);
    unchanged();
    console.log('Verified unknown/missing EditorConfig, unsafe paths and complete rollback without installed-tree changes');

    const lowerLayerDirectories = new Set([...versions.keys()].map(relative => path.join(root, relative)));
    lowerLayerDirectories.add(brace);
    const rename = fs.renameSync;
    try {
      // Reproduce overlayfs: directories from an older image layer cannot be renamed.
      fs.renameSync = (source, destination) => {
        if (lowerLayerDirectories.has(source)) {
          throw Object.assign(new Error('EXDEV: cannot rename an old image-layer directory'), {code: 'EXDEV'});
        }
        return rename(source, destination);
      };
      patch();
    } finally {fs.renameSync = rename;}
    assert.equal(JSON.parse(fs.readFileSync(bracePackage)).version, '5.0.13');
    const sandboxPackage = JSON.parse(fs.readFileSync(path.join(root,
      'lib/vscode/node_modules/@vscode/sandbox-runtime/node_modules/zod/package.json')));
    assert.equal(sandboxPackage.main, './v3/index.cjs');
    assert.equal(sandboxPackage.module, './v3/index.js');
    assert.equal(sandboxPackage.types, './v3/index.d.cts');
    assert.deepEqual(sandboxPackage.exports['.'], sandboxPackage.exports['./v3']);
    const patchedTrees = trees();
    patch();
    assert.deepEqual(trees(), patchedTrees, 'repeated replacement changed an installed tree');
    console.log('Verified content-hash idempotency of code-server and EditorConfig dependency trees');

    // code-server 4.145.2 bundles this newer upstream redirect client.
    install(root, {'body-parser': '2.3.0', 'follow-redirects': '1.16.2', express: '5.2.1'});
    const redirectsPackage = path.join(root, 'node_modules/follow-redirects/package.json');
    const originalRedirects = fs.readFileSync(redirectsPackage);
    fs.writeFileSync(redirectsPackage, JSON.stringify({...JSON.parse(originalRedirects), version: '1.17.0'}));
    assert.throws(patch, /unreviewed follow-redirects version/);
    fs.writeFileSync(redirectsPackage, originalRedirects);
    patch();

    // A custom list that did not request EditorConfig can omit it.
    const beforeOmission = trees();
    fs.renameSync(editorConfig, absentEditorConfig);
    patch('redhat.vscode-yaml');
    fs.renameSync(absentEditorConfig, editorConfig);
    assert.deepEqual(trees(), beforeOmission);
    console.log('Verified custom extension omission remains supported');
  } finally {fs.rmSync(temporary, {recursive: true, force: true});}
});
