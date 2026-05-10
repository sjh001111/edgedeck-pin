param(
    [ValidateRange(100, 10000)]
    [int] $IntervalMilliseconds = 500,
    [switch] $NoStart
)

$ErrorActionPreference = "Stop"

$appName = "EdgeDeckPin"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$stateDir = Join-Path $env:LOCALAPPDATA $appName
$pidFile = Join-Path $stateDir "watcher.pid"
$mainScript = Join-Path $PSScriptRoot "EdgeDeckPin.ps1"
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$command = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mainScript`" -Watch -Quiet -IntervalMilliseconds $IntervalMilliseconds"

if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir | Out-Null
}

if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid) {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
}

Remove-ItemProperty -Path $runKey -Name "VsdEdgeDock" -ErrorAction SilentlyContinue
Set-ItemProperty -Path $runKey -Name $appName -Value $command
Write-Host "Installed EdgeDeck Pin login startup entry."

if (-not $NoStart) {
    $process = Start-Process -FilePath $powershell `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$mainScript`"", "-Watch", "-Quiet", "-IntervalMilliseconds", "$IntervalMilliseconds") `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -Path $pidFile -Value $process.Id
    Write-Host "Started EdgeDeck Pin with PID $($process.Id)."
}
