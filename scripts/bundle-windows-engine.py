#!/usr/bin/env python3
"""Stage a relocatable QEMU/TPM toolchain. Build-time Homebrew only; never runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(path):
    return [line.strip().split(' (compatibility')[0]
            for line in run('otool', '-L', str(path)).splitlines()[1:]]


def system(path):
    return path.startswith(('/usr/lib/', '/System/Library/'))


parser = argparse.ArgumentParser()
parser.add_argument('destination', type=Path)
parser.add_argument('--prefix', type=Path, default=Path('/opt/homebrew'))
parser.add_argument('--firmware', type=Path, required=True)
parser.add_argument('--identity', default='-')
args = parser.parse_args()
root = args.destination.resolve()
root.mkdir(parents=True, exist_ok=True)
(root / 'lib').mkdir()
(root / 'Licenses').mkdir()
sources = {}
names = {}


def stage(source, name):
    source = source.resolve(strict=True)
    if source in sources:
        return sources[source]
    dest = root / name
    if dest.name in names and names[dest.name] != source:
        raise RuntimeError(f'Dependency basename collision: {source}')
    names[dest.name] = source
    shutil.copy2(source, dest)
    dest.chmod(0o755)
    sources[source] = dest
    for dep in dependencies(source):
        if system(dep):
            continue
        if not dep.startswith('/'):
            raise RuntimeError(f'Unresolved build dependency: {source}: {dep}')
        stage(Path(dep), 'lib/' + Path(dep).name)
    return dest


for source, name in [('qemu-system-aarch64', 'MacVMWindowsEngine'),
                     ('qemu-img', 'qemu-img'), ('swtpm', 'swtpm'),
                     ('swtpm_setup', 'swtpm_setup')]:
    stage(args.prefix / 'bin' / source, name)

# Resolve every dependency relative to its own file, with no external fallback.
for source, dest in sources.items():
    for dep in dependencies(source):
        if not system(dep):
            relative = os.path.relpath(sources[Path(dep).resolve()], dest.parent)
            subprocess.run(['install_name_tool', '-change', dep,
                            '@loader_path/' + relative, str(dest)], check=True, capture_output=True)
    if dest.suffix == '.dylib':
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + dest.name, str(dest)], check=True, capture_output=True)
    commands = run('otool', '-l', str(dest))
    for rpath in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', commands):
        if rpath.startswith(('/opt/', '/usr/local/', '/Users/')):
            subprocess.run(['install_name_tool', '-delete_rpath', rpath, str(dest)], check=True, capture_output=True)

shutil.copy2(args.firmware / 'edk2-aarch64-secure-code.fd', root)
shutil.copy2(args.firmware / 'edk2-licenses.txt', root / 'Licenses')
shutil.copytree(args.prefix / 'share/qemu/keymaps', root / 'keymaps')
# The source template may be QCOW2 despite its .fd suffix. Runtime pflash is raw.
subprocess.run([str(args.prefix / 'bin/qemu-img'), 'convert', '-O', 'raw',
                str(args.firmware / 'edk2-arm-secure-vars.fd'), str(root / 'edk2-arm-secure-vars.fd')], check=True)
(root / 'swtpm_setup.conf').write_text('# MacVM initializes TPM locally without a certificate service.\n')

formulae = set()
formula_roots = {}
for source in sources:
    if 'Cellar' in source.parts:
        index = source.parts.index('Cellar')
        name = source.parts[index + 1]
        installed_root = Path(*source.parts[:index + 3])
        if name in formula_roots and formula_roots[name] != installed_root:
            raise RuntimeError(f'Two installed versions of {name} are linked; rebuild a consistent toolchain.')
        formulae.add(name)
        formula_roots[name] = installed_root
metadata = json.loads(run(str(args.prefix / 'bin/brew'), 'info', '--json=v2', *sorted(formulae)))
for formula in metadata['formulae']:
    formula_root = formula_roots[formula['name']]
    folder = root / 'Licenses' / formula['name']
    folder.mkdir(exist_ok=True)
    for candidate in formula_root.glob('*'):
        if candidate.is_file() and re.match(r'(?i)(copying|copyright|licen[cs]e|notice)', candidate.name):
            shutil.copy2(candidate, folder)
    recipe = formula_root / '.brew' / (formula['name'].split('@')[0] + '.rb')
    if not recipe.exists():
        recipes = list((formula_root / '.brew').glob('*.rb'))
        if len(recipes) != 1:
            raise RuntimeError(f'Installed build recipe missing for {formula["name"]}')
        recipe = recipes[0]
    shutil.copy2(recipe, folder / 'Formula.rb')
    receipt = json.loads((formula_root / 'INSTALL_RECEIPT.json').read_text())
    public_receipt = {key: receipt.get(key) for key in ['homebrew_version', 'used_options', 'built_as_bottle', 'poured_from_bottle', 'arch', 'built_on']}
    (folder / 'BuildReceipt.json').write_text(json.dumps(public_receipt, indent=2) + '\n')
    recipe_text = recipe.read_text()
    original_url = re.search(r'^\s+url "([^"]+)"', recipe_text, re.M)
    original_sha = re.search(r'^\s+sha256 "([a-f0-9]{64})"', recipe_text, re.M)
    if not original_url or not original_sha:
        raise RuntimeError(f'Cannot identify exact source archive for {formula["name"]}')
    metadata_item = {key: formula.get(key) for key in ['name', 'license', 'homepage']}
    metadata_item.update(version=formula_root.name, source_url=original_url[1], source_sha256=original_sha[1])
    (folder / 'source.json').write_text(json.dumps(metadata_item, indent=2) + '\n')

# The sources are shipped beside the app release; licences are inside the app.
collection = ['python3', str(Path(__file__).with_name('collect-windows-sources.py')),
              str(root / 'Licenses'), str(Path(__file__).resolve().parent.parent / 'dist/MacVM-Windows-Sources.tar.gz')]
guest_cache = Path.home() / 'Library/Application Support/MacVM/Engines/Windows Display Tools'
if (guest_cache / 'GuestSources.zip').is_file():
    collection += ['--guest-sources', str(guest_cache / 'GuestSources.zip'), '--guest-provenance', str(guest_cache / 'GuestHelpers/Provenance.json')]
    shutil.copytree(guest_cache / 'GuestHelpers/Licenses', root / 'Licenses/WindowsGuestTools')
    shutil.copy2(guest_cache / 'GuestHelpers/Provenance.json', root / 'Licenses/WindowsGuestTools/Provenance.json')
subprocess.run(collection, check=True)

for source, dest in sources.items():
    if any(not system(dep) and not dep.startswith('@loader_path/') for dep in dependencies(dest)):
        raise RuntimeError(f'Non-portable dependency in {dest}')
    flags = ['codesign', '--force', '--sign', args.identity, '--options', 'runtime']
    if args.identity != '-':
        flags.append('--timestamp')
    if dest.name == 'MacVMWindowsEngine':
        flags += ['--entitlements', str(Path(__file__).resolve().parent.parent / 'Resources/WindowsPrototypeEngine.entitlements')]
    subprocess.run(flags + [str(dest)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(dest)], check=True, capture_output=True)

manifest = {str(dest.relative_to(root)): hashlib.sha256(dest.read_bytes()).hexdigest()
            for dest in sources.values()}
(root / 'EngineManifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(f'Bundled {len(sources)} portable executables/libraries; no external dylib paths.')
