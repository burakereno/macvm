# Run by Install.cmd. All payloads are pinned before any system change.
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:ProgramFiles 'MacVM Display Tools'
$version = '100.100.104.27100'
$fallbackKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\BasicDisplay'
$expected = @{
    'vgpusrv.exe' = '396b50c643a55745a7f05023d83bf4f1d82b38a4e22594cfc603827b42f79e07'
    'viogpuap.exe' = '2ed3d0678fa009f30029de5d6dfb66d41efd7e8439da837f40649eb2c801bdca'
    'viogpudo.cat' = 'c4f11ed462623bd15c132b229c99b6911442a63848409c5d2ca51b168a85c2bf'
    'viogpudo.inf' = '4304b94e6b108bab81ac50d96171255872afeab49d501b91d898bab90b093507'
    'viogpudo.sys' = '99b233551b76469d9b18b1f015b7c27ff5337c7854513470222ed770e447b643'
}
function Invoke-Checked([string] $File, [string[]] $Arguments) {
    & $File @Arguments | Out-Host
    # PnPUtil can report success with a required restart.
    if ($LASTEXITCODE -notin @(0, 3010)) { throw "$File failed ($LASTEXITCODE)." }
}
function Get-GpuDriver {
    @(Get-CimInstance Win32_PnPSignedDriver | Where-Object {
        $_.DeviceID -like 'PCI\VEN_1AF4&DEV_1050*'
    })
}
try {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Right-click Install.cmd and choose Run as administrator.'
    }
    foreach ($name in $expected.Keys) {
        if ((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash -ne $expected[$name]) {
            throw "Checksum mismatch: $name. No software was installed."
        }
    }
    foreach ($name in @('vgpusrv.exe', 'viogpuap.exe', 'viogpudo.cat')) {
        $signature = Get-AuthenticodeSignature -LiteralPath $name
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
            throw "Invalid Microsoft hardware signature: $name. No software was installed."
        }
    }
    $drivers = @(Get-GpuDriver)
    if ($drivers.Count -ne 1) { throw 'Expected one VirtIO GPU. No software was installed.' }
    $driver = $drivers[0]
    if ($driver.DriverVersion -notin @($version, '22.7.38.43', $null, '') -and $driver.DriverProviderName -notmatch '^Microsoft( Corporation)?$') {
        throw "Unsupported installed driver version $($driver.DriverVersion). Keep the current driver; contact MacVM support."
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $statePath = Join-Path $destination 'DriverMigration.json'
    if ($driver.DriverVersion -eq '22.7.38.43') {
        # The old driver cannot safely be removed while its kernel service runs.
        # Stage/export first, then require a real Restart (Fast Startup is not enough).
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if (!(Test-Path -LiteralPath $statePath)) {
            $backup = Join-Path $destination 'Previous Driver'
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
            Invoke-Checked pnputil.exe @('/export-driver', $driver.InfName, $backup)
            Invoke-Checked pnputil.exe @('/add-driver', (Join-Path (Get-Location) 'viogpudo.inf'))
            @{ Inf = $driver.InfName; Boot = $boot; Device = $driver.DeviceID } |
                ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
            try {
                # Ensure the firmware screen works while the old driver is off.
                New-Item -Path $fallbackKey -Force | Out-Null
                New-ItemProperty -Path $fallbackKey -Name DisableBasicDisplayFallback -Value 0 -PropertyType DWord -Force | Out-Null
                Invoke-Checked sc.exe @('config', 'VioGpuDod', 'start=', 'disabled')
            }
            catch { Remove-Item -LiteralPath $statePath; throw }
            Write-Host 'Step 1 complete. Restart Windows, then run this installer again.'
            Write-Host 'Use Restart, not Shut down. Low resolution during this step is expected.'
            Write-Host 'To cancel migration: sc.exe config VioGpuDod start= demand'
            exit 10
        }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.Device -ne $driver.DeviceID -or $state.Inf -ne $driver.InfName) {
            throw 'The GPU changed during migration. No driver was removed.'
        }
        $kernel = Get-CimInstance Win32_SystemDriver -Filter "Name='VioGpuDod'"
        if ($state.Boot -eq $boot -or $kernel.State -eq 'Running') {
            throw 'Restart Windows before continuing. The previous display driver is still loaded.'
        }
        Invoke-Checked pnputil.exe @('/delete-driver', $driver.InfName, '/uninstall')
    }
    # Do not reinstall an already active matching driver. PnPUtil returns 259
    # (no new devices) for this case on Windows ARM64.
    if ($driver.DriverVersion -ne $version) {
        Invoke-Checked pnputil.exe @('/add-driver', (Join-Path (Get-Location) 'viogpudo.inf'), '/install')
    }
    Invoke-Checked sc.exe @('config', 'VioGpuDod', 'start=', 'demand')
    $installed = @(Get-GpuDriver)
    if ($installed.Count -ne 1 -or $installed[0].DriverVersion -ne $version) {
        throw 'Windows has not activated the matching display driver. Restart and run this installer again.'
    }
    $device = Get-PnpDevice -InstanceId $installed[0].DeviceID
    if ($device.Status -ne 'OK') {
        throw 'The display driver is not ready. Restart and run this installer again; the fallback display was kept enabled.'
    }
    $service = Get-Service vgpusrv -ErrorAction SilentlyContinue
    if ($service) { Stop-Service vgpusrv -ErrorAction Stop }
    # The service can leave its per-user child alive after stopping. Only stop
    # our installed helper, never a same-named process from another product.
    $helperPath = Join-Path $destination 'viogpuap.exe'
    foreach ($process in @(Get-Process viogpuap -ErrorAction SilentlyContinue)) {
        if ($process.Path -eq $helperPath) {
            Stop-Process -Id $process.Id -ErrorAction Stop
            if (!$process.WaitForExit(5000)) { throw 'The previous resolution helper did not stop.' }
        }
    }
    foreach ($name in @('vgpusrv.exe', 'viogpuap.exe', 'LICENSE.txt')) {
        $target = Join-Path $destination $name
        if (!(Test-Path -LiteralPath $target) -or
            (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $name).Hash) {
            Copy-Item -LiteralPath $name -Destination $destination -Force
        }
    }
    if (!$service) {
        Invoke-Checked (Join-Path $destination 'vgpusrv.exe') @('-i')
    } else {
        Start-Service vgpusrv
    }
    $service = Get-Service vgpusrv
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    # On ARM64, Basic Display otherwise remains a second adapter. It can own
    # the login screen and prevent viogpuap from finding the VirtIO GPU.
    # This is the same setting used by UTM's official driver installer.
    New-Item -Path $fallbackKey -Force | Out-Null
    New-ItemProperty -Path $fallbackKey -Name DisableBasicDisplayFallback -Value 1 -PropertyType DWord -Force | Out-Null
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    Write-Host 'Matching ARM64 display driver and resolution service installed.'
    Write-Host 'Restart Windows. Then resize MacVM and enter/leave full screen.'
    Write-Host 'Set Windows Settings > System > Display > Scale to 200% for Retina.'
    Write-Host 'The previous driver backup, if any, is in Program Files\MacVM Display Tools.'
    exit 0
} catch {
    Write-Host "Installation stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No restart or forced shutdown was performed. Review this message before retrying.'
    exit 1
}
