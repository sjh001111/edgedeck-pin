param(
    [switch] $Watch,
    [switch] $ListWindows,
    [switch] $DryRun,
    [switch] $ClearTopmost,
    [switch] $AnyDisplay,
    [switch] $AllProcesses,
    [switch] $Quiet,
    [string] $TargetDisplayName,
    [int] $PreferredDisplayWidth = 2560,
    [int] $PreferredDisplayHeight = 720,
    [ValidateRange(100, 10000)]
    [int] $IntervalMilliseconds = 500
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$win32Source = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class EdgeDeckPinWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumThreadWindows(uint dwThreadId, EnumWindowsProc lpfn, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
'@

if (-not ("EdgeDeckPinWin32" -as [type])) {
    Add-Type -TypeDefinition $win32Source
}

$GWLP_HWNDPARENT = -8
$GWL_EXSTYLE = -20
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$SW_SHOWNA = 8
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_NOACTIVATE = 0x0010
$SWP_SHOWWINDOW = 0x0040
$WS_EX_TOPMOST = 0x00000008

function ConvertTo-EdgeDeckRectObject {
    param([EdgeDeckPinWin32+RECT] $Rect)

    [pscustomobject]@{
        X = $Rect.Left
        Y = $Rect.Top
        Width = $Rect.Right - $Rect.Left
        Height = $Rect.Bottom - $Rect.Top
    }
}

function Format-EdgeDeckRect {
    param($Rect)
    return "X=$($Rect.X),Y=$($Rect.Y),W=$($Rect.Width),H=$($Rect.Height)"
}

function Get-EdgeDeckIntersectionArea {
    param($A, $B)

    $left = [Math]::Max([int]$A.X, [int]$B.X)
    $top = [Math]::Max([int]$A.Y, [int]$B.Y)
    $right = [Math]::Min([int]$A.X + [int]$A.Width, [int]$B.X + [int]$B.Width)
    $bottom = [Math]::Min([int]$A.Y + [int]$A.Height, [int]$B.Y + [int]$B.Height)
    $width = $right - $left
    $height = $bottom - $top

    if ($width -le 0 -or $height -le 0) {
        return [int64]0
    }

    return [int64]$width * [int64]$height
}

function Get-EdgeDeckScreens {
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [pscustomobject]@{
            DeviceName = $_.DeviceName
            Primary = $_.Primary
            Bounds = [pscustomobject]@{
                X = $_.Bounds.X
                Y = $_.Bounds.Y
                Width = $_.Bounds.Width
                Height = $_.Bounds.Height
            }
        }
    }
}

function Get-EdgeDeckVirtualDesktopScreen {
    param([object[]] $Screens)

    $minX = ($Screens.Bounds.X | Measure-Object -Minimum).Minimum
    $minY = ($Screens.Bounds.Y | Measure-Object -Minimum).Minimum
    $maxX = (($Screens.Bounds.X + $Screens.Bounds.Width) | Measure-Object -Maximum).Maximum
    $maxY = (($Screens.Bounds.Y + $Screens.Bounds.Height) | Measure-Object -Maximum).Maximum

    [pscustomobject]@{
        DeviceName = "virtual-desktop"
        Bounds = [pscustomobject]@{
            X = $minX
            Y = $minY
            Width = $maxX - $minX
            Height = $maxY - $minY
        }
    }
}

function Select-EdgeDeckTargetScreen {
    param([object[]] $Screens)

    $exactNonPrimary = $Screens |
        Where-Object { -not $_.Primary -and $_.Bounds.Width -eq $PreferredDisplayWidth -and $_.Bounds.Height -eq $PreferredDisplayHeight } |
        Select-Object -First 1

    if ($null -ne $exactNonPrimary) {
        return $exactNonPrimary
    }

    $exactAny = $Screens |
        Where-Object { $_.Bounds.Width -eq $PreferredDisplayWidth -and $_.Bounds.Height -eq $PreferredDisplayHeight } |
        Select-Object -First 1

    if ($null -ne $exactAny) {
        return $exactAny
    }

    $nonPrimary = $Screens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if ($null -ne $nonPrimary) {
        return $nonPrimary
    }

    return $Screens | Select-Object -First 1
}

function Get-EdgeDeckWindowText {
    param([IntPtr] $Hwnd)

    $builder = New-Object Text.StringBuilder 512
    [EdgeDeckPinWin32]::GetWindowText($Hwnd, $builder, $builder.Capacity) | Out-Null
    return $builder.ToString()
}

function Get-EdgeDeckWindowClass {
    param([IntPtr] $Hwnd)

    $builder = New-Object Text.StringBuilder 256
    [EdgeDeckPinWin32]::GetClassName($Hwnd, $builder, $builder.Capacity) | Out-Null
    return $builder.ToString()
}

function New-EdgeDeckWindowRecord {
    param([IntPtr] $Hwnd)

    $processIdValue = 0
    $threadId = [EdgeDeckPinWin32]::GetWindowThreadProcessId($Hwnd, [ref] $processIdValue)

    try {
        $process = Get-Process -Id $processIdValue -ErrorAction Stop
    } catch {
        return $null
    }

    $rect = New-Object EdgeDeckPinWin32+RECT
    if (-not [EdgeDeckPinWin32]::GetWindowRect($Hwnd, [ref] $rect)) {
        return $null
    }

    $exStyle = [EdgeDeckPinWin32]::GetWindowLongPtr($Hwnd, $GWL_EXSTYLE).ToInt64()
    $owner = [EdgeDeckPinWin32]::GetWindowLongPtr($Hwnd, $GWLP_HWNDPARENT).ToInt64()

    [pscustomobject]@{
        Hwnd = ("0x{0:X}" -f $Hwnd.ToInt64())
        HwndInt64 = $Hwnd.ToInt64()
        ProcessName = $process.ProcessName
        ProcessId = $processIdValue
        ThreadId = $threadId
        Visible = [EdgeDeckPinWin32]::IsWindowVisible($Hwnd)
        Topmost = (($exStyle -band $WS_EX_TOPMOST) -ne 0)
        OwnerHwndInt64 = $owner
        OwnerHwnd = ("0x{0:X}" -f $owner)
        ClassName = Get-EdgeDeckWindowClass -Hwnd $Hwnd
        Title = Get-EdgeDeckWindowText -Hwnd $Hwnd
        Rect = ConvertTo-EdgeDeckRectObject -Rect $rect
    }
}

function Get-EdgeDeckWindows {
    $recordsByHwnd = @{}

    $addWindow = {
        param([IntPtr] $hwnd)

        $record = New-EdgeDeckWindowRecord -Hwnd $hwnd
        if ($null -eq $record) {
            return
        }

        if (-not $AllProcesses -and $record.ProcessName -notin @("StreamDeck", "iCUE", "QtWebEngineProcess")) {
            return
        }

        $recordsByHwnd[$record.Hwnd] = $record
    }

    [EdgeDeckPinWin32]::EnumWindows({
        param([IntPtr] $hwnd, [IntPtr] $lParam)
        & $addWindow $hwnd
        return $true
    }, [IntPtr]::Zero) | Out-Null

    Get-Process -Name StreamDeck, iCUE, QtWebEngineProcess -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($thread in $_.Threads) {
            [EdgeDeckPinWin32]::EnumThreadWindows([uint32]$thread.Id, {
                param([IntPtr] $hwnd, [IntPtr] $lParam)
                & $addWindow $hwnd
                return $true
            }, [IntPtr]::Zero) | Out-Null
        }
    }

    return $recordsByHwnd.Values
}

function Select-EdgeDeckIcueWindow {
    param([object[]] $Windows, $TargetScreen)

    $scored = foreach ($window in $Windows) {
        if ($window.ProcessName -ne "iCUE" -or -not $window.Visible) {
            continue
        }

        $intersection = Get-EdgeDeckIntersectionArea -A $window.Rect -B $TargetScreen.Bounds
        if ($intersection -le 0) {
            continue
        }

        $classScore = if ([string]$window.ClassName -match "ToolSaveBits|QWindow") { 1000000 } else { 0 }
        $topmostScore = if ($window.Topmost) { 100000 } else { 0 }

        [pscustomobject]@{
            Window = $window
            Score = [int64]$intersection + [int64]$classScore + [int64]$topmostScore
        }
    }

    $best = $scored | Sort-Object Score -Descending | Select-Object -First 1
    if ($null -eq $best) {
        return $null
    }

    return $best.Window
}

function Select-EdgeDeckStreamDeckWindow {
    param([object[]] $Windows, $SearchScreen)

    $scored = foreach ($window in $Windows) {
        if ($window.ProcessName -ne "StreamDeck") {
            continue
        }

        $intersection = Get-EdgeDeckIntersectionArea -A $window.Rect -B $SearchScreen.Bounds
        if ($intersection -le 0) {
            continue
        }

        $visibleScore = if ($window.Visible) { 10000000 } else { 0 }
        $titleScore = if ([string]$window.Title -match "Virtual\s+Stream\s+Deck|VSD|Stream Deck") { 1000000 } else { 0 }
        $classScore = if ([string]$window.ClassName -match "ToolSaveBits|QWindow") { 100000 } else { 0 }

        [pscustomobject]@{
            Window = $window
            Score = [int64]$visibleScore + [int64]$titleScore + [int64]$classScore + [int64]$intersection
        }
    }

    $best = $scored | Sort-Object Score -Descending | Select-Object -First 1
    if ($null -eq $best) {
        return $null
    }

    return $best.Window
}

function Set-EdgeDeckOwner {
    param(
        [Int64] $VsdHwndInt64,
        [Int64] $OwnerHwndInt64
    )

    [EdgeDeckPinWin32]::SetWindowLongPtr([IntPtr]$VsdHwndInt64, $GWLP_HWNDPARENT, [IntPtr]$OwnerHwndInt64) | Out-Null
}

function Set-EdgeDeckTopmost {
    param(
        [Int64] $HwndInt64,
        [bool] $Topmost,
        [bool] $Show
    )

    $insertAfter = if ($Topmost) { $HWND_TOPMOST } else { $HWND_NOTOPMOST }
    $flags = $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE
    if ($Show) {
        $flags = $flags -bor $SWP_SHOWWINDOW
    }

    if (-not [EdgeDeckPinWin32]::SetWindowPos([IntPtr]$HwndInt64, $insertAfter, 0, 0, 0, 0, [uint32]$flags)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowPos failed for hwnd $HwndInt64 with Win32 error $errorCode"
    }
}

function Invoke-EdgeDeckPinOnce {
    $screens = @(Get-EdgeDeckScreens)
    if ($screens.Count -eq 0) {
        throw "No display found."
    }

    if ($TargetDisplayName) {
        $targetScreen = $screens | Where-Object { $_.DeviceName -eq $TargetDisplayName } | Select-Object -First 1
    } else {
        $targetScreen = Select-EdgeDeckTargetScreen -Screens $screens
    }

    if ($null -eq $targetScreen) {
        throw "Target display not found: $TargetDisplayName"
    }

    $windows = @(Get-EdgeDeckWindows)

    if ($ListWindows) {
        Write-Host "Target display: $($targetScreen.DeviceName) $(Format-EdgeDeckRect $targetScreen.Bounds)"
        $windows |
            Sort-Object ProcessName, Title, Hwnd |
            ForEach-Object {
                Write-Host ("{0} process={1} pid={2} visible={3} topmost={4} owner={5} class='{6}' title='{7}' rect={8}" -f `
                    $_.Hwnd, $_.ProcessName, $_.ProcessId, $_.Visible, $_.Topmost, $_.OwnerHwnd, $_.ClassName, $_.Title, (Format-EdgeDeckRect $_.Rect))
            }
        return
    }

    $icueWindow = Select-EdgeDeckIcueWindow -Windows $windows -TargetScreen $targetScreen
    $searchScreen = if ($AnyDisplay) { Get-EdgeDeckVirtualDesktopScreen -Screens $screens } else { $targetScreen }
    $vsdWindow = Select-EdgeDeckStreamDeckWindow -Windows $windows -SearchScreen $searchScreen

    if ($null -eq $vsdWindow) {
        if (-not $Quiet) {
            Write-Warning "No Stream Deck window found on $($searchScreen.DeviceName)."
        }
        return
    }

    if ($ClearTopmost) {
        if (-not $DryRun) {
            Set-EdgeDeckOwner -VsdHwndInt64 $vsdWindow.HwndInt64 -OwnerHwndInt64 0
            [EdgeDeckPinWin32]::ShowWindow([IntPtr]$vsdWindow.HwndInt64, $SW_SHOWNA) | Out-Null
            Set-EdgeDeckTopmost -HwndInt64 $vsdWindow.HwndInt64 -Topmost $false -Show $true
        }

        if (-not $Quiet) {
            Write-Host "cleared -> $($vsdWindow.Hwnd) '$($vsdWindow.Title)'"
        }
        return
    }

    $ownerChanged = $false
    if ($null -ne $icueWindow -and $vsdWindow.OwnerHwndInt64 -ne $icueWindow.HwndInt64) {
        $ownerChanged = $true
    }

    $needsShow = -not $vsdWindow.Visible
    $needsTopmost = -not $vsdWindow.Topmost
    $needsWork = $ownerChanged -or $needsShow -or $needsTopmost

    $ownerText = if ($null -ne $icueWindow) { $icueWindow.Hwnd } else { "none" }
    $message = "sync -> vsd=$($vsdWindow.Hwnd) owner=$ownerText ownerChanged=$ownerChanged needsShow=$needsShow needsTopmost=$needsTopmost"

    if ($DryRun) {
        if (-not $Quiet) {
            Write-Host "DRY RUN: $message"
        }
        return
    }

    if ($ownerChanged) {
        Set-EdgeDeckOwner -VsdHwndInt64 $vsdWindow.HwndInt64 -OwnerHwndInt64 $icueWindow.HwndInt64
    }

    if ($needsShow) {
        [EdgeDeckPinWin32]::ShowWindow([IntPtr]$vsdWindow.HwndInt64, $SW_SHOWNA) | Out-Null
    }

    if ($needsWork) {
        Set-EdgeDeckTopmost -HwndInt64 $vsdWindow.HwndInt64 -Topmost $true -Show $true
    }

    if (-not $Quiet) {
        Write-Host $message
    }
}

do {
    Invoke-EdgeDeckPinOnce
    if ($Watch) {
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
} while ($Watch)
