# EdgeDeck Pin

Pin Elgato Virtual Stream Deck above Corsair iCUE on XENEON EDGE.

EdgeDeck Pin is a tiny Windows helper for people who use Virtual Stream Deck on
a Corsair XENEON EDGE screen. It watches the XENEON EDGE dashboard window in
iCUE, makes the Virtual Stream Deck window owned by that dashboard window, and
only corrects visibility/topmost state when needed.

## What it does

- Automatically detects the XENEON EDGE-style display by its 2560x720 resolution.
- Automatically detects the Stream Deck window on that display.
- Syncs the Stream Deck window owner to the current iCUE XENEON EDGE window.
- Repairs visibility/topmost state only when the owner or window state changes.
- Installs as a per-user login startup entry.
- Uninstalls cleanly.
- Does not patch iCUE, Stream Deck, or device firmware.

## Requirements

- Windows
- PowerShell 5.1 or newer
- Elgato Stream Deck with Virtual Stream Deck enabled
- Corsair iCUE/XENEON EDGE or another secondary display you want to target

No .NET SDK, Python, Node.js, or admin rights are required.

## Quick start

Open PowerShell in this folder:

```powershell
.\install.ps1
```

That registers a per-user startup entry named `EdgeDeckPin` and starts it
immediately. The helper runs hidden in the background and will start again when
you log in.

## Manual use

List detected iCUE/Stream Deck windows:

```powershell
.\EdgeDeckPin.ps1 -ListWindows
```

Apply once:

```powershell
.\EdgeDeckPin.ps1
```

Run continuously in the current console:

```powershell
.\EdgeDeckPin.ps1 -Watch
```

## Uninstall

```powershell
.\uninstall.ps1
```

This stops the watcher, removes the login startup entry, clears the owner/topmost
state from the currently detected Stream Deck window, and deletes local state
under:

```text
%LOCALAPPDATA%\EdgeDeckPin
```

## Options

Use a specific display name:

```powershell
.\EdgeDeckPin.ps1 -Watch -TargetDisplayName "\\.\DISPLAY2"
```

Use a different preferred display resolution:

```powershell
.\EdgeDeckPin.ps1 -Watch -PreferredDisplayWidth 1920 -PreferredDisplayHeight 480
```

Search all displays instead of only the target display:

```powershell
.\EdgeDeckPin.ps1 -Watch -AnyDisplay
```

Change the watch interval:

```powershell
.\install.ps1 -IntervalMilliseconds 250
```

## Notes

This is intentionally a small user-mode helper. It does not try to embed Virtual
Stream Deck into iCUE. It keeps the real Virtual Stream Deck window usable while
preventing iCUE's XENEON EDGE dashboard from covering it.
