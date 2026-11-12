# Vector Contour Windows Setup: quick start

## Before you start
1. New PC: finish Windows setup and connect to Wi-Fi.
2. Plug in the USB stick with the **TECHNICAL DATA** folder (machine software installers are in `TECHNICAL DATA\SOFTWARE`, one folder per app). Any drive letter works.

## Start the tool
Open **PowerShell as administrator** (Start, type PowerShell, right-click, Run as administrator), paste this and press Enter:

```
irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1 | iex
```

Or double-click **VectorContourSetup.exe** and say Yes. (SmartScreen: More info, then Run anyway.)

## Set up a machine PC (the usual job)
1. The window opens on the **Vector Contour** tab with **Machine PC** already picked.
2. Click **Preview first**: the log at the bottom lists what would change. Nothing is changed.
3. Untick anything you don't want. Open a section to edit folder names, paths or the USB location.
4. Click **Looks good, go**. Installers without silent switches open their own window: click through them.
5. Restart when the summary asks (Windows features and updates need it).

Running it again is safe: anything already done is skipped.

## The other tabs
| Tab | What it's for |
|---|---|
| **Install** | ~240 apps. Tick, then **Install / upgrade selected**. Also: uninstall, upgrade all, show installed, WinGet or Chocolatey, add your own app. |
| **Tweaks** | Windows tweaks. **Standard** is a safe pick. **Run tweaks** or **Undo selected tweaks**. Switches on the right apply instantly. DNS, power plan, remove built-in apps. |
| **Config** | Windows features (.NET, Hyper-V, WSL...), fixes (Windows Update, network, system file repair) and shortcuts to old Control Panel pages. |
| **Updates** | **Security updates only** is recommended for machine PCs. Default puts Windows back; Turn off is for offline PCs only. |
| **Folders** | Folder templates and your own folder list. |
| **Presets** | Save what you ticked as a file to reuse on the next PC. |

## Good to know
- **Dry run** (top right) turns any button into a preview.
- **Run everything ticked on the tabs** runs all the tabs at once.
- A restore point is made before changes, so Windows can roll back.
- The Install, Tweaks, Config and Updates tabs come from Chris Titus Tech's WinUtil (MIT licence) and update themselves.
- Sensitive company files are not in the tool: copy them by hand.
