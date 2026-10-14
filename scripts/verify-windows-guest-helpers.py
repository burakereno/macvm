#!/usr/bin/env python3
"""Verify the ARM64 outputs against the source build's public receipt."""
import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import re
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('helpers', type=Path)
parser.add_argument('sources', type=Path)
parser.add_argument('--tools-iso', type=Path)
parser.add_argument('--tools-receipt', type=Path)
args = parser.parse_args()
assert bool(args.tools_iso) == bool(args.tools_receipt), 'ISO and receipt must be provided together'
receipt = json.loads((args.helpers / 'Provenance.json').read_text(encoding='utf-8-sig'))
assert receipt['schemaVersion'] == 1 and receipt['architecture'] == 'ARM64'
assert receipt['vdagent'] == '9c573c97545db8a58f1cc115f40073ea493bb356'
assert receipt['webdav'] == '10613f2087b9359463e70bf5e2491c9aadd83dd5'
assert receipt['vcpkg'] == 'e456309491fd875487bf02b8a0dca76c1b1b00cc'
assert receipt['spiceCommon'] == '05c0c26839e88e6d0cc5452f49c40e38543c8f97'
assert receipt['spiceProtocol'] == 'ce0c4211e6f16c66477934cc42e70fa0988ca7f0'
expected = {}
for name, checksum in receipt['binaries'].items():
    windows = PureWindowsPath(name)
    assert not windows.is_absolute() and not windows.drive
    assert all(re.fullmatch(r'[A-Za-z0-9_.-]+', part) and part not in ['.', '..'] for part in windows.parts)
    normalized = '/'.join(windows.parts)
    assert normalized not in expected and re.fullmatch(r'[a-f0-9]{64}', checksum)
    expected[normalized] = checksum
assert {'vdagent.exe', 'vdservice.exe', 'WebDAV/spice-webdavd.exe'} <= expected.keys()
actual = {str(file.relative_to(args.helpers)): file for file in args.helpers.rglob('*') if file.suffix.lower() in ['.exe', '.dll']}
assert set(actual) == set(expected), 'Unexpected or missing helper binary'
for name, file in actual.items():
    assert file.is_file() and not file.is_symlink()
    assert hashlib.sha256(file.read_bytes()).hexdigest() == expected[name], f'Checksum mismatch: {name}'
    with file.open('rb') as stream:
        assert stream.read(2) == b'MZ'
        stream.seek(0x3c)
        offset, = struct.unpack('<I', stream.read(4))
        stream.seek(offset)
        assert stream.read(4) == b'PE\0\0' and stream.read(2) == b'\x64\xaa', f'Not ARM64: {name}'
assert (args.helpers / 'Licenses/LICENSE-GPL-2.0.txt').is_file()
assert (args.helpers / 'Licenses/spice-webdavd-LGPL-2.1.txt').is_file()
with zipfile.ZipFile(args.sources) as sources:
    names = set(sources.namelist())
    assert {'vdagent.tar', 'spice-webdavd.tar', 'spice-common.tar', 'spice-protocol.tar', 'vcpkg.tar',
            'webdav-CMakeLists.txt', 'vdagent-CMake.patch', 'spice-protocol-arm64.patch',
            'build-windows-guest-helpers.ps1', 'README.txt', 'Provenance.json'} <= names
    assert json.loads(sources.read('Provenance.json').decode('utf-8-sig')) == receipt
    assert any(name.startswith('dependency-archives/') for name in names)
    assert all(not name.startswith('/') and '..' not in PureWindowsPath(name).parts for name in names)
if args.tools_iso:
    tools = json.loads(args.tools_receipt.read_text())
    assert tools['schemaVersion'] == 1
    assert tools['provenanceSHA256'] == hashlib.sha256((args.helpers / 'Provenance.json').read_bytes()).hexdigest(), 'Tools ISO uses another helper build'
    assert tools['isoSHA256'] == hashlib.sha256(args.tools_iso.read_bytes()).hexdigest(), 'Tools ISO checksum mismatch'
print(f'Verified {len(actual)} ARM64 helpers/libraries, matching sources and notices.')
