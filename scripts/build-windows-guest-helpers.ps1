# Produce ARM64 helpers and their complete matching sources. No release secrets
# or downloaded prebuilt SPICE helpers are used by this build.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.build/windows-guest-sources'
$output = Join-Path $root 'dist/windows-guest-helpers'
$sources = Join-Path $work 'corresponding-sources'
function Run([string] $File, [string[]] $Arguments) {
    & $File @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File failed ($LASTEXITCODE)." }
}
function Checkout([string] $Name, [string] $URL, [string] $Commit) {
    $path = Join-Path $work $Name
    Run git @('clone', '--no-checkout', $URL, $path)
    Run git @('-C', $path, 'checkout', '--detach', $Commit)
    $actual = (& git -C $path rev-parse HEAD).Trim()
    if ($actual -ne $Commit) { throw "Source revision mismatch: $Name." }
    Run git @('-C', $path, 'archive', '--format=tar', "--output=$sources/$Name.tar", $Commit)
    return $path
}
New-Item -ItemType Directory -Path $work,$output,$sources -Force | Out-Null
$vcpkgCommit = 'e456309491fd875487bf02b8a0dca76c1b1b00cc'
$agentCommit = '9c573c97545db8a58f1cc115f40073ea493bb356'
$webdavCommit = '10613f2087b9359463e70bf5e2491c9aadd83dd5'
$vcpkg = Checkout 'vcpkg' 'https://github.com/microsoft/vcpkg.git' $vcpkgCommit
$agent = Checkout 'vdagent' 'https://gitlab.freedesktop.org/spice/win32/vd_agent.git' $agentCommit
# Submodules use historical git:// URLs upstream. Fetch the exact recorded
# revisions via HTTPS rather than using that unauthenticated transport.
foreach ($module in @(
    @('spice-common','https://gitlab.freedesktop.org/spice/spice-common.git','05c0c26839e88e6d0cc5452f49c40e38543c8f97'),
    @('spice-protocol','https://gitlab.freedesktop.org/spice/spice-protocol.git','ce0c4211e6f16c66477934cc42e70fa0988ca7f0')
)) {
    $path = Checkout $module[0] $module[1] $module[2]
    Get-ChildItem -LiteralPath $path -Force | Where-Object Name -ne '.git' | Copy-Item -Destination (Join-Path $agent $module[0]) -Recurse -Force
}
$webdav = Checkout 'spice-webdavd' 'https://github.com/utmapp/spice-webdavd-arm64.git' $webdavCommit
Run (Join-Path $vcpkg 'bootstrap-vcpkg.bat') @('-disableMetrics')
$env:VCPKG_DISABLE_METRICS = '1'
$env:VCPKG_BINARY_SOURCES = 'clear'
Run (Join-Path $vcpkg 'vcpkg.exe') @('install','libpng:arm64-windows-static','glib:arm64-windows')
$agentBuild = Join-Path $work 'agent-build'
Run cmake @('-S',$agent,'-B',$agentBuild,'-A','ARM64',"-DCMAKE_TOOLCHAIN_FILE=$vcpkg/scripts/buildsystems/vcpkg.cmake",'-DVCPKG_TARGET_TRIPLET=arm64-windows-static','-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
Run cmake @('--build',$agentBuild,'--config','Release','--target','vdagent','vdservice')
Copy-Item (Join-Path $agentBuild 'Release/vdagent.exe'),(Join-Path $agentBuild 'Release/vdservice.exe') $output

# The upstream ARM64 port uses a VS2019 project. This equivalent CMake wrapper
# builds its unmodified C sources against the pinned current GLib libraries.
$cmake = @'
cmake_minimum_required(VERSION 3.20)
project(macvm_webdav C)
add_executable(spice-webdavd spice-webdavd/spice-webdavd.c spice-webdavd/output-queue.c)
set(PREFIX "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}")
target_include_directories(spice-webdavd PRIVATE "${PREFIX}/include" "${PREFIX}/include/glib-2.0" "${PREFIX}/lib/glib-2.0/include")
foreach(COMPONENT glib gio gobject)
  find_library(${COMPONENT}_LIBRARY NAMES ${COMPONENT}-2.0 ${COMPONENT}-2 PATHS "${PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
  target_link_libraries(spice-webdavd PRIVATE ${${COMPONENT}_LIBRARY})
endforeach()
target_link_libraries(spice-webdavd PRIVATE mpr advapi32 ws2_32)
target_compile_definitions(spice-webdavd PRIVATE _CRT_SECURE_NO_WARNINGS)
'@
Set-Content -LiteralPath (Join-Path $webdav 'CMakeLists.txt') -Value $cmake -Encoding utf8
Set-Content -LiteralPath (Join-Path $sources 'webdav-CMakeLists.txt') -Value $cmake -Encoding utf8
$webdavBuild = Join-Path $work 'webdav-build'
Run cmake @('-S',$webdav,'-B',$webdavBuild,'-A','ARM64',"-DCMAKE_TOOLCHAIN_FILE=$vcpkg/scripts/buildsystems/vcpkg.cmake",'-DVCPKG_TARGET_TRIPLET=arm64-windows')
Run cmake @('--build',$webdavBuild,'--config','Release')
$webdavOutput = Join-Path $output 'WebDAV'
New-Item -ItemType Directory -Path $webdavOutput -Force | Out-Null
Copy-Item (Join-Path $webdavBuild 'Release/spice-webdavd.exe') $webdavOutput
Copy-Item (Join-Path $vcpkg 'installed/arm64-windows/bin/*.dll') $webdavOutput
$licenses = Join-Path $output 'Licenses'
New-Item -ItemType Directory -Path $licenses -Force | Out-Null
foreach ($triplet in @('arm64-windows','arm64-windows-static')) {
    Get-ChildItem (Join-Path $vcpkg "installed/$triplet/share") -Filter copyright -Recurse | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $licenses ($triplet + '-' + $_.Directory.Name + '.txt'))
    }
}
Copy-Item (Join-Path $root 'Resources/WindowsDisplayTools/LICENSE-GPL-2.0.txt') $licenses
Copy-Item (Join-Path $webdav 'COPYING') (Join-Path $licenses 'spice-webdavd-LGPL-2.1.txt')
$archives = Join-Path $sources 'dependency-archives'
New-Item -ItemType Directory -Path $archives -Force | Out-Null
# Top-level vcpkg downloads are upstream source archives; downloaded build
# tools live in subdirectories and are not redistributed in the source asset.
Get-ChildItem (Join-Path $vcpkg 'downloads') -File | Where-Object { $_.Name -match '\.(tar\.gz|tar\.xz|tar\.bz2|tgz|zip)$' } | Copy-Item -Destination $archives
Copy-Item $PSCommandPath (Join-Path $sources 'build-windows-guest-helpers.ps1')
$readme = @'
These sources correspond to the MacVM-built ARM64 VDAgent, VDService and
SPICE WebDAV helper plus its dynamically linked GLib dependencies. Upstream
source revisions, binary hashes and dependency receipts are in Provenance.json.
Extract each source tar. Run the supplied build script on a Windows ARM64
Visual Studio C++ host (or use the MacVM Windows guest helpers GitHub workflow).
The supplied vcpkg source tree contains exact ports and patches; its source
downloads are in dependency-archives. VDAgent's two submodule sources are
separate tar files. webdav-CMakeLists.txt is the only added upstream build file.
GLib DLLs remain dynamically linked and may be replaced with rebuilt versions.
Source archives contain no signing secrets or user credentials.
'@
Set-Content (Join-Path $sources 'README.txt') $readme -Encoding utf8
$binaries = @{}
Get-ChildItem $output -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object {
    $stream = [IO.File]::OpenRead($_.FullName)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c; $offset = $reader.ReadUInt32(); $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xaa64) { throw "Not ARM64: $($_.Name)." }
    } finally { $stream.Dispose() }
    $binaries[[IO.Path]::GetRelativePath($output,$_.FullName)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$provenance = @{
    schemaVersion=1; architecture='ARM64'; vdagent=$agentCommit; webdav=$webdavCommit; vcpkg=$vcpkgCommit
    spiceCommon='05c0c26839e88e6d0cc5452f49c40e38543c8f97'; spiceProtocol='ce0c4211e6f16c66477934cc42e70fa0988ca7f0'
    binaries=$binaries; dependencies=(Get-Content (Join-Path $vcpkg 'installed/vcpkg/status') -Raw)
}
$provenance | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $output 'Provenance.json') -Encoding utf8
Copy-Item (Join-Path $output 'Provenance.json') $sources
Compress-Archive -Path (Join-Path $sources '*') -DestinationPath (Join-Path $root 'dist/MacVM-Windows-Guest-Sources.zip') -CompressionLevel Optimal
Write-Host 'ARM64 helpers, matching sources and notices prepared.'
