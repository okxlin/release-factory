#!/usr/bin/env python3
"""Run offline consumer regressions against an explicitly selected source tree."""

import argparse
import contextlib
import io
import json
import os
import stat
import tempfile
from pathlib import Path
import sys
import tarfile
import unicodedata
import unittest
from unittest.mock import Mock, patch
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, required=True)
parser.add_argument('--work-root', type=Path, required=True)
parser.add_argument('--phase', choices=['red', 'green'], required=True)
args = parser.parse_args()
SOURCE = args.source_root.resolve(strict=True)
if SOURCE.is_file():
    assert SOURCE.name == 'setuptools-68.1.2-py3-none-any.whl'
    wheel_stage = tempfile.TemporaryDirectory(prefix='release-factory-setuptools-wheel-')
    destination = Path(wheel_stage.name).resolve(strict=True)
    with zipfile.ZipFile(SOURCE) as archive:
        members = archive.infolist()
        assert 0 < len(members) < 500 and sum(entry.file_size for entry in members) < 20000000
        paths = []
        for entry in members:
            relative = Path(entry.filename)
            assert not relative.is_absolute() and '..' not in relative.parts and chr(92) not in entry.filename
            assert not stat.S_ISLNK(entry.external_attr >> 16)
            path = (destination / relative).resolve()
            assert path.is_relative_to(destination)
            paths.append(path)
        assert len(paths) == len(set(paths)) and archive.testzip() is None
        print(json.dumps({'wheel': str(SOURCE), 'extraction_root': str(destination),
                          'entries': len(members), 'bytes': sum(entry.file_size for entry in members)}), flush=True)
        for entry, path in zip(members, paths):
            if entry.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('xb') as output:
                    output.write(archive.read(entry))
    SOURCE = destination
WORK = args.work_root.resolve()
assert not WORK.exists() and WORK.parent.is_dir(), 'use an empty, new fixture root'
assert WORK != SOURCE and SOURCE not in WORK.parents and WORK not in SOURCE.parents
WORK.mkdir()
sys.dont_write_bytecode = True
os.environ['SETUPTOOLS_USE_DISTUTILS'] = 'local'
sys.path.insert(0, str(SOURCE))
import setuptools
from setuptools import build_meta
from setuptools.command.egg_info import FileList, translate_pattern
from setuptools.package_index import PackageIndex
import setuptools.wheel as wheel_module
from setuptools.wheel import Wheel

for module in (setuptools, build_meta, wheel_module):
    assert Path(module.__file__).resolve().is_relative_to(SOURCE), module.__file__


def make_wheel(path, namespace, payload=False):
    metadata = 'demo_pkg-1.0.dist-info'
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr(f'{metadata}/WHEEL', 'Wheel-Version: 1.0\nGenerator: bounded-fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n')
        archive.writestr(f'{metadata}/METADATA', 'Metadata-Version: 2.1\nName: demo-pkg\nVersion: 1.0\n')
        archive.writestr(f'{metadata}/namespace_packages.txt', namespace + '\n')
        archive.writestr('demo_pkg/__init__.py', '')
        if payload:
            archive.writestr('ns/pkg/data.txt', 'legitimate')


class ManifestBoundary(unittest.TestCase):
    def test_translate_pattern_both_unicode_forms(self):
        nfc = unicodedata.normalize('NFC', 'café.txt')
        nfd = unicodedata.normalize('NFD', 'café.txt')
        self.assertNotEqual(nfc, nfd)
        self.assertIsNotNone(translate_pattern(nfc).match(nfd))
        self.assertIsNotNone(translate_pattern(nfd).match(nfc))

    def test_all_four_unicode_exclusion_directives(self):
        nfc = 'café.txt'
        nfd = unicodedata.normalize('NFD', nfc)
        for method, parameters, candidate in [
            ('exclude', ('app/' + nfc,), 'app/' + nfd),
            ('global_exclude', (nfc,), 'app/' + nfd),
            ('recursive_exclude', ('app', nfc), 'app/' + nfd),
            ('prune', ('café',), unicodedata.normalize('NFD', 'café') + '/secret.txt'),
        ]:
            with self.subTest(method=method):
                files = FileList()
                files.files = [candidate, 'keep.txt']
                self.assertTrue(getattr(files, method)(*parameters))
                self.assertEqual(files.files, ['keep.txt'])

    def test_ascii_exclusion_and_unmatched_inclusion_controls(self):
        files = FileList()
        files.files = ['nested/control.txt', 'keep.txt']
        self.assertTrue(files.global_exclude('control.txt'))
        self.assertEqual(files.files, ['keep.txt'])
        self.assertIsNone(translate_pattern('*.txt').match('keep.py'))

    def test_pep517_sdist_excludes_nfd_secret_and_ascii_control(self):
        project = WORK / 'sdist-fixture'
        project.mkdir()
        (project / 'setup.py').write_text("from setuptools import setup\nsetup(name='unicode-fixture', version='1.0', py_modules=['plain'])\n", encoding='utf-8')
        (project / 'plain.py').write_text('answer = 42\n', encoding='utf-8')
        (project / 'README.md').write_text('Offline fixture.\n', encoding='utf-8')
        nfc = 'secret_café.txt'
        nfd = unicodedata.normalize('NFD', nfc)
        (project / nfd).write_text('dummy secret\n', encoding='utf-8')
        (project / 'control.txt').write_text('dummy ASCII secret\n', encoding='utf-8')
        (project / 'MANIFEST.in').write_text(f'global-include *.txt\nglobal-exclude {nfc}\nglobal-exclude control.txt\n', encoding='utf-8')
        previous = Path.cwd()
        try:
            os.chdir(project)
            with contextlib.redirect_stdout(io.StringIO()):
                name = build_meta.build_sdist(str(project / 'dist'))
        finally:
            os.chdir(previous)
        with tarfile.open(project / 'dist' / name, 'r:gz') as archive:
            names = {unicodedata.normalize('NFC', Path(n).name) for n in archive.getnames()}
        self.assertIn('plain.py', names)
        self.assertNotIn('control.txt', names)
        self.assertNotIn(nfc, names)


class WheelBoundary(unittest.TestCase):
    def test_install_as_egg_rejects_posix_absolute_namespace(self):
        case = WORK / 'absolute-wheel'
        case.mkdir()
        outside = case / 'outside'
        outside.mkdir()
        canary = outside / 'canary.txt'
        canary.write_bytes(b'unchanged')
        path = case / 'demo_pkg-1.0-py3-none-any.whl'
        make_wheel(path, str(outside))
        with self.assertRaisesRegex(ValueError, 'invalid namespace package name'):
            Wheel(str(path)).install_as_egg(str(case / 'destination'))
        self.assertFalse((outside / '__init__.py').exists())
        self.assertEqual(canary.read_bytes(), b'unchanged')

    def test_install_as_egg_accepts_dotted_namespaces(self):
        case = WORK / 'legitimate-wheel'
        case.mkdir()
        path = case / 'demo_pkg-1.0-py3-none-any.whl'
        make_wheel(path, 'ns ns.pkg', payload=True)
        destination = case / 'destination'
        Wheel(str(path)).install_as_egg(str(destination))
        self.assertEqual((destination / 'ns/pkg/data.txt').read_text(), 'legitimate')
        self.assertEqual((destination / 'ns/pkg/__init__.py').read_text(), wheel_module.NAMESPACE_PACKAGE_INIT)
        self.assertTrue((destination / 'EGG-INFO/PKG-INFO').is_file())

    def test_install_as_egg_rejects_namespace_symlink_escape(self):
        case = WORK / 'symlink-wheel'
        case.mkdir()
        outside = case / 'outside'
        outside.mkdir()
        destination = case / 'destination'
        destination.mkdir()
        (destination / 'ns').symlink_to(outside, target_is_directory=True)
        path = case / 'demo_pkg-1.0-py3-none-any.whl'
        make_wheel(path, 'ns')
        with self.assertRaisesRegex(ValueError, 'invalid namespace package name'):
            Wheel(str(path)).install_as_egg(str(destination))
        self.assertFalse((outside / '__init__.py').exists())

    def test_pep517_suppresses_legacy_setup_requires_installation(self):
        installer = Mock(side_effect=AssertionError('unexpected legacy installation'))
        with patch.object(setuptools, '_install_setup_requires', installer):
            with build_meta.no_install_setup_requires():
                setuptools._install_setup_requires({'setup_requires': ['offline-fixture']})
            installer.assert_not_called()
            self.assertIs(setuptools._install_setup_requires, installer)

    @unittest.skipUnless(args.phase == 'green', 'new helper boundary applies after backport')
    def test_helper_rejects_all_upstream_invalid_name_classes(self):
        for mod in ('/tmp/outside', r'C:\Windows', r'\\server\share', 'foo/../../evil', '..', ''):
            with self.subTest(mod=mod):
                with self.assertRaisesRegex(ValueError, 'invalid namespace package name'):
                    wheel_module._resolve_namespace_dir(str(WORK / 'helper-destination'), mod)
        self.assertEqual(wheel_module._resolve_namespace_dir(str(WORK), 'ns.pkg'), str(WORK / 'ns/pkg'))


class UbuntuHighBackport(unittest.TestCase):
    def test_already_fixed_download_boundary(self):
        root = str(WORK / 'download-root')
        self.assertEqual(PackageIndex._resolve_download_filename('https://example.test/pkg-1.0.tar.gz', root), str(Path(root) / 'pkg-1.0.tar.gz'))
        with self.assertRaisesRegex(ValueError, 'Invalid filename'):
            PackageIndex._resolve_download_filename('https://example.test/%2ftmp%2foutside', root)


print(json.dumps({'phase': args.phase, 'python': sys.version, 'source_root': str(SOURCE), 'work_root': str(WORK), 'setuptools_version': setuptools.__version__}, indent=2))
suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in (ManifestBoundary, WheelBoundary, UbuntuHighBackport))
result = unittest.TextTestRunner(verbosity=2).run(suite)
summary = {'tests_run': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'skipped': len(result.skipped), 'successful': result.wasSuccessful()}
(WORK / 'test-result.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
print(json.dumps(summary))
sys.exit(0 if result.wasSuccessful() else 1)
