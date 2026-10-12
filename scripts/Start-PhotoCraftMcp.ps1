# Start the native desktop control server, then forward MCP stdio unchanged.
[CmdletBinding()]
param(
    [string]$RuntimeDir = "$PSScriptRoot/../runtime",
    [string]$WorkspaceDir = "$PSScriptRoot/../workspace",
    [string]$StateDir = "$PSScriptRoot/../state",
    [ValidateRange(1024, 65535)][int]$Port = 17878,
    [ValidateRange(5, 180)][int]$StartupTimeoutSeconds = 60,
    [switch]$SafeGpu
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Platform.ps1"
$platform = Get-PhotoCraftPlatform
$app = (Resolve-Path -LiteralPath (Join-Path $RuntimeDir $platform.App)).Path
$cli = (Resolve-Path -LiteralPath (Join-Path $RuntimeDir $platform.Cli)).Path
New-Item -ItemType Directory -Force -Path $WorkspaceDir, $StateDir | Out-Null
$workspace = (Resolve-Path -LiteralPath $WorkspaceDir).Path
$state = (Resolve-Path -LiteralPath $StateDir).Path
$tokenFile = Join-Path $state 'control.token'

function Test-ControlReady {
    if (-not (Test-Path -LiteralPath $tokenFile)) { return $false }
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $connect.Wait(500)) { return $false }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1000
        $stream.WriteTimeout = 1000
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
            $writer.WriteLine((@{id='dsh-ready'; method='auth'; params=@{token=$token}} | ConvertTo-Json -Compress))
            $writer.Flush()
            $reply = $reader.ReadLine() | ConvertFrom-Json
            return $reply.ok -eq $true
        } finally { $writer.Dispose(); $reader.Dispose() }
    } catch { return $false }
    finally { $client.Dispose() }
}

# Different MCP clients and the DSH protocol probe may start concurrently.
$mutex = [System.Threading.Mutex]::new($false, "PhotoCraft-Dsh-$Port")
$held = $false
try {
    try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds($StartupTimeoutSeconds)) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Timed out waiting for PhotoCraft startup.' }
    if (-not (Test-ControlReady)) {
        $arguments = @('--control', "$Port", '--control-token-file', ('"' + $tokenFile + '"'),
            '--automation-read-root', ('"' + $workspace + '"'), '--automation-write-root', ('"' + $workspace + '"'))
        if ($SafeGpu) { $arguments += '--safe-gpu' }
        $launch = @{FilePath=$app; ArgumentList=$arguments; WorkingDirectory=(Split-Path $app);
            RedirectStandardOutput=(Join-Path $state 'app.stdout.log'); RedirectStandardError=(Join-Path $state 'app.stderr.log'); PassThru=$true}
        if ($IsWindows) { $launch.WindowStyle = 'Hidden' }
        else {
            # Preserve the desktop after the MCP client exits on Unix.
            $launch.FilePath = '/usr/bin/nohup'
            $launch.ArgumentList = @('"' + $app + '"') + $arguments
        }
        $appProcess = Start-Process @launch
        $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        while (-not (Test-ControlReady)) {
            if ($appProcess.HasExited) { throw "PhotoCraft exited with code $($appProcess.ExitCode). See $state/app.stderr.log" }
            if ([DateTime]::UtcNow -ge $deadline) { throw "PhotoCraft control startup timed out. See $state/app.stderr.log" }
            Start-Sleep -Milliseconds 200
        }
    }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

# Inherit the real stdio handles: PowerShell must not parse MCP frames.
$start = [System.Diagnostics.ProcessStartInfo]::new($cli)
$start.UseShellExecute = $false
foreach ($argument in @('mcp', '--bridge', "127.0.0.1:$Port", '--control-token-file', $tokenFile)) {
    $start.ArgumentList.Add($argument)
}
$server = [System.Diagnostics.Process]::Start($start)
try { $server.WaitForExit(); $result = $server.ExitCode }
finally { $server.Dispose() }
# Keep the desktop alive so disconnecting an agent cannot discard unsaved work.
exit $result
