#!/usr/bin/env python3
"""Prepare one private local prototype. Never overwrite an existing VM disk."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, required=True)
parser.add_argument('--iso', type=Path, required=True)
parser.add_argument('--iso-sha256', required=True)
parser.add_argument('--firmware', type=Path, required=True)
parser.add_argument('--variables', type=Path, required=True,
                    help='Raw or qcow2 variable template with Microsoft Secure Boot certificates enrolled.')
parser.add_argument('--drivers', type=Path)
args = parser.parse_args()
assert len(args.iso_sha256) == 64 and all(c in '0123456789abcdefABCDEF' for c in args.iso_sha256)
for source in [args.iso, args.firmware, args.variables] + ([args.drivers] if args.drivers else []):
    assert source.is_absolute() and stat.S_ISREG(source.lstat().st_mode), f'Not a regular source: {source}'
h = hashlib.sha256()
with args.iso.open('rb') as file:
    while chunk := file.read(8 * 1024 * 1024):
        h.update(chunk)
assert h.hexdigest() == args.iso_sha256.lower(), 'Microsoft ISO SHA256 mismatch'
root = args.directory
assert root.is_absolute()
root.mkdir(parents=True, exist_ok=True, mode=0o700)
info = root.lstat()
assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077
fd = os.open(root / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
try:
    assert not (root / 'Prototype.json').exists(), 'Existing prototype: do not overwrite its configuration.'
    assert not (root / 'Disk.qcow2').exists(), 'Existing disk: do not overwrite it.'
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=root) as temp:
        staging = Path(temp)
        subprocess.run(['/opt/homebrew/bin/qemu-img', 'create', '-f', 'qcow2', str(staging/'Disk.qcow2'), '128G'], check=True)
        subprocess.run(['/opt/homebrew/bin/qemu-img', 'convert', '-O', 'raw', str(args.variables), str(staging/'EFI.fd')], check=True)
        for name in ['Disk.qcow2', 'EFI.fd']:
            (staging/name).chmod(0o600)
            (staging/name).rename(root/name)
    value = {'directory': root.as_uri()+'/', 'name': 'Windows 11 ARM Prototype',
             'cpuCount': 4, 'memoryGB': 8, 'diskGB': 128,
             'qemuPath': '/opt/homebrew/bin/qemu-system-aarch64', 'swtpmPath': '/opt/homebrew/bin/swtpm',
             'firmwarePath': str(args.firmware), 'installerPath': str(args.iso)}
    if args.drivers:
        value['toolsPath'] = str(args.drivers)
    config = root/'Prototype.json'
    with config.open('x') as file:
        json.dump(value, file, indent=2)
    config.chmod(0o600)
    print('Prepared Windows prototype:', root)
finally:
    os.close(fd)
