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

function Get-EdgeDeckIntersectionArea {
    param(
        [Parameter(Mandatory = $true)] $A,
        [Parameter(Mandatory = $true)] $B
    )

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

function Select-EdgeDeckTargetScreen {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Screens,
        [int] $PreferredWidth = 2560,
        [int] $PreferredHeight = 720
    )

    if ($Screens.Count -eq 0) {
        return $null
    }

    $exactNonPrimary = $Screens |
        Where-Object { -not $_.Primary -and $_.Bounds.Width -eq $PreferredWidth -and $_.Bounds.Height -eq $PreferredHeight } |
        Select-Object -First 1

    if ($null -ne $exactNonPrimary) {
        return $exactNonPrimary
    }

    $exactAny = $Screens |
        Where-Object { $_.Bounds.Width -eq $PreferredWidth -and $_.Bounds.Height -eq $PreferredHeight } |
        Select-Object -First 1

    if ($null -ne $exactAny) {
        return $exactAny
    }

    $nonPrimary = $Screens |
        Where-Object { -not $_.Primary } |
        Select-Object -First 1

    if ($null -ne $nonPrimary) {
        return $nonPrimary
    }

    return $Screens | Select-Object -First 1
}

function Select-EdgeDeckWindowCandidate {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Windows,
        [Parameter(Mandatory = $true)] $TargetScreen,
        [string] $ProcessName = "StreamDeck"
    )

    $scored = foreach ($window in $Windows) {
        if ($null -eq $window -or -not $window.Visible) {
            continue
        }

        if ($window.ProcessName -ne $ProcessName) {
            continue
        }

        $intersection = Get-EdgeDeckIntersectionArea -A $window.Rect -B $TargetScreen.Bounds
        if ($intersection -le 0) {
            continue
        }

        $titleScore = if ([string]$window.Title -match "Virtual\s+Stream\s+Deck|VSD") { 1000000000000 } else { 0 }
        $classScore = if ([string]$window.ClassName -match "Qt|Chrome|CEF|Window") { 1000000 } else { 0 }

        [pscustomobject]@{
            Window = $window
            Score = [int64]$titleScore + [int64]$classScore + [int64]$intersection
        }
    }

    $best = $scored | Sort-Object Score -Descending | Select-Object -First 1
    if ($null -eq $best) {
        return $null
    }

    return $best.Window
}

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
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
'@

if (-not ("EdgeDeckPinWin32" -as [type])) {
    Add-Type -TypeDefinition $win32Source
}

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

    $exStyle = [EdgeDeckPinWin32]::GetWindowLongPtr($Hwnd, -20).ToInt64()

    [pscustomobject]@{
        Hwnd = ("0x{0:X}" -f $Hwnd.ToInt64())
        HwndInt64 = $Hwnd.ToInt64()
        ProcessName = $process.ProcessName
        ProcessId = $processIdValue
        ThreadId = $threadId
        Visible = [EdgeDeckPinWin32]::IsWindowVisible($Hwnd)
        Topmost = (($exStyle -band 0x00000008) -ne 0)
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

function Set-EdgeDeckWindowTopmost {
    param(
        [Parameter(Mandatory = $true)] [Int64] $HwndInt64,
        [Parameter(Mandatory = $true)] [bool] $Topmost
    )

    $hwnd = [IntPtr]$HwndInt64
    $insertAfter = if ($Topmost) { [IntPtr](-1) } else { [IntPtr](-2) }
    $flags = [uint32](0x0001 -bor 0x0002 -bor 0x0010)

    if (-not [EdgeDeckPinWin32]::SetWindowPos($hwnd, $insertAfter, 0, 0, 0, 0, $flags)) {
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
        $targetScreen = Select-EdgeDeckTargetScreen -Screens $screens -PreferredWidth $PreferredDisplayWidth -PreferredHeight $PreferredDisplayHeight
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
                Write-Host ("{0} process={1} pid={2} visible={3} topmost={4} class='{5}' title='{6}' rect={7}" -f `
                    $_.Hwnd, $_.ProcessName, $_.ProcessId, $_.Visible, $_.Topmost, $_.ClassName, $_.Title, (Format-EdgeDeckRect $_.Rect))
            }
        return
    }

    $searchScreen = if ($AnyDisplay) { Get-EdgeDeckVirtualDesktopScreen -Screens $screens } else { $targetScreen }
    $candidate = Select-EdgeDeckWindowCandidate -Windows $windows -TargetScreen $searchScreen

    if ($null -eq $candidate) {
        if (-not $Quiet) {
            Write-Warning "No visible Virtual Stream Deck candidate found on $($searchScreen.DeviceName)."
        }
        return
    }

    $topmost = -not $ClearTopmost
    $mode = if ($topmost) { "topmost" } else { "not-topmost" }
    $message = "$mode -> $($candidate.Hwnd) $($candidate.ProcessName) '$($candidate.Title)' $(Format-EdgeDeckRect $candidate.Rect)"

    if ($DryRun) {
        if (-not $Quiet) {
            Write-Host "DRY RUN: $message"
        }
        return
    }

    Set-EdgeDeckWindowTopmost -HwndInt64 $candidate.HwndInt64 -Topmost $topmost
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
