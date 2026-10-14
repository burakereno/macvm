#!/usr/bin/env python3
"""Check portable engine dependencies, signatures and independent disk/TPM creation."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('engine', type=Path)
parser.add_argument('--team', default='66K3EFBVB6')
args = parser.parse_args()
root = args.engine.resolve(strict=True)
manifest = json.loads((root / 'EngineManifest.json').read_text())
environment = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
environment['PATH'] = '/usr/bin:/bin'
def run(*arguments, **kwargs):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT, env=environment, timeout=60, **kwargs)

for name, digest in manifest.items():
    file = root / name
    if hashlib.sha256(file.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'Bundled executable checksum mismatch: {name}')
    run('codesign', '--verify', '--strict', str(file))
    signature = run('codesign', '-dv', '--verbose=4', str(file))
    if f'TeamIdentifier={args.team}' not in signature or 'runtime' not in signature:
        raise RuntimeError(f'Unexpected publisher or hardened runtime: {name}')
    for dependency in run('otool', '-L', str(file)).splitlines()[1:]:
        path = dependency.strip().split(' (compatibility')[0]
        if not path.startswith(('/usr/lib/', '/System/Library/', '@loader_path/')):
            raise RuntimeError(f'External runtime dependency: {name}: {path}')
    for path in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', run('otool', '-l', str(file))):
        if path.startswith(('/opt/', '/usr/local/', '/Users/')):
            raise RuntimeError(f'External runtime search path in {name}')
for name in ['keymaps/en-us', 'edk2-aarch64-secure-code.fd', 'edk2-arm-secure-vars.fd', 'swtpm_setup.conf', 'DisplayTools.iso']:
    if not (root / name).is_file():
        raise RuntimeError(f'Missing Windows runtime resource: {name}')
print(run(str(root / 'MacVMWindowsEngine'), '--version').splitlines()[0])
print(run(str(root / 'swtpm'), '--version').splitlines()[0])
with tempfile.TemporaryDirectory(prefix='macvm-engine-check-') as temp:
    directory = Path(temp)
    run(str(root / 'qemu-img'), 'create', '-f', 'qcow2', str(directory / 'Disk.qcow2'), '64M')
    info = json.loads(run(str(root / 'qemu-img'), 'info', '--output=json', str(directory / 'Disk.qcow2')))
    assert info['format'] == 'qcow2' and info['virtual-size'] == 64 * 1024 * 1024
    state = directory / 'TPM'; state.mkdir(mode=0o700)
    run(str(root / 'swtpm_setup'), '--tpm', './swtpm socket', '--tpm2', '--tpmstate', str(state),
        '--config', str(root / 'swtpm_setup.conf'), '--createek', '--pcr-banks', 'sha256', cwd=root)
    assert (state / 'tpm2-00.permall').is_file()
print(f'Verified {len(manifest)} signed, portable engine files; disk and private TPM creation passed.')
