#!/usr/bin/env python3
"""Backport two upstream fixes to exact Ubuntu 68.1.2-2ubuntu1.2 sources.

CVE-2026-59890: https://github.com/pypa/setuptools/commit/dd9f436a36486b4cb8a4c70a2321548b0be09b8f
GHSA-xmj3-9gf7-h52w: https://github.com/pypa/setuptools/commit/6d07b8d17890dda58d944ac51e58f54af92d52af
"""

import argparse
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import zipfile


MATCHER = '''class _NormalizedMatcher:
    """Match manifest paths in canonical Unicode form (CVE-2026-59890)."""

    def __init__(self, pattern: re.Pattern) -> None:
        self._pattern = pattern

    def match(self, path):
        return self._pattern.match(unicode_utils.normalize(path))

    def search(self, path):
        return self._pattern.search(unicode_utils.normalize(path))


'''

NORMALIZE = '''def normalize(text):
    """Return canonical NFC text (CVE-2026-59890)."""
    return unicodedata.normalize('NFC', text) if isinstance(text, str) else text


'''

NAMESPACE = '''def _resolve_namespace_dir(destination_eggdir, mod):
    """Resolve a dotted module inside the egg (GHSA-xmj3-9gf7-h52w)."""
    parts = mod.split('.')
    if not all(part.isidentifier() for part in parts):
        raise ValueError(f"invalid namespace package name: {mod!r}")
    dest = os.path.join(destination_eggdir, *parts)
    root = os.path.realpath(destination_eggdir)
    if not os.path.realpath(dest).startswith(os.path.join(root, '')):
        raise ValueError(f"invalid namespace package name: {mod!r}")
    return dest


'''

PATCHES = {
    'setuptools/command/egg_info.py': (
        '3eb6ba1c0903a524e038ce7408352b5a7c1a00d5dd62e6460cba72d7c859b8d5',
        [
            ('def translate_pattern(glob):', MATCHER + 'def translate_pattern(glob):'),
            ("    pat = ''\n", "    pat = ''\n    glob = unicode_utils.normalize(glob)\n"),
            (
                'return re.compile(pat, flags=re.MULTILINE | re.DOTALL)',
                'return _NormalizedMatcher(re.compile(pat, flags=re.MULTILINE | re.DOTALL))',
            ),
        ],
    ),
    'setuptools/unicode_utils.py': (
        '68e385a38246c00b2206db46603b2a152ed8a9641e6768fa0d6882b9cb51ff4d',
        [('def filesys_decode(path):', NORMALIZE + 'def filesys_decode(path):')],
    ),
    'setuptools/wheel.py': (
        '36862e1f36da8cd1a6f67fc999ae2aebeb34ca38e052be9468e02b05252f08b3',
        [
            ('class Wheel:', NAMESPACE + 'class Wheel:'),
            (
                "mod_dir = os.path.join(destination_eggdir, *mod.split('.'))",
                'mod_dir = _resolve_namespace_dir(destination_eggdir, mod)',
            ),
        ],
    ),
}
HIGH_PATH = 'setuptools/package_index.py'
HIGH_HASH = 'b5324e4c217dc49d3fa22d13b552a2106394003bd4b08ba6c815e1de4ff341d1'
RECORD = 'setuptools-68.1.2.dist-info/RECORD'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def convert(name, data):
    expected, substitutions = PATCHES[name]
    text = data.decode('utf-8')
    if sha(data) == expected:
        for before, after in substitutions:
            if text.count(before) != 1:
                raise ValueError(f'{name}: expected one source anchor')
            text = text.replace(before, after, 1)
        return text.encode('utf-8')
    original = text
    for before, after in reversed(substitutions):
        if original.count(after) != 1:
            raise ValueError(f'{name}: unknown source identity')
        original = original.replace(after, before, 1)
    if sha(original.encode('utf-8')) != expected:
        raise ValueError(f'{name}: source drift outside this backport')
    return data


def check_record(archive):
    names = [info.filename for info in archive.infolist()]
    if len(names) != len(set(names)) or archive.testzip() is not None:
        raise ValueError('wheel contains duplicate entries or corrupt data')
    rows = list(csv.reader(io.StringIO(archive.read(RECORD).decode('utf-8'))))
    if len(rows) != len(names) or {r[0] for r in rows} != set(names):
        raise ValueError('wheel RECORD does not cover every archive entry')
    for name, digest, size in rows:
        if name == RECORD:
            if digest or size:
                raise ValueError('wheel RECORD must leave its own hash and size empty')
            continue
        data = archive.read(name)
        expected = 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode('ascii')
        if digest != expected or size != str(len(data)):
            raise ValueError(f'wheel RECORD mismatch: {name}')
    return rows


def wheel_plan(path):
    data = path.read_bytes()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        rows = check_record(archive)
        if sha(archive.read(HIGH_PATH)) != HIGH_HASH:
            raise ValueError('wheel: Ubuntu CVE-2025-47273 source identity changed')
        replacements = {name: convert(name, archive.read(name)) for name in PATCHES}
        if all(archive.read(name) == body for name, body in replacements.items()):
            return data
        for row in rows:
            if row[0] in replacements:
                body = replacements[row[0]]
                row[1] = 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(body).digest()).rstrip(b'=').decode('ascii')
                row[2] = str(len(body))
        record = io.StringIO(newline='')
        csv.writer(record, lineterminator='\n').writerows(rows)
        replacements[RECORD] = record.getvalue().encode('utf-8')
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as target:
            target.comment = archive.comment
            for info in archive.infolist():
                target.writestr(info, replacements.get(info.filename, archive.read(info.filename)))
    updated = output.getvalue()
    with zipfile.ZipFile(io.BytesIO(updated)) as archive:
        check_record(archive)
    return updated


def atomic_write(path, body):
    mode = stat.S_IMODE(path.stat().st_mode)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='setuptools-backport-', delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(body)
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.fsync(output.fileno())
        except BaseException:
            temporary.unlink()
            raise
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--site-packages', type=Path, required=True)
    parser.add_argument('--wheel', type=Path, required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    root = args.site_packages.resolve(strict=True)
    wheel = args.wheel
    if wheel.is_symlink() or wheel.name != 'setuptools-68.1.2-py3-none-any.whl':
        raise ValueError('expected the exact regular Ubuntu setuptools wheel')
    if sha((root / HIGH_PATH).read_bytes()) != HIGH_HASH:
        raise ValueError('Ubuntu CVE-2025-47273 source identity changed')
    plan = []
    for name in PATCHES:
        path = root / name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root):
            raise ValueError(f'{name}: unsafe target')
        before = path.read_bytes()
        plan.append((path, before, convert(name, before)))
    before = wheel.read_bytes()
    plan.append((wheel, before, wheel_plan(wheel)))
    report = [{'path': str(path), 'before': sha(before), 'after': sha(after), 'changed': before != after}
              for path, before, after in plan]
    print(json.dumps({'dry_run': args.dry_run, 'files': report}, indent=2))
    if args.dry_run:
        return
    written = []
    try:
        for path, before, after in plan:
            if before != after:
                atomic_write(path, after)
                written.append((path, before))
    except BaseException:
        for path, before in reversed(written):
            atomic_write(path, before)
        raise


if __name__ == '__main__':
    main()
