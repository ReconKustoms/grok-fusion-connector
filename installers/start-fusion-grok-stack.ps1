#Requires -Version 5.1
# Hidden stack: Fusion MCP bridge + Cloudflare quick tunnel.
# Prints GROK_CONNECTOR_URL = https://<trycloudflare-host>/mcp
# Windows PowerShell 5.1+ (or pwsh 7+). Does not install Python or cloudflared.

$ErrorActionPreference = 'Stop'

$Listen = if ($env:BRIDGE_LISTEN) { $env:BRIDGE_LISTEN } else { '127.0.0.1' }
$Port = if ($env:BRIDGE_PORT) { $env:BRIDGE_PORT } else { '18782' }
$Upstream = if ($env:FUSION_MCP_UPSTREAM) { $env:FUSION_MCP_UPSTREAM } else { 'http://127.0.0.1:27182' }
$WaitSecs = 45
if ($env:TUNNEL_WAIT) {
    $WaitSecs = [int]$env:TUNNEL_WAIT
}

$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { $HomeDir = $env:HOME }
$State = $env:GROK_FUSION_STATE
if (-not $State) { $State = Join-Path $HomeDir '.grok\fusion-stack' }

if (-not (Test-Path -LiteralPath $State)) {
    New-Item -ItemType Directory -Path $State -Force | Out-Null
}

$Log = Join-Path $State 'cloudflared.log'
$UrlFile = Join-Path $State 'connector.url'
$PidBridge = Join-Path $State 'bridge.pid'
$PidCf = Join-Path $State 'cloudflared.pid'
$BridgeLog = Join-Path $State 'bridge.log'

function Get-Win32Processes {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        try {
            return @(Get-WmiObject Win32_Process -ErrorAction Stop)
        } catch {
            return @()
        }
    }
}

function Get-ChildProcessId {
    param(
        [int]$ParentId,
        [string]$NameMatch,
        [int]$Tries = 15
    )
    for ($i = 0; $i -lt $Tries; $i++) {
        Start-Sleep -Milliseconds 200
        foreach ($proc in (Get-Win32Processes)) {
            $ppid = 0
            try { $ppid = [int]$proc.ParentProcessId } catch { continue }
            if ($ppid -ne $ParentId) { continue }
            if ($proc.Name -match $NameMatch) {
                return [int]$proc.ProcessId
            }
        }
        if (-not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) {
            break
        }
    }
    return $null
}

function Find-ProcessIdByCommandLine {
    param(
        [string]$NameMatch,
        [string]$Needle
    )
    foreach ($proc in (Get-Win32Processes)) {
        if ($proc.Name -notmatch $NameMatch) { continue }
        if ($proc.CommandLine -and ($proc.CommandLine -like "*$Needle*")) {
            return [int]$proc.ProcessId
        }
    }
    return $null
}

function Resolve-StartedPid {
    param(
        [int]$WrapperId,
        [string]$NameMatch,
        [string]$CommandNeedle
    )
    $found = Get-ChildProcessId -ParentId $WrapperId -NameMatch $NameMatch
    if ($found) { return $found }
    $found = Find-ProcessIdByCommandLine -NameMatch $NameMatch -Needle $CommandNeedle
    if ($found) { return $found }
    if (Get-Process -Id $WrapperId -ErrorAction SilentlyContinue) {
        return $WrapperId
    }
    return $null
}

function Start-DetachedLogged {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath,
        [switch]$MergeErrorToOut
    )
    if ($StdoutPath) {
        $redirOut = '> "' + $StdoutPath + '"'
    } else {
        $redirOut = '>NUL'
    }
    if ($MergeErrorToOut) {
        $redirErr = '2>&1'
    } elseif ($StderrPath) {
        $redirErr = '2> "' + $StderrPath + '"'
    } else {
        $redirErr = '2>NUL'
    }
    $inner = '"{0}" {1} {2} {3}' -f $Exe, $Arguments, $redirOut, $redirErr
    $comspec = $env:ComSpec
    if (-not $comspec) { $comspec = 'cmd.exe' }
    return Start-Process -FilePath $comspec `
        -ArgumentList @('/d', '/s', '/c', ('"{0}"' -f $inner)) `
        -WorkingDirectory $State `
        -WindowStyle Hidden `
        -PassThru
}

function Resolve-BridgePath {
    $source = $PSCommandPath
    if (-not $source) { $source = $MyInvocation.MyCommand.Path }
    $guard = 0
    while ($source -and $guard -lt 10) {
        $guard++
        if (-not (Test-Path -LiteralPath $source)) { break }
        $item = Get-Item -LiteralPath $source -Force
        $isLink = $false
        if ($item.LinkType -eq 'SymbolicLink' -or $item.LinkType -eq 'Junction') {
            $isLink = $true
        } elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $isLink = $true
        }
        if (-not $isLink) { break }
        $target = $item.Target
        if ($target -is [array]) { $target = $target[0] }
        if (-not $target) { break }
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $item.DirectoryName $target
        }
        $source = $target
    }
    $scriptDir = Split-Path -Parent $source
    $root = Split-Path -Parent $scriptDir
    $candidates = @()
    if ($env:GROK_FUSION_LIBEXEC) {
        $candidates += (Join-Path $env:GROK_FUSION_LIBEXEC 'bridge\fusion_mcp_bridge.py')
    }
    $candidates += (Join-Path $root 'bridge\fusion_mcp_bridge.py')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Stop-PidFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return }
    $raw = Get-Content -LiteralPath $File -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item -LiteralPath $File -Force -ErrorAction SilentlyContinue
    $procId = 0
    if ([int]::TryParse(("$raw").Trim(), [ref]$procId) -and $procId -gt 0) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

function Get-TrycloudflareMcpUrl {
    if (-not (Test-Path -LiteralPath $Log)) { return $null }
    $content = $null
    try {
        $fs = [System.IO.File]::Open($Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($fs)
            try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
    if (-not $content) { return $null }
    $found = [regex]::Matches($content, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($found.Count -lt 1) { return $null }
    return ($found[$found.Count - 1].Value + '/mcp')
}

function Find-OnPath {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return $null
}

$Bridge = Resolve-BridgePath
if (-not $Bridge) {
    Write-Host 'missing fusion_mcp_bridge.py'
    exit 1
}

$Cloudflared = Find-OnPath -Names @('cloudflared', 'cloudflared.exe')
if (-not $Cloudflared) {
    Write-Host 'cloudflared required on PATH. Install it yourself, then reopen this terminal. This script does not install cloudflared.'
    exit 1
}

$Python = Find-OnPath -Names @('python', 'python.exe', 'python3', 'python3.exe')
if (-not $Python) {
    Write-Host 'python or python3 required on PATH. Install it yourself; this script does not install Python.'
    exit 1
}

Stop-PidFile -File $PidBridge
Stop-PidFile -File $PidCf

Set-Content -LiteralPath $Log -Value '' -Encoding ASCII
if (Test-Path -LiteralPath $UrlFile) {
    Remove-Item -LiteralPath $UrlFile -Force -ErrorAction SilentlyContinue
}

$bridgeArgs = ('"{0}" --listen {1} --port {2} --upstream {3}' -f $Bridge, $Listen, $Port, $Upstream)
$bridgeWrap = Start-DetachedLogged -Exe $Python -Arguments $bridgeArgs -StderrPath $BridgeLog
if (-not $bridgeWrap) {
    Write-Host 'bridge failed to start'
    exit 1
}
$bridgeId = Resolve-StartedPid -WrapperId $bridgeWrap.Id -NameMatch '^python' -CommandNeedle 'fusion_mcp_bridge.py'
if ($bridgeId) {
    Set-Content -LiteralPath $PidBridge -Value $bridgeId -Encoding ASCII
} else {
    Write-Host 'bridge failed to start'
    if (Test-Path -LiteralPath $BridgeLog) { Get-Content -LiteralPath $BridgeLog }
    exit 1
}

Start-Sleep -Milliseconds 400
if (-not (Get-Process -Id $bridgeId -ErrorAction SilentlyContinue)) {
    Write-Host 'bridge failed to start'
    if (Test-Path -LiteralPath $BridgeLog) { Get-Content -LiteralPath $BridgeLog }
    exit 1
}

$cfArgs = ('tunnel --no-autoupdate --url http://{0}:{1}' -f $Listen, $Port)
$cfWrap = Start-DetachedLogged -Exe $Cloudflared -Arguments $cfArgs -StdoutPath $Log -MergeErrorToOut
if (-not $cfWrap) {
    Write-Host "FAIL: cloudflared failed to start; see $Log"
    exit 1
}
$cfNeedle = ('--url http://{0}:{1}' -f $Listen, $Port)
$cfId = Resolve-StartedPid -WrapperId $cfWrap.Id -NameMatch 'cloudflared' -CommandNeedle $cfNeedle
if ($cfId) {
    Set-Content -LiteralPath $PidCf -Value $cfId -Encoding ASCII
} else {
    Write-Host "FAIL: cloudflared failed to start; see $Log"
    if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Tail 20 }
    exit 1
}

Write-Host "Waiting up to ${WaitSecs}s for trycloudflare hostname..."
$Url = $null
for ($i = 1; $i -le $WaitSecs; $i++) {
    $Url = Get-TrycloudflareMcpUrl
    if ($Url) { break }
    Start-Sleep -Seconds 1
}

if (-not $Url) {
    Write-Host "FAIL: no trycloudflare host in $Log"
    if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Tail 20 }
    exit 1
}

Set-Content -LiteralPath $UrlFile -Value $Url -Encoding ASCII
Write-Host ("GROK_CONNECTOR_URL={0}" -f $Url)

if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    try { Set-Clipboard -Value $Url } catch { }
} elseif (Get-Command clip.exe -ErrorAction SilentlyContinue) {
    try { $Url | & clip.exe } catch { }
}

Write-Host 'Stop: stop-fusion-grok-stack.ps1'
Write-Host ("PIDs: bridge={0} cloudflared={1}" -f (Get-Content -LiteralPath $PidBridge -Raw).Trim(), (Get-Content -LiteralPath $PidCf -Raw).Trim())
