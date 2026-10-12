# Install a pinned upstream runtime without changing DSH profiles or user data.
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallDir = $(if ($env:PHOTOCRAFT_DSH_HOME) { $env:PHOTOCRAFT_DSH_HOME } else { Join-Path $env:LOCALAPPDATA 'dsh-photocraft' }),
    [string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This release supports Windows x64 only.'
}
$version = '0.7.0'
$expectedHash = '331e3111ed068b3f41df7d44401c3b51a312abde393e5829a4f24df2c9405b87'
$asset = "photocraft-$version-windows-x64-portable.zip"
$url = "https://github.com/storytold/photocraft/releases/download/v$version/$asset"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$install = (Resolve-Path -LiteralPath $InstallDir).Path
$runtime = Join-Path $install 'runtime'
$receiptPath = Join-Path $install 'installation.json'
$existing = Test-Path -LiteralPath $runtime
if ($existing) {
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'Existing runtime has no installation receipt. Use a new InstallDir; it will not be overwritten.' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.version -ne $version -or $receipt.archiveSha256 -ne $expectedHash) { throw 'Existing runtime differs from this pinned release. Use a new InstallDir.' }
    foreach ($name in @('photocraft.exe','photocraft-cli.exe')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $receipt.executables.$name) { throw "Installed $name has changed. Use a new InstallDir for a verified installation." }
    }
} else {
    New-Item -ItemType Directory -Force -Path (Join-Path $install 'downloads') | Out-Null
    if (-not $ArchivePath) {
        $ArchivePath = Join-Path $install "downloads/$asset"
        if (-not (Test-Path -LiteralPath $ArchivePath)) {
            Write-Host "Downloading PhotoCraft $version..."
            Invoke-WebRequest -Uri $url -Headers @{'User-Agent'='Photocraft-dev'} -OutFile $ArchivePath
        }
    }
    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Archive SHA-256 mismatch. Nothing was extracted or executed. Obtain the official pinned archive.' }
    $staging = Join-Path $install ('extract-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging
    $extracted = Join-Path $staging "photocraft-$version-windows-x64-portable"
    foreach ($name in @('photocraft.exe','photocraft-cli.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $extracted $name))) { throw "Archive is missing $name" }
    }
    # Refuse any computed move outside the selected installation.
    $prefix = $install.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($candidate in @($extracted, $runtime, $staging)) {
        if (-not [System.IO.Path]::GetFullPath($candidate).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Runtime path escaped the installation directory.'
        }
    }
    Move-Item -LiteralPath $extracted -Destination $runtime
    Remove-Item -LiteralPath $staging
    $hashes = @{}
    foreach ($name in @('photocraft.exe','photocraft-cli.exe')) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    @{version=$version; source=$url; archiveSha256=$expectedHash; executables=$hashes} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8
}
New-Item -ItemType Directory -Force -Path "$install/scripts", "$install/workspace", "$install/state" | Out-Null
foreach ($name in @('Start-PhotoCraftMcp.ps1','Test-PhotoCraftMcp.ps1')) {
    $source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot $name)).Path
    $destination = Join-Path $install "scripts/$name"
    if ($source -ne $destination) { Copy-Item -LiteralPath $source -Destination $destination -Force }
}
& (Join-Path $runtime 'photocraft-cli.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Installed PhotoCraft CLI failed to start.' }
Write-Host "Installed: $install"
Write-Host "Images: $install/workspace"
Write-Host 'Install the dsh-photocraft bundle into the desired DSH profile, then restart DSH.'
