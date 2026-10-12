# Offline package checks. Integration testing is a separate explicit operation.
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$PSScriptRoot/Platform.ps1"
foreach ($system in @('windows','macos')) {
    foreach ($architecture in $(if ($system -eq 'windows') {@('X64')} else {@('X64','Arm64')})) {
        $platform = Get-PhotoCraftPlatform -System $system -Architecture $architecture
        if ($platform.Hash -notmatch '^[a-f0-9]{64}$') { throw 'Missing archive pin' }
        if ($system -eq 'macos' -and ($platform.Cli -ne 'photocraft-cli' -or $platform.CliHash -notmatch '^[a-f0-9]{64}$')) { throw 'Invalid Mac runtime definition' }
    }
}
foreach ($pair in @(@('windows','Arm64'), @('linux','X64'))) {
    $refused = $false
    try { $null = Get-PhotoCraftPlatform -System $pair[0] -Architecture $pair[1] } catch { $refused = $true }
    if (-not $refused) { throw 'Unsupported platform accepted' }
}
$manifest = Get-Content -LiteralPath "$root/package.json" -Raw | ConvertFrom-Json
if ($manifest.name -ne 'dsh-photocraft' -or $manifest.dsh.bundle.patch -ne './cordis.patch.yml') { throw 'Invalid bundle manifest' }
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
$patch = Get-Content -LiteralPath "$root/cordis.patch.yml" -Raw
foreach ($name in @('photocraft','photocraft_ui')) {
    if ($patch -notmatch "serverName: $name\r?\n") { throw "Missing $name namespace" }
}
if ($patch -match '(?i)[A-Z]:[/\\]Users[/\\]|control\.token|[a-f0-9]{64}') { throw 'Machine path or credential in public configuration' }
if ($manifest.scripts.postinstall -or $manifest.scripts.install -or $manifest.scripts.prepare) { throw 'Installation must not execute lifecycle downloads' }
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-photocraft-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$archive = Join-Path $testRoot 'invalid.zip'
Set-Content -LiteralPath $archive -Value 'not the official archive'
$rejected = $false
try { & "$PSScriptRoot/Install-PhotoCraft.ps1" -InstallDir "$testRoot/install" -ArchivePath $archive }
catch {
    if ($_.Exception.Message -notmatch 'SHA-256 mismatch') { throw }
    $rejected = $true
}
if (-not $rejected -or (Test-Path "$testRoot/install/runtime")) { throw 'Invalid archive was accepted' }
Write-Output 'PASS: manifest, PowerShell syntax, portable configuration, no lifecycle downloads, invalid archive rejected.'
