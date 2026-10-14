#!/usr/bin/env python3
"""Fetch the exact upstream Secure Boot images used by the validated Windows VM."""
import bz2
import hashlib
from pathlib import Path
import os
import shutil
import tempfile
import urllib.request

FILES = {
    'edk2-aarch64-secure-code.fd': (
        '37ba092d59aff24900dfd0d5e01d4ed68441ba07', '.bz2',
        '89206fa3bce0a43161e6d8dc143c6246ac03f095ce9873a1243cdb99efe4ee63',
        'c85a57de1ac39e550a6529bd66a4214eb1d8c14dcda7e22dedf72566a769fbc7'),
    'edk2-arm-secure-vars.fd': (
        'fdaf37123a5cf6d74a9da7cd97d1b5b18eadd305', '.bz2',
        '4dba10d7c7169b52a7b7bb8e0cef1c0b630312ff13725eff10d4711f21d9f373',
        'e16c802acef4b55ad6a9a21908ba0c3fdec59abec7b9cecb084a8e9261c75f06'),
    'edk2-licenses.txt': (
        'fdaf37123a5cf6d74a9da7cd97d1b5b18eadd305', '',
        '1ddeaed2e7d2e9ecb960bdfc1b8ee45387aff70d056d985d145949af3951657c',
        '1ddeaed2e7d2e9ecb960bdfc1b8ee45387aff70d056d985d145949af3951657c'),
}
cache = Path.home() / 'Library/Application Support/MacVM/Engines/Windows Prototype'
downloads = Path.home() / 'Downloads'
downloads.mkdir(exist_ok=True)
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='macvm-firmware-', dir=downloads) as staging:
    for name, (commit, suffix, compressed_hash, expanded_hash) in FILES.items():
        target = cache / name
        if target.is_file() and not target.is_symlink() and hashlib.sha256(target.read_bytes()).hexdigest() == expanded_hash:
            continue
        url = f'https://raw.githubusercontent.com/utmapp/qemu/{commit}/pc-bios/{name}{suffix}'
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(16 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != compressed_hash:
            raise RuntimeError(f'Upstream firmware checksum mismatch: {name}')
        compressed = Path(staging) / (name + suffix)
        compressed.write_bytes(data)
        expanded = bz2.decompress(data) if suffix else data
        if hashlib.sha256(expanded).hexdigest() != expanded_hash:
            raise RuntimeError(f'Expanded firmware checksum mismatch: {name}')
        pending = cache / (name + '.pending')
        pending.write_bytes(expanded)
        os.replace(pending, target)
print('Pinned Secure Boot firmware ready; temporary downloads removed.')
