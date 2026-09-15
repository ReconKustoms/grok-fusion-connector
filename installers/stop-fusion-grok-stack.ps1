#Requires -Version 5.1
# Kill hidden bridge + cloudflared started by start-fusion-grok-stack.ps1
# Windows PowerShell 5.1+ (or pwsh 7+).

$ErrorActionPreference = 'Continue'

$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { $HomeDir = $env:HOME }
$State = $env:GROK_FUSION_STATE
if (-not $State) { $State = Join-Path $HomeDir '.grok\fusion-stack' }

$script:Killed = $false

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

function Stop-PidFromFile {
    param(
        [string]$File,
        [string]$Name
    )
    if (-not (Test-Path -LiteralPath $File)) { return }
    $raw = Get-Content -LiteralPath $File -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item -LiteralPath $File -Force -ErrorAction SilentlyContinue
    $procId = 0
    if (-not [int]::TryParse(("$raw").Trim(), [ref]$procId)) { return }
    if ($procId -le 0) { return }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Write-Host "killed $Name PID=$procId"
        $script:Killed = $true
    } else {
        Write-Host "stale $Name PID=$procId (already dead)"
    }
}

function Get-PidsListeningOnPort {
    param([int]$Port)
    $ids = @()
    $netstat = Get-Command netstat.exe -ErrorAction SilentlyContinue
    if ($netstat) {
        $lines = & netstat.exe -ano -p TCP 2>$null
        foreach ($line in $lines) {
            if ($line -match "(?i)TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$") {
                $id = [int]$Matches[1]
                if ($id -gt 0 -and ($ids -notcontains $id)) {
                    $ids += $id
                }
            }
        }
        if ($ids.Count -gt 0) { return $ids }
    }
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
            foreach ($c in $conns) {
                $id = [int]$c.OwningProcess
                if ($id -gt 0 -and ($ids -notcontains $id)) {
                    $ids += $id
                }
            }
        } catch { }
    }
    return $ids
}

Stop-PidFromFile -File (Join-Path $State 'bridge.pid') -Name 'bridge.pid'
Stop-PidFromFile -File (Join-Path $State 'cloudflared.pid') -Name 'cloudflared.pid'

foreach ($listenId in (Get-PidsListeningOnPort -Port 18782)) {
    if ($listenId -eq $PID) { continue }
    if (Get-Process -Id $listenId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $listenId -Force -ErrorAction SilentlyContinue
        Write-Host "killed leftover :18782 PID=$listenId"
        $script:Killed = $true
    }
}

$tunnelUrl = 'http://127.0.0.1:18782'
foreach ($proc in (Get-Win32Processes)) {
    $name = [string]$proc.Name
    if ($name -notmatch 'cloudflared') { continue }
    $cl = [string]$proc.CommandLine
    if (-not $cl) { continue }
    $safe = ($cl -like '*tunnel*') -and ($cl -like "*$tunnelUrl*")
    if (-not $safe) { continue }
    $cfPid = [int]$proc.ProcessId
    if ($cfPid -le 0) { continue }
    if (Get-Process -Id $cfPid -ErrorAction SilentlyContinue) {
        Stop-Process -Id $cfPid -Force -ErrorAction SilentlyContinue
        Write-Host "killed leftover cloudflared PID=$cfPid"
        $script:Killed = $true
    }
}

if (-not $script:Killed) {
    Write-Host 'nothing running'
}
Write-Host "state: $State"
