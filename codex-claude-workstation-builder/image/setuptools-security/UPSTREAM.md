# Ubuntu setuptools source backports

These fixes target the complete Ubuntu 24.04 `python3-setuptools` and
`python3-setuptools-whl` 68.1.2-2ubuntu1.2 instances, before pipx environments
can seed from the distro wheel. The distro version and all unrelated package
files remain unchanged. Source hashes and wheel RECORD entries are verified
before mutation; unknown source shapes stop the build.

- [CVE-2025-47273](https://ubuntu.com/security/CVE-2025-47273) is already fixed
  by Ubuntu in this version. Its `PackageIndex` containment source is preserved
  and checked against SHA-256
  `b5324e4c217dc49d3fa22d13b552a2106394003bd4b08ba6c815e1de4ff341d1`.
- [CVE-2026-59890](https://ubuntu.com/security/CVE-2026-59890): backport
  [dd9f436a](https://github.com/pypa/setuptools/commit/dd9f436a36486b4cb8a4c70a2321548b0be09b8f).
  Normalize both the manifest pattern and candidate path to NFC in
  `setuptools.command.egg_info.FileList`. Real PEP 517 sdist tests verify that
  NFD filenames excluded by NFC rules do not leak into the archive. This
  upstream fix does not change the independent legacy distutils FileList API.
- [GHSA-xmj3-9gf7-h52w](https://github.com/advisories/GHSA-xmj3-9gf7-h52w):
  backport [6d07b8d](https://github.com/pypa/setuptools/commit/6d07b8d17890dda58d944ac51e58f54af92d52af).
  Validate dotted namespace identifiers and real-path containment before the
  legacy Wheel installer writes namespace files. POSIX absolute and symlink
  escapes are rejected; legitimate dotted namespace installation is preserved.

The build verifies both the system tree and the patched, RECORD-validated
wheel with ten offline consumer tests each. The three owning source files and
RECORD are the only uncompressed wheel entries changed; upstream license files
remain intact (setuptools: MIT). Existing raw scanner findings remain visible.
This backport is separate from pip's stripped vendored `pkg_resources` subset
and makes no claim about independently downloaded packages or all legacy APIs.
