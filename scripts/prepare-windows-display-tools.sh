#!/usr/bin/env bash
set -euo pipefail
# Keep downloaded installers in Downloads; retain only the small runtime payload.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD="$HOME/Downloads/macvm-display-tools-0.1.273.iso"
STAGE="$(mktemp -d "$HOME/Downloads/macvm-display-tools.XXXXXX")"
MOUNT="$(mktemp -d /tmp/macvm-display-tools.XXXXXX)"
CACHE="$HOME/Library/Application Support/MacVM/Engines/Windows Display Tools"
PENDING_CACHE=""
HELPERS="${WINDOWS_GUEST_HELPERS_DIR:-$CACHE/GuestHelpers}"
if [[ -n "${WINDOWS_GUEST_HELPERS_DIR:-}" ]]; then
    HELPER_SOURCES="${WINDOWS_GUEST_SOURCES_FILE:-${HELPERS%/*}/MacVM-Windows-Guest-Sources.zip}"
else
    HELPER_SOURCES="$CACHE/GuestSources.zip"
fi
cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
    rm -rf "$STAGE"
    [[ -z "$PENDING_CACHE" ]] || rm -rf "$PENDING_CACHE"
    rm -f "$CACHE/DisplayTools.pending.iso"
    rm -f "$DOWNLOAD" "$DOWNLOAD.part"
}
trap cleanup EXIT
python3 "$ROOT_DIR/scripts/verify-windows-guest-helpers.py" "$HELPERS" "$HELPER_SOURCES"
# Reuse only the verified runtime binaries when editing the installer UI/scripts.
# An older cache missing a matching driver falls back to the original release.
PAYLOADS=(viogpuap.exe vgpusrv.exe viogpudo.cat viogpudo.inf viogpudo.sys Drivers/Serial/vioser.inf Drivers/Network/netkvm.inf)
if [[ -f "$CACHE/DisplayTools.iso" && ! -f "$DOWNLOAD" ]]; then
    hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$CACHE/DisplayTools.iso" >/dev/null
    cp -R "$MOUNT/." "$STAGE/"
    chmod -R u+w "$STAGE"
    hdiutil detach "$MOUNT" >/dev/null
fi
NEEDS_SOURCE=0
for file in "${PAYLOADS[@]}"; do
    [[ -f "$STAGE/$file" ]] || NEEDS_SOURCE=1
done
if [[ "$NEEDS_SOURCE" == 1 ]]; then
    if [[ ! -f "$DOWNLOAD" ]]; then
        curl --fail --location --output "$DOWNLOAD.part" https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/utm-guest-tools-0.1.273.iso
        mv "$DOWNLOAD.part" "$DOWNLOAD"
    fi
    echo '7d2c0343e92358ad5e65078b08ec1dad873eb91b3c154aef60531bf6c2f04601  '"$DOWNLOAD" | shasum -a 256 -c -
    hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DOWNLOAD" >/dev/null
    for file in viogpuap.exe vgpusrv.exe viogpudo.cat viogpudo.inf viogpudo.sys; do
        cp "$MOUNT/Drivers/viogpudo/2k25/ARM64/$file" "$STAGE/"
    done
    mkdir -p "$STAGE/Drivers/Serial" "$STAGE/Drivers/Network"
    cp "$MOUNT/Drivers/vioserial/2k25/ARM64/"* "$STAGE/Drivers/Serial/"
    cp "$MOUNT/Drivers/NetKVM/2k25/ARM64/"* "$STAGE/Drivers/Network/"
    hdiutil detach "$MOUNT" >/dev/null
fi
(cd "$STAGE" && shasum -a 256 -c <<'HASHES'
396b50c643a55745a7f05023d83bf4f1d82b38a4e22594cfc603827b42f79e07  vgpusrv.exe
2ed3d0678fa009f30029de5d6dfb66d41efd7e8439da837f40649eb2c801bdca  viogpuap.exe
c4f11ed462623bd15c132b229c99b6911442a63848409c5d2ca51b168a85c2bf  viogpudo.cat
4304b94e6b108bab81ac50d96171255872afeab49d501b91d898bab90b093507  viogpudo.inf
99b233551b76469d9b18b1f015b7c27ff5337c7854513470222ed770e447b643  viogpudo.sys
HASHES
)
rm -f "$STAGE/vc_redist.arm64.exe" "$STAGE/spice-webdavd-arm64-latest.msi"
rm -rf "$STAGE/WebDAV" "$STAGE/Licenses"
cp "$HELPERS/vdagent.exe" "$HELPERS/vdservice.exe" "$STAGE/"
cp "$HELPERS/Provenance.json" "$STAGE/SourceProvenance.json"
cp -R "$HELPERS/WebDAV" "$HELPERS/Licenses" "$STAGE/"
cp "$ROOT_DIR/Resources/WindowsDisplayTools/"* "$STAGE/"
python3 - "$STAGE" <<'PYHASH'
from pathlib import Path
import json,hashlib,sys,struct
stage=Path(sys.argv[1])
hashes={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.rglob('*') if p.is_file() and p.suffix.lower() in ['.exe','.msi','.cat','.inf','.sys','.dll']}
(stage/'PayloadHashes.json').write_text(json.dumps(hashes,indent=2,sort_keys=True)+'\n')
minor = 28
for file in stage.rglob('*'):
    if file.suffix.lower() in ['.exe','.dll']:
        data = file.read_bytes(); pe = struct.unpack_from('<I',data,0x3c)[0]
        major, candidate = data[pe+26:pe+28]
        if major == 14: minor = max(minor, candidate)
(stage/'SourceInfo.json').write_text(json.dumps({'minimumRuntime':f'14.{minor}','sourcesAsset':'MacVM-Windows-Sources.tar.gz'},indent=2)+'\n')
PYHASH
mkdir -p "$CACHE"
PENDING_CACHE="$(mktemp -d "$CACHE/.pending.XXXXXX")"
# Copy before replacing the cache, including when its existing helpers are the
# input. Commit the receipt last so interrupted preparation fails preflight.
cp -R "$HELPERS" "$PENDING_CACHE/GuestHelpers"
cp "$HELPER_SOURCES" "$PENDING_CACHE/GuestSources.zip"
hdiutil makehybrid -iso -joliet -default-volume-name 'MacVM Tools' -o "$CACHE/DisplayTools.pending.iso" "$STAGE" >/dev/null
python3 - "$CACHE/DisplayTools.pending.iso" "$PENDING_CACHE/GuestHelpers/Provenance.json" "$PENDING_CACHE/DisplayTools.json" <<'PYRECEIPT'
from pathlib import Path
import hashlib, json, sys
iso, provenance, output = map(Path, sys.argv[1:])
output.write_text(json.dumps({'schemaVersion': 1,
    'isoSHA256': hashlib.sha256(iso.read_bytes()).hexdigest(),
    'provenanceSHA256': hashlib.sha256(provenance.read_bytes()).hexdigest()}, indent=2)+'\n')
PYRECEIPT
rm -rf "$CACHE/GuestHelpers"
mv "$PENDING_CACHE/GuestHelpers" "$CACHE/GuestHelpers"
mv "$PENDING_CACHE/GuestSources.zip" "$CACHE/GuestSources.zip"
mv "$CACHE/DisplayTools.pending.iso" "$CACHE/DisplayTools.iso"
mv "$PENDING_CACHE/DisplayTools.json" "$CACHE/DisplayTools.json"
rm -f "$DOWNLOAD"
echo "Windows Tools prepared from verified ARM64 sources. Downloaded installer removed. Rebuild MacVM to include them."
