#!/usr/bin/env python3
"""Exercise source resolution with fake HTTP and a real verified source archive."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


class SourceDownloadTests(unittest.TestCase):
    def test_archive_has_its_own_budget_and_still_verifies_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            archive = root / 'source.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                for name in ['package.json', 'apps/cli/package.json']:
                    data = b'{"version":"9.9.9"}'
                    entry = tarfile.TarInfo('source/' + name)
                    entry.size = len(data)
                    tar.addfile(entry, io.BytesIO(data))
            (root / 'curl').write_text('''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
a = sys.argv[1:]
url = next(x for x in a if x.startswith('https://'))
timeouts = [a[i+1] for i,x in enumerate(a) if x == '--max-time']
with open(os.environ['FAKE_CURL_LOG'], 'a') as f:
    f.write(json.dumps({'url':url, 'timeout':timeouts[-1]})+'\\n')
if '/releases?' in url:
    print('[{"tag_name":"dsh-v9.9.9","draft":false}]')
elif '/commits/' in url:
    print(json.dumps({'sha':'a'*40}))
else:
    shutil.copyfile(os.environ['FAKE_SOURCE_ARCHIVE'], a[a.index('-o')+1])
''')
            (root / 'curl').chmod(0o755)
            log, metadata = root / 'requests.jsonl', root / 'metadata.json'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       FAKE_CURL_LOG=str(log), FAKE_SOURCE_ARCHIVE=str(archive))
            env.pop('GITHUB_TOKEN', None)
            subprocess.run(['bash', str(Path(__file__).with_name('resolve-dsh-source.sh')),
                            '--metadata-output', str(metadata), '--github-output', '/dev/null'],
                           env=env, check=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([c['timeout'] for c in calls], ['120', '120', '600'])
            result = json.loads(metadata.read_text())
            self.assertEqual(result['version'], '9.9.9')
            self.assertEqual(result['commit'], 'a' * 40)
            self.assertEqual(result['archiveSha256'], hashlib.sha256(archive.read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
