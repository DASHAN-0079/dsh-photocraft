# Exercise the installed MCP transports with synthetic images only.
[CmdletBinding()]
param(
    [string]$InstallDir,
    [ValidateRange(1024,65535)][int]$Port = 17878
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Platform.ps1"
$platform = Get-PhotoCraftPlatform
if (-not $InstallDir) { $InstallDir = Get-PhotoCraftHome }
$install = (Resolve-Path -LiteralPath $InstallDir).Path
$workspace = Join-Path $install 'workspace'
$checks = [System.Collections.Generic.List[object]]::new()
$covered = [System.Collections.Generic.HashSet[string]]::new()

function Invoke-Rpc($Connection, [string]$Method, [hashtable]$Params) {
    $Connection.Sequence++
    $frame = @{jsonrpc='2.0'; id=$Connection.Sequence; method=$Method; params=$Params}
    $Connection.Process.StandardInput.WriteLine(($frame | ConvertTo-Json -Depth 30 -Compress))
    $Connection.Process.StandardInput.Flush()
    while ($true) {
        $read = $Connection.Process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait(90000)) { throw "MCP timeout: $Method" }
        if ($null -eq $read.Result) { throw "MCP exited during $Method" }
        $reply = $read.Result | ConvertFrom-Json -Depth 100
        if ($reply.id -eq $Connection.Sequence) {
            if ($reply.error) { throw ($reply.error | ConvertTo-Json -Compress) }
            return $reply.result
        }
    }
}
function Start-Mcp([string]$Executable, [string[]]$Arguments) {
    $start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($start)
    $connection = @{Process=$process; Sequence=0; Errors=$process.StandardError.ReadToEndAsync()}
    try {
        $connection.Info = Invoke-Rpc $connection 'initialize' @{protocolVersion='2024-11-05'; capabilities=@{}; clientInfo=@{name='photocraft-dsh-test'; version='1'}}
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $process.StandardInput.Flush()
        return $connection
    } catch { $process.Kill($true); $process.Dispose(); throw }
}
function Stop-Mcp($Connection) {
    $Connection.Process.StandardInput.Close()
    if (-not $Connection.Process.WaitForExit(10000)) { $Connection.Process.Kill($true) }
    $Connection.Process.Dispose()
}
function Invoke-Tool($Connection, [string]$Name, [hashtable]$Arguments = @{}, [switch]$ExpectError) {
    $result = Invoke-Rpc $Connection 'tools/call' @{name=$Name; arguments=$Arguments}
    if ([bool]$result.isError -ne [bool]$ExpectError) { throw "$Name returned unexpected result: $($result | ConvertTo-Json -Depth 8 -Compress)" }
    $checks.Add(@{tool=$Name; arguments=$Arguments; expectedError=[bool]$ExpectError; passed=$true})
    $null = $covered.Add($Name)
    return $result
}
function Invoke-Command($Connection, [string]$Id, [hashtable]$Params = @{}) {
    $null = Invoke-Tool $Connection 'command_run' @{id=$Id; params=$Params}
}
function Save-Preview($Result, [string]$Path) {
    $image = @($Result.content | Where-Object type -eq 'image')[0]
    $bytes = [Convert]::FromBase64String($image.data)
    if ($bytes.Length -lt 8 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A') { throw 'Invalid PNG preview' }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

$headless = Start-Mcp (Join-Path "$install/runtime" $platform.Cli) @('mcp','--automation-read-root',$workspace,'--automation-write-root',$workspace)
try {
    $tools = (Invoke-Rpc $headless 'tools/list' @{}).tools
    $commands = (Invoke-Tool $headless 'command_list').content[0].text | ConvertFrom-Json -Depth 100
    if (@($commands.id | Sort-Object -Unique).Count -ne $commands.Count) { throw 'Duplicate command IDs' }
    $null = Invoke-Tool $headless 'session_list'
    $null = Invoke-Tool $headless 'doc_new' @{width=256; height=192; name='DSH validation'; background='#f4e8d2'}
    Invoke-Command $headless 'layer.new.layer' @{name='Paint'}
    Invoke-Command $headless 'edit.fill' @{color='#285d82'}
    Invoke-Command $headless 'image.adjustments.brightnessContrast' @{brightness=10; contrast=15}
    Invoke-Command $headless 'filter.blur.gaussianBlur' @{radius=2}
    Invoke-Command $headless 'edit.undo'
    Invoke-Command $headless 'edit.redo'
    $null = Invoke-Tool $headless 'command_batch' @{steps=@(
        @{id='shape.create'; params=@{kind='ellipse'; rect=@(30,25,130,90); fill='#f8c46b'}},
        @{id='type.create'; params=@{x=20; y=155; text='PhotoCraft + DSH'; size=18; color='#ffffff'}})}
    $null = Invoke-Tool $headless 'doc_inspect'
    $null = Invoke-Tool $headless 'doc_save' @{path='validated.pcraft'}
    foreach ($format in @('png','jpg','webp','tif','psd','psb','ora','exr')) {
        $null = Invoke-Tool $headless 'doc_export' @{path="validated.$format"}
        if ((Get-Item -LiteralPath (Join-Path $workspace "validated.$format")).Length -eq 0) { throw "Empty $format export" }
        $null = Invoke-Tool $headless 'doc_open' @{path="validated.$format"}
        $null = Invoke-Tool $headless 'doc_close'
    }
    foreach ($name in @('doc_render_preview','render_preview')) {
        Save-Preview (Invoke-Tool $headless $name @{max_side=400}) (Join-Path $workspace 'headless-preview.png')
    }
    $null = Invoke-Tool $headless 'doc_open' @{path='validated.pcraft'}
    $null = Invoke-Tool $headless 'doc_select' @{index=0}
    $null = Invoke-Tool $headless 'doc_close' @{index=1}
    $null = Invoke-Tool $headless 'jobs_list'
    $null = Invoke-Tool $headless 'jobs_cancel'
    foreach ($mode in @('rgb','gray','cmyk','lab')) {
        foreach ($depth in @(8,16,32)) {
            $null = Invoke-Tool $headless 'doc_new' @{width=32; height=24; mode=$mode; depth=$depth; name="$mode-$depth"}
            Invoke-Command $headless 'image.adjustments.brightnessContrast' @{brightness=5}
            $null = Invoke-Tool $headless 'doc_save' @{path="$mode-$depth.pcraft"}
            $null = Invoke-Tool $headless 'doc_close'
        }
    }
    $null = Invoke-Tool $headless 'command_run' @{id='does.not.exist'} -ExpectError
    $null = Invoke-Tool $headless 'command_run' @{id='filter.blur.gaussianBlur'; params=@{radius='invalid'}} -ExpectError
    $null = Invoke-Tool $headless 'doc_open' @{path='../outside.png'} -ExpectError
    $null = Invoke-Tool $headless 'doc_save' @{path='../outside.pcraft'} -ExpectError
    $null = Invoke-Tool $headless 'session_list'
    foreach ($resource in (Invoke-Rpc $headless 'resources/list' @{}).resources) {
        $null = Invoke-Rpc $headless 'resources/read' @{uri=$resource.uri}
    }
} finally { Stop-Mcp $headless }

$bridgeArguments = @('-NoProfile','-NonInteractive','-File',"$PSScriptRoot/Start-PhotoCraftMcp.ps1",'-RuntimeDir',"$install/runtime",'-WorkspaceDir',$workspace,'-StateDir',"$install/state",'-Port',"$Port",'-SafeGpu')
$bridge = Start-Mcp (Get-Process -Id $PID).Path $bridgeArguments
try {
    $null = Invoke-Tool $bridge 'doc_new' @{width=256; height=192; name='DSH desktop validation'}
    $null = Invoke-Tool $bridge 'ui_inspect'
    $null = Invoke-Tool $bridge 'ui_set' @{fields=@{tool='brush'; zoom=2}}
    $null = Invoke-Tool $bridge 'ui_pointer' @{events=@(
        @{kind='down'; x=30; y=30; pressure=1}, @{kind='move'; x=180; y=120; pressure=1}, @{kind='up'; x=180; y=120; pressure=1})}
    $null = Invoke-Tool $bridge 'ui_menu_invoke' @{id='edit.undo'}
    Invoke-Command $bridge 'edit.redo'
    $null = Invoke-Tool $bridge 'control_call' @{method='ui.menu.list'; params=@{}}
    $null = Invoke-Tool $bridge 'doc_save' @{path='desktop-validated.pcraft'}
    Save-Preview (Invoke-Tool $bridge 'ui_screenshot' @{max_side=1200}) (Join-Path $workspace 'desktop-preview.png')
} finally { Stop-Mcp $bridge }
foreach ($tool in $tools) { if (-not $covered.Contains($tool.name)) { throw "Untested MCP tool: $($tool.name)" } }
$report = @{version=$headless.Info.serverInfo.version; commandsDiscovered=$commands.Count; toolsCovered=@($covered | Sort-Object); passedChecks=$checks.Count; checks=$checks.ToArray()}
$report | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8 (Join-Path $install 'validation.json')
Write-Output "Passed $($checks.Count) checks; $($covered.Count) MCP tools; $($commands.Count) commands discovered."
