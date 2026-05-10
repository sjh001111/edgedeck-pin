param(
    [switch] $KeepState
)

$ErrorActionPreference = "Stop"

$appName = "EdgeDeckPin"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$stateDir = Join-Path $env:LOCALAPPDATA $appName
$pidFile = Join-Path $stateDir "watcher.pid"

if (Test-Path $pidFile) {
    $watcherPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($watcherPid) {
        Stop-Process -Id ([int]$watcherPid) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
}

& (Join-Path $PSScriptRoot "EdgeDeckPin.ps1") -ClearTopmost

Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $runKey -Name "VsdEdgeDock" -ErrorAction SilentlyContinue

if (-not $KeepState -and (Test-Path $stateDir)) {
    Remove-Item -LiteralPath $stateDir -Recurse -Force
}

Write-Host "EdgeDeck Pin is uninstalled."
