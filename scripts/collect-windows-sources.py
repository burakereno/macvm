#!/usr/bin/env python3
"""Collect exact source archives/build recipes and fill missing upstream notices."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('licenses', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--guest-sources', type=Path)
parser.add_argument('--guest-provenance', type=Path)
args = parser.parse_args()
if bool(args.guest_sources) != bool(args.guest_provenance):
    parser.error('Guest source archive and provenance must be supplied together.')
cache = Path.home() / 'Downloads/MacVM-Windows-Source-Cache'
cache.mkdir(parents=True, exist_ok=True)

# Alternate distribution of the identical upstream archive. Keep the original
# source URL in the receipt and require its original SHA-256 on every route.
source_mirrors = {
    ('https://cairographics.org/releases/pixman-0.46.4.tar.gz',
     'd09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c'):
        ['https://storage.googleapis.com/minimal-staging-archives/pixman-0.46.4.tar.gz'],
}

def fetch(url, checksum, destination):
    if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == checksum:
        return
    partial = destination.with_suffix(destination.suffix + '.partial')
    candidates = [url, *source_mirrors.get((url, checksum), [])]
    for index, candidate in enumerate(candidates):
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '15', '--max-time', '180', '--silent', '--show-error',
                            '--proto', '=https', '--output', str(partial), candidate], check=True)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != checksum:
                raise RuntimeError(f'Source checksum mismatch: {destination.name}')
            partial.replace(destination)
            return
        except subprocess.CalledProcessError:
            if index == len(candidates) - 1:
                raise
            print(f'Upstream download unavailable; trying a checksum-pinned mirror for {destination.name}.')
        finally:
            partial.unlink(missing_ok=True)

def collect(metadata_file):
    item = json.loads(metadata_file.read_text())
    folder = metadata_file.parent
    source_root = cache / item['name']
    source_root.mkdir(exist_ok=True)
    if source_root.is_symlink():
        raise RuntimeError(f'Source cache folder must not be a symlink: {item["name"]}')
    filename = Path(urllib.parse.urlparse(item['source_url']).path).name
    archive = source_root / filename
    fetch(item['source_url'], item['source_sha256'], archive)
    files = [filename, 'source.json', 'Formula.rb', 'BuildReceipt.json']
    shutil.copy2(metadata_file, source_root / 'source.json')
    for name in ['Formula.rb', 'BuildReceipt.json']:
        shutil.copy2(folder / name, source_root / name)
    # Never extract an upstream archive to disk. Only copy bounded notice text.
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            notice = re.match(r'(?i)^(copying|copyright|licen[cs]e|notice|gpl|lgpl|bsd)([._-].*)?$', parts[-1]) or parts[-1].lower() == 'readme.license'
            if member.isfile() and 1 <= member.size <= 1024 * 1024 and len(parts) <= 3 and notice:
                data = tar.extractfile(member).read()
                name = '_'.join(parts[1:])
                if name and not (folder / name).exists():
                    (folder / name).write_bytes(data)
    text = (folder / 'Formula.rb').read_text()
    for index, patch in enumerate(re.findall(r'\bpatch do\s+(.*?)\n\s+end', text, re.S)):
        files.append(f'patch-{index}.diff')
        url = re.search(r'url "([^"]+)"', patch)
        checksum = re.search(r'sha256 "([a-f0-9]{64})"', patch)
        file = re.search(r'file "([^"]+)"', patch)
        if url and checksum:
            fetch(url[1], checksum[1], source_root / f'patch-{index}.diff')
        elif file:
            # These Homebrew patches are also part of the corresponding source.
            path = Path('/opt/homebrew/Library/Taps/homebrew/homebrew-core') / file[1]
            if path.is_file():
                shutil.copy2(path, source_root / f'patch-{index}.diff')
            elif file[1] == 'Patches/glib/hardcoded-paths.diff':
                fetch('https://raw.githubusercontent.com/Homebrew/homebrew-core/1cf441a09f572566b1b7c4695a4d169d1177248a/Patches/glib/hardcoded-paths.diff',
                      'd846efd0bf62918350da94f850db33b0f8727fece9bfaf8164566e3094e80c97', source_root / f'patch-{index}.diff')
            else:
                raise RuntimeError(f'Install the Homebrew core tap to supply {file[1]} before releasing.')
        else:
            raise RuntimeError(f'Unrecognised patch recipe for {item["name"]}')
    if not any(p.name != 'source.json' and p.name not in ['Formula.rb', 'BuildReceipt.json'] for p in folder.iterdir()):
        raise RuntimeError(f'No upstream licence notice for {item["name"]}')
    return (item['name'], files)

with ThreadPoolExecutor(max_workers=4) as pool:
    names = list(pool.map(collect, sorted(args.licenses.glob('*/source.json'))))
readme = '''These exact upstream source archives and Homebrew build recipes correspond to
the separate QEMU/TPM executables and dynamically linked libraries bundled in
MacVM. Upstream licence notices are also included inside WindowsEngine/Licenses.
Build with the supplied Formula.rb recipes and patches on an Apple Silicon Mac,
then scripts/bundle-windows-engine.py relocates and signs the executables.
Modified LGPL libraries can be rebuilt and substituted in a local app copy;
re-sign nested code and the app with your own identity (or an ad-hoc development
signature). Never change files inside a running VM application's bundle.
MacVM's Swift source and build scripts are at https://github.com/burakereno/macvm.
'''
if args.guest_sources:
    readme += '''\nWindowsGuestTools.zip contains the matching Windows ARM64 clipboard/folder
helper sources, exact vcpkg ports/patches, dependency source archives and the
Windows build script. WindowsGuestTools-Provenance.json records the compiled
binary hashes and upstream revisions. Original dependency notices are included
in the app and on the Windows Tools CD.\n'''
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='macvm-source-index-', dir=cache) as temp:
    info = Path(temp) / 'README.txt'
    info.write_text(readme)
    pending = args.output.with_suffix('.pending')
    with tarfile.open(pending, 'w:gz') as tar:
        tar.add(info, arcname='MacVM-Windows-Sources/README.txt')
        for name, files in names:
            for filename in files:
                file = cache / name / filename
                if not file.is_file() or file.is_symlink():
                    raise RuntimeError(f'Invalid source package file: {name}/{filename}')
                tar.add(file, arcname=f'MacVM-Windows-Sources/{name}/{filename}')
        if args.guest_sources:
            for file, name in [(args.guest_sources, 'WindowsGuestTools.zip'), (args.guest_provenance, 'WindowsGuestTools-Provenance.json')]:
                if not file.is_file() or file.is_symlink():
                    raise RuntimeError(f'Invalid guest source asset: {name}')
                tar.add(file, arcname=f'MacVM-Windows-Sources/{name}')
    pending.replace(args.output)
print(f'Collected exact sources, recipes and licence notices for {len(names)} components.')
