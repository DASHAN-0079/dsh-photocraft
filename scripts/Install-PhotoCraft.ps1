# Install verified upstream files without replacing existing user data.
#Requires -Version 7.0
[CmdletBinding()]
param([string]$InstallDir, [string]$ArchivePath, [string]$CliArchivePath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Platform.ps1"
$platform = Get-PhotoCraftPlatform
if (-not $InstallDir) { $InstallDir = Get-PhotoCraftHome }
$version = '0.7.0'
$release = 'https://github.com/storytold/photocraft/releases/download/v0.7.0'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$install = (Resolve-Path -LiteralPath $InstallDir).Path
$runtime = Join-Path $install 'runtime'
$receiptPath = Join-Path $install 'installation.json'
function Get-VerifiedArchive([string]$Path, [string]$Asset, [string]$Hash) {
    if (-not $Path) {
        New-Item -ItemType Directory -Force -Path "$install/downloads" | Out-Null
        $Path = Join-Path $install "downloads/$Asset"
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "Downloading $Asset..."
            Invoke-WebRequest -Uri "$release/$Asset" -Headers @{'User-Agent'='Photocraft-dev'} -OutFile $Path
        }
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        throw 'Archive SHA-256 mismatch. Nothing was extracted or executed. Obtain the official pinned archive.'
    }
    return (Resolve-Path -LiteralPath $Path).Path
}
function Assert-InstallPath([string]$Path) {
    $prefix = $install.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not [System.IO.Path]::GetFullPath($Path).StartsWith($prefix, $comparison)) { throw 'Runtime path escaped the installation directory.' }
}
if (Test-Path -LiteralPath $runtime) {
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'Existing runtime has no installation receipt. Use a new InstallDir; it will not be overwritten.' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.version -ne $version -or $receipt.archiveSha256 -ne $platform.Hash) { throw 'Existing runtime differs from this release. Use a new InstallDir.' }
    foreach ($name in @($platform.App, $platform.Cli)) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $receipt.executables.$name) { throw "Installed $name has changed. Use a new InstallDir for a verified installation." }
    }
} else {
    $ArchivePath = Get-VerifiedArchive $ArchivePath $platform.Archive $platform.Hash
    if ($IsMacOS) { $CliArchivePath = Get-VerifiedArchive $CliArchivePath $platform.CliArchive $platform.CliHash }
    $staging = Join-Path $install ('extract-' + [guid]::NewGuid().ToString('N'))
    Assert-InstallPath $staging
    New-Item -ItemType Directory -Path $staging | Out-Null
    if ($IsWindows) {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging
        $extracted = Join-Path $staging 'photocraft-0.7.0-windows-x64-portable'
    } else {
        $extracted = Join-Path $staging 'photocraft-cli-0.7.0-macos-universal'
        & /usr/bin/ditto -x -k $CliArchivePath $staging
        if ($LASTEXITCODE -ne 0) { throw 'CLI archive extraction failed.' }
        $mount = Join-Path $staging 'mount'
        New-Item -ItemType Directory -Path $mount | Out-Null
        & /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint $mount $ArchivePath | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not mount the verified PhotoCraft DMG.' }
        try {
            & /usr/bin/ditto (Join-Path $mount 'PhotoCraft.app') (Join-Path $extracted 'PhotoCraft.app')
            if ($LASTEXITCODE -ne 0) { throw 'App bundle copy failed.' }
            & /usr/bin/codesign --verify --deep --strict (Join-Path $extracted 'PhotoCraft.app')
            if ($LASTEXITCODE -ne 0) { throw 'PhotoCraft.app signature verification failed.' }
            & /usr/bin/codesign --verify --strict (Join-Path $extracted $platform.Cli)
            if ($LASTEXITCODE -ne 0) { throw 'PhotoCraft CLI signature verification failed.' }
        } finally {
            & /usr/bin/hdiutil detach $mount | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Could not unmount $mount; unmount it before retrying." }
        }
        Remove-Item -LiteralPath $mount
    }
    foreach ($name in @($platform.App, $platform.Cli)) {
        if (-not (Test-Path -LiteralPath (Join-Path $extracted $name))) { throw "Archive is missing $name" }
    }
    foreach ($candidate in @($extracted, $runtime)) { Assert-InstallPath $candidate }
    Move-Item -LiteralPath $extracted -Destination $runtime
    # Leave optional ZIP metadata in staging rather than deleting recursively.
    if (@(Get-ChildItem -LiteralPath $staging -Force).Count -eq 0) { Remove-Item -LiteralPath $staging }
    $hashes = @{}
    foreach ($name in @($platform.App, $platform.Cli)) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    @{version=$version; platform=$platform.Name; source="$release/$($platform.Archive)"; archiveSha256=$platform.Hash; cliArchiveSha256=$platform.CliHash; executables=$hashes} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8
}
New-Item -ItemType Directory -Force -Path "$install/scripts", "$install/workspace", "$install/state" | Out-Null
foreach ($name in @('Platform.ps1','Start-PhotoCraftMcp.ps1','Test-PhotoCraftMcp.ps1')) {
    $source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot $name)).Path
    $destination = Join-Path $install "scripts/$name"
    if ($source -ne $destination) { Copy-Item -LiteralPath $source -Destination $destination -Force }
}
& (Join-Path $runtime $platform.Cli) --version
if ($LASTEXITCODE -ne 0) { throw 'Installed PhotoCraft CLI failed to start.' }
Write-Host "Installed: $install"
Write-Host "Images: $install/workspace"
Write-Host 'Install the dsh-photocraft bundle into the desired DSH profile, then restart DSH.'
