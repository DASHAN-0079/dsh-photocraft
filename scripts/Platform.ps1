# Shared paths keep the installer, launcher, and tests on the same runtime.
function Get-PhotoCraftHome {
    if ($env:PHOTOCRAFT_DSH_HOME) { return $env:PHOTOCRAFT_DSH_HOME }
    if ($IsWindows) { return Join-Path $env:LOCALAPPDATA 'dsh-photocraft' }
    if ($IsMacOS) { return Join-Path $env:HOME 'Library/Application Support/dsh-photocraft' }
    throw 'Supported platforms: Windows x64 and macOS Intel/Apple Silicon.'
}
function Get-PhotoCraftPlatform {
    param([string]$System = $(if ($IsWindows) {'windows'} elseif ($IsMacOS) {'macos'} else {'unsupported'}),
          [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())
    if ($System -eq 'windows' -and $Architecture -eq 'X64') {
        return @{ Name='windows-x64'; App='photocraft.exe'; Cli='photocraft-cli.exe';
            Archive='photocraft-0.7.0-windows-x64-portable.zip'; Hash='331e3111ed068b3f41df7d44401c3b51a312abde393e5829a4f24df2c9405b87' }
    }
    if ($System -eq 'macos' -and $Architecture -in @('X64','Arm64')) {
        return @{ Name='macos-universal'; App='PhotoCraft.app/Contents/MacOS/PhotoCraft'; Cli='photocraft-cli';
            Archive='photocraft-0.7.0-macos-universal.dmg'; Hash='cd04389f15518c6208ef3a1e4b9b16f9edbbd1ece3fa63f7876b5d8d411c8a4a';
            CliArchive='photocraft-cli-0.7.0-macos-universal.zip'; CliHash='caf41eee1827ef740bc4495fb1fee77f6a4e0be82fb131106ad06cd591fd8091' }
    }
    throw "Unsupported platform: $System/$Architecture. Supported: Windows x64 and macOS Intel/Apple Silicon."
}
