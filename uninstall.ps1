param(
    [switch] $KeepState
)

$ErrorActionPreference = "Stop"

$appName = "EdgeDeckPin"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$stateDir = Join-Path $env:LOCALAPPDATA $appName
$pidFile = Join-Path $stateDir "watcher.pid"

function Stop-EdgeDeckWatcher {
    param([string] $Path)

    if (-not (Test-Path $Path)) {
        return
    }

    $watcherPidText = Get-Content $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    $watcherPid = 0
    if ([int]::TryParse([string]$watcherPidText, [ref]$watcherPid)) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $watcherPid" -ErrorAction SilentlyContinue
        if ($null -ne $process -and [string]$process.CommandLine -like "*EdgeDeckPin.ps1*") {
            Stop-Process -Id $watcherPid -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
}

Stop-EdgeDeckWatcher -Path $pidFile

& (Join-Path $PSScriptRoot "EdgeDeckPin.ps1") -ClearTopmost

Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $runKey -Name "VsdEdgeDock" -ErrorAction SilentlyContinue

if (-not $KeepState -and (Test-Path $stateDir)) {
    Remove-Item -LiteralPath $stateDir -Recurse -Force
}

Write-Host "EdgeDeck Pin is uninstalled."
