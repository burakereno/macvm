# Install the official ARM64 integration helpers only after verifying the entire
# app-owned payload. No firewall, UAC or Windows hardware checks are disabled.
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:ProgramFiles 'MacVM Windows Tools'
function Checked([string] $File, [string[]] $Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010, 1638)) { throw "$File failed ($($process.ExitCode))." }
}
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Right-click Install.cmd and choose Run as administrator.' }
    $hashes = Get-Content -LiteralPath 'PayloadHashes.json' -Raw | ConvertFrom-Json
    foreach ($entry in $hashes.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath $entry.Name -Algorithm SHA256).Hash -ne $entry.Value) { throw "Checksum mismatch: $($entry.Name). Nothing was installed." }
    }
    foreach ($catalog in @('Drivers\Serial\vioser.cat', 'Drivers\Network\netkvm.cat', 'viogpudo.cat')) {
        $signature = Get-AuthenticodeSignature -LiteralPath $catalog
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') { throw "Invalid Microsoft driver signature: $catalog." }
    }
    $service = Get-CimInstance Win32_Service -Filter "Name='vdservice'"
    if ($service -and $service.PathName -notlike ('*' + $destination + '*')) { throw 'Another product already manages SPICE VDAgent. Keep its installation; do not replace its service with MacVM.' }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Start-Transcript -Path (Join-Path $destination 'Install.log') -Append | Out-Null
    foreach ($inf in @('Drivers\Serial\vioser.inf','Drivers\Network\netkvm.inf')) {
        & pnputil.exe /add-driver $inf /install | Out-Host
        if ($LASTEXITCODE -notin @(0, 259, 3010)) { throw "Driver installation failed ($LASTEXITCODE): $inf." }
    }
    $runtimeDLL = Join-Path $env:windir 'System32\vcruntime140.dll'
    $cppDLL = Join-Path $env:windir 'System32\msvcp140.dll'
    $runtimeReady = (Test-Path -LiteralPath $runtimeDLL) -and (Test-Path -LiteralPath $cppDLL)
    if ($runtimeReady) {
        $info = (Get-Item -LiteralPath $runtimeDLL).VersionInfo
        $minimum = [Version](Get-Content -LiteralPath 'SourceInfo.json' -Raw | ConvertFrom-Json).minimumRuntime
        $runtimeReady = [Version]::new($info.FileMajorPart,$info.FileMinorPart) -ge $minimum
    }
    if (!$runtimeReady) {
        Write-Host 'The Microsoft ARM64 Visual C++ runtime is required. Its installer will open; review the licence and install it.'
        $temporary = Join-Path $env:LOCALAPPDATA ('Temp\MacVM-Runtime-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $temporary | Out-Null
        try {
            $runtimeFile = Join-Path $temporary 'vc_redist.arm64.exe'
            Invoke-WebRequest -Uri 'https://aka.ms/vc14/vc_redist.arm64.exe' -OutFile $runtimeFile -UseBasicParsing
            $signature = Get-AuthenticodeSignature -LiteralPath $runtimeFile
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'Invalid Microsoft Visual C++ runtime signature.' }
            Checked $runtimeFile @('/install', '/norestart')
        } finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    if ($service) { Stop-Service vdservice -ErrorAction Stop }
    foreach ($process in @(Get-Process vdagent -ErrorAction SilentlyContinue)) {
        if ($process.Path -eq (Join-Path $destination 'vdagent.exe')) { Stop-Process -Id $process.Id -ErrorAction Stop; if (!$process.WaitForExit(5000)) { throw 'The clipboard helper did not stop.' } }
    }
    foreach ($name in @('vdagent.exe','vdservice.exe')) {
        $target = Join-Path $destination $name
        if (!(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $name).Hash) { Copy-Item -LiteralPath $name -Destination $target -Force }
    }
    if (!$service) {
        New-Service -Name vdservice -BinaryPathName ('"' + (Join-Path $destination 'vdservice.exe') + '"') -DisplayName 'MacVM Clipboard Integration' -StartupType Automatic | Out-Null
    }
    Start-Service vdservice
    (Get-Service vdservice).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    Write-Host 'Installing the ARM64 shared-folder helper...'
    $webdavDestination = Join-Path $destination 'WebDAV'
    $existingWebdav = Get-CimInstance Win32_Service -Filter "Name='spice-webdavd'"
    if ($existingWebdav -and $existingWebdav.PathName -notlike ('*' + $webdavDestination + '*')) { throw 'Another product manages SPICE WebDAV. Remove its folder helper in Windows Installed Apps before installing MacVM sharing.' }
    if ($existingWebdav) {
        Stop-Service spice-webdavd -ErrorAction Stop
        (Get-Service spice-webdavd).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
    New-Item -ItemType Directory -Force -Path $webdavDestination | Out-Null
    Copy-Item -Path 'WebDAV\*' -Destination $webdavDestination -Force
    Copy-Item -Path 'Licenses' -Destination $destination -Recurse -Force
    Copy-Item -LiteralPath 'SourceProvenance.json','SourceInfo.json' -Destination $destination -Force
    if (!$existingWebdav) {
        New-Service -Name spice-webdavd -BinaryPathName ('"' + (Join-Path $webdavDestination 'spice-webdavd.exe') + '" -p 9843') -DisplayName 'MacVM Selected Folder Sharing' -StartupType Automatic | Out-Null
    }
    $webClient = Get-Service WebClient -ErrorAction SilentlyContinue
    if (!$webClient) { throw 'Windows WebClient is unavailable. Install Windows WebDAV client support before using shared folders.' }
    Set-Service WebClient -StartupType Manual
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters' -Name FileSizeLimitInBytes -Value 134217728 -PropertyType DWord -Force | Out-Null
    Start-Service WebClient
    $webdav = Get-Service 'spice-webdavd' -ErrorAction Stop
    if ($webdav.Status -ne 'Running') { Start-Service $webdav }
    $webdav.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    Write-Host 'Clipboard and folder helpers installed. Restart Windows after display setup.'
    Write-Host 'Select shared folders and clipboard access in MacVM Machine Settings.'
    Write-Host 'Open \\localhost@9843\DavWWWRoot in Windows Explorer for selected folders.'
    Stop-Transcript | Out-Null
    exit 0
} catch {
    Write-Host "Integration installation stopped: $($_.Exception.Message)" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
