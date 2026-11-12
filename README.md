# VectorContour Windows Setup

A Windows setup tool in two parts, in one window. New to it? Read the one-page [quick start](docs/quick-start.md) ([PDF](docs/quick-start.pdf)).

- **Vector Contour** (first tab): set up a PC the company way. Pick a setup (the **Machine PC** preset from the reference PC is selected when the window opens), check the list, and click **Looks good, go**.
- **Everything from Chris Titus Tech's WinUtil**, in the same tabs WinUtil has:
  - **Install**: about 240 apps by category, with search, WinGet or Chocolatey, *Install / upgrade selected*, *Uninstall selected*, *Upgrade all apps*, *Show installed apps* (ticks what's on the PC), and a filter for free and open source apps. You can add your own app by download link, GitHub repo or winget ID.
  - **Tweaks**: WinUtil's essential and advanced tweaks with its **Standard**, **Minimal** and **Advanced** picks and **Undo**; its preference switches (dark mode, file extensions, taskbar alignment, Bing search, sticky keys...) which apply as soon as you flip them; DNS (Cloudflare, Google, Quad9, AdGuard, the fastest one, or back to automatic); the Ultimate Performance power plan; Multiplane Overlay; removing built-in apps; O&O ShutUp10++. Our own Vector Contour tweaks (power, scaling, wallpaper...) are there too, each with Undo.
  - **Config**: WinUtil's features (.NET 3.5, Hyper-V, WSL, Sandbox, NFS, registry backup, F8 recovery...), Windows optional features, fixes (reset Windows Update, reset network, system corruption scan, reinstall WinGet, NTP server, AutoLogon), the old Control Panel pages, OpenSSH server and the CTT PowerShell profile.
  - **Updates**: Windows default, **security updates only** (recommended for machine PCs: security fixes 4 days late, feature updates a year late, no driver updates), or updates off. Plus *Check for updates now* and *Reset Windows Update*.
- **Folders**: folder templates and your own folder list. **Presets**: save what you picked as a preset, or load one (WinUtil's own exported config files load too).

The app list, tweaks and features are read from WinUtil's own config files each time the window opens, so they stay as current as WinUtil. If GitHub can't be reached, the copy in `winutil/config` is used (`-Catalog pinned` always uses that copy). WinUtil is MIT licensed, Copyright (c) 2022 CT Tech Group LLC; its licence is in `winutil/LICENSE`. Not included: WinUtil's MicroWin (custom Windows ISO builder).

Anything already in place is skipped, so it is safe to run again. **Dry run** shows what would change without changing anything. Each run is logged in the window (and to `%TEMP%\winsetup-*.log` in unattended mode).

## Vector Contour tab (review & go)

The window opens on **Vector Contour** with the Machine PC setup loaded: one page listing everything that will happen, all ticked. Pick another setup from the list (setups live in `presets/` and are listed in `$CompanyPresets` at the top of `winsetup.ps1`), or load a preset file.

- If it all looks right, click **Looks good, go**. **Preview first** shows what would change, without changing anything.
- Untick a row to skip it, or untick a section's header to skip the whole section.
- Open a section to edit folder paths, shortcut targets, the installer location or the wallpaper, or to add folders and Quick Access pins.
- **Use what I picked on the other tabs** rebuilds the page from the other tabs, for when you'd rather build a setup from scratch.

### Testing a branch before it is merged

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/BRANCH/winsetup.ps1))) -Branch BRANCH
```

`-Branch` makes the presets and the pinned catalog load from that branch too.

## Running it

### As an .exe

Double-click `VectorContourSetup.exe`, say Yes to the admin prompt, and the window opens. You can drop a preset `.json` onto the exe to load it, or run it from a command line with `VectorContourSetup.exe my-pc.json -Run` to apply the preset without the window.

The exe is a small launcher with `winsetup.ps1` built in. It writes the script to `%TEMP%\VectorContourSetup` and starts it in PowerShell as administrator.

- On Windows: `powershell -ExecutionPolicy Bypass -File .\launcher\build.ps1`
- On a Mac: `brew install mono`, then `sh launcher/build.sh`

The exe isn't code-signed, so Windows SmartScreen will say "Windows protected your PC" (click **More info**, then **Run anyway**). Some antivirus tools also distrust unsigned launchers that run PowerShell. Before you hand it to customers, sign it with a code-signing certificate.

The exe is built automatically by GitHub (see *Releases and the .exe* below), or by hand:

### From the web

On a new PC, open PowerShell **as administrator** (Start, type PowerShell, right-click, Run as administrator) and run:

```powershell
irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1 | iex
```

If PowerShell isn't elevated, the script reopens itself in an admin window. It always runs the current version on `main`, so a merged change is live within about five minutes (GitHub caches raw files briefly).

Running a preset with no window:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1))) -Preset https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/presets/example.json -Run
# preview only: add -DryRun
```

`-Preset` takes a URL or a local path, so a company preset can live in `presets/` here and be run straight from GitHub.

Running from a local copy:

```powershell
powershell -ExecutionPolicy Bypass -File .\winsetup.ps1
powershell -ExecutionPolicy Bypass -File .\winsetup.ps1 -Preset .\presets\example.json -Run -DryRun
```

### A short link on vectorcontour.com (later)

To use `irm vectorcontour.com/win | iex` instead, make `https://vectorcontour.com/win` an HTTPS **302 redirect** to
`https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1`.
On AWS that is an S3 bucket redirect rule or a CloudFront function; most hosting panels call it a "URL redirect". The website never needs to change again: updates still come from GitHub. Once it works, change `$SourceUrl` at the top of `winsetup.ps1` to the short link (the script uses it to relaunch itself as admin).

## Releases and the .exe

GitHub Actions checks every change: it parses every script in Windows PowerShell 5.1, checks the presets are valid JSON, and builds `VectorContourSetup.exe`. The exe from any run can be downloaded from that run's page under **Artifacts**.

To publish a version, create a tag such as `v1.0.0` (GitHub: **Releases > Draft a new release**, type the new tag, publish). The build attaches `winsetup.ps1` and `VectorContourSetup.exe` to that release. Built files are never committed to the repo.

## Your own installers and files

Installers and files that aren't on winget or a vendor link go in this repo's **files** release and are referred to as `files:<name>`. The repo is public, so sensitive files stay out of it and are copied by hand for now. See [docs/hosting-files.md](docs/hosting-files.md) for how to add or replace a file and how to decide what is public.

## Editing the lists

All the lists are near the top of `winsetup.ps1`, inside `$Engine`:

- `$AppCatalog`: apps by category. The `Id` is the winget ID. Find one with `winget search <name>`.
- `$TweakCatalog`: each tweak has the registry values to apply (`On`) and to undo (`Off`). Tweaks that aren't plain registry values (power, wallpaper) use `Apply` / `Undo` script blocks instead, or as well.
- `$BuiltInAppCatalog`: built-in Store apps that can be removed.
- `$FeatureCatalog`: optional Windows features.

## Apps that aren't on winget

An app can be downloaded straight from the vendor instead. There are three ways to point at it, and the last two always pick up the latest version:

| Field | Use when |
|---|---|
| `url` | The vendor has a permanent link, e.g. `https://vendor.com/download/latest/setup.exe` |
| `url` = `files:<name>` | You host the installer yourself in this repo's files release (see [docs/hosting-files.md](docs/hosting-files.md)) |
| `github` + `asset` | The app is released on GitHub: `"github": "owner/repo"`, plus a regex for the file name (default: any `.exe`/`.msi`) |
| `page` + `link` | The vendor only has a download page: the script loads the page and takes the first link matching the `link` regex (group 1 if it has one) |

Other fields:

- `args`: silent install switches for `.exe` installers. Common ones are `/S` (NSIS), `/VERYSILENT /NORESTART` (Inno Setup) and `/quiet /norestart` (MSI-based exes). Without them, the installer window opens and waits. `.msi` files always run with `/qn`.
- `type`: `exe`, `msi`, `zip` (unpacked to `target`) or `portable` (copied to `target`). It is guessed from the file name if you leave it out.
- `detect`: the app's name as it appears in Settings > Apps (wildcards allowed), so it is skipped if already installed.
- `target`: the folder for zip and portable apps (default `C:\Tools\<name>`).
- `sha256`: an optional checksum, useful with fixed-version links.

### Installing from a USB stick or share

For software you can't download automatically (licensed machine software, old versions), point `path` at a local installer instead of a link:

```json
"installerRoot": "*:\\TECHNICAL DATA\\SOFTWARE",
"apps": { "install": [
  { "name": "SoMove", "path": "SOMOVE", "detect": "SoMove*" },
  { "name": "QCAD/CAM", "path": "QCAD\\qcadcam-*.msi", "detect": "QCAD/CAM*" }
] }
```

- `path` can be a file (wildcards allowed, the newest match wins) or a folder. For a folder, the tool picks an `.msi` over an `.exe`, and a name containing *setup* or *install* over others, and logs which one it used.
- Relative paths are looked up in `installerRoot`, or next to the preset file if there's no root.
- `*:\` at the start means "any drive", so a USB stick is found whatever letter it gets.
- Without `args`, the installer's own window opens and the tool waits for you to finish it.

Where to put them:

- **Built in for everyone**: add an entry to `$AppCatalog` with an `Id` like `direct:myapp` (see the *Direct downloads* category, which uses Rufus as an example).
- **Just in a preset**: put the object straight into `apps.install` (see `presets/example.json`).
- **From the window**: on the Install tab, enter a name, a link / `owner/repo` / winget ID, and optional silent switches, then click **Add app**. It shows up under *Your apps*, and **Save selections as preset** keeps it.

Limitation: "Upgrade all apps" only covers winget apps. A direct-download app with `detect` set is skipped once installed. Most of these apps update themselves, and for those that don't, uninstall and run again.

## Folder templates

The templates live in `$FolderTemplates` in `winsetup.ps1`. Each one has:

- `Folders`: folders to create
- `Pin`: folders to pin to Quick Access in File Explorer
- `Files`: starter files, either `{destination, content}` for a text file written by the script or `{destination, source}` to copy or download one. Existing files are left alone unless `overwrite` is `true`.

To add a template, copy one of the existing blocks and give it a new key. A preset can also contain a whole template object in `folderTemplates`, so you can have customer-specific layouts without changing the script:

```json
"folderTemplates": [
  "developer",
  { "label": "Acme Ltd", "folders": ["C:\\Acme\\Projects", "C:\\Acme\\Shared"], "pin": ["C:\\Acme\\Projects"],
    "files": [{ "destination": "C:\\Acme\\README.txt", "content": "Welcome to Acme" }] }
]
```

## Preset format

See `presets/example.json`. Every section is optional.

| Key | Meaning |
|---|---|
| `restorePoint` | Create a restore point before tweaks (default true) |
| `apps.install` | winget IDs, catalog Ids, or direct-download objects (see above) |
| `apps.upgradeAll` | Upgrade every installed app afterwards |
| `removeApps` | Built-in app package names to remove |
| `folderTemplates` | Template keys (`developer`, `business`, `creative`, `support`, `gaming`, `tidy`) or template objects |
| `folders` | Folders to create (`%VARS%` allowed) |
| `quickAccess` | Folders to pin to Quick Access |
| `files` | `{source, destination}` (the source can be a URL, `files:<name>`, or a path relative to the preset) or `{destination, content}` for a text file |
| `tweaks` | `TweakName: true` to apply, `false` to undo |
| `registry` | Raw values: `{path, name, type, value}` |
| `features.enable` / `features.disable` | Optional feature names. These run first, because some apps need them to install |
| `installerRoot` | Folder for local installers (see *Installing from a USB stick or share*) |
| `copyFolders` | `{source, destination}`: whole folders copied with robocopy (newer files win, nothing deleted). The source can start with `*:\` |
| `shortcuts` | `{name, target, args?, icon?, folder?}`, where folder is `Desktop` (default), `PublicDesktop`, `StartMenu` or a path |
| `removeShortcuts` | Shortcut files to delete, e.g. `%PUBLIC%\\Desktop\\Microsoft Edge.lnk` |
| `wallpaper` | Picture file (local, relative to the preset, `*:\...`, or a URL). Pictures from a USB stick are copied to Public Pictures first |
| `startLayout` | A Windows 11 `start2.bin` (Start menu pins) to copy in |

Power settings are tweaks, so they appear on the Tweaks tab with Undo: `NeverSleepPluggedIn`, `DisplayAlwaysOnPluggedIn`, `PowerButtonShutsDown` and `BestPerformancePowerMode`. They change every power plan.

`presets/machine-pc.json` is the setup captured from the reference machine PC. It expects a USB stick with the `TECHNICAL DATA` folder at its root, installs the machine software from `TECHNICAL DATA\SOFTWARE`, and copies the whole folder to the desktop.

When you load a preset in the window, the sections the window has no controls for (wallpaper, shortcuts, copied folders, files, registry) are kept, and run with **Run everything**.

### WinUtil settings in a preset

```json
{
  "packageManager": "winget",
  "winutil": {
    "tweaks": ["WPFTweaksRestorePoint", "WPFTweaksTelemetry", "WPFTweaksServices"],
    "toggles": { "WPFToggleDarkMode": true, "WPFToggleBingSearch": false },
    "features": ["WPFFeaturesdotnet"],
    "actions": ["WPFFixesNTPPool", "WPFAddUltPerf"],
    "choices": { "WPFMultiplaneOverlay": "Disabled (Compatibility)" }
  },
  "dns": "Cloudflare",
  "updates": "security"
}
```

The keys are WinUtil's own names (see `winutil/config/tweaks.json` and `feature.json`). `packageManager` is `winget` or `choco`; apps can also be listed as `choco:<package>`. `updates` is `default`, `security` or `disable`. `dns` is `DHCP`, `Fastest` or a name from `dns.json`.

## Status

Version 1.0.0 adds the WinUtil tabs (Install, Tweaks, Config, Updates) and makes the Machine PC setup the default first tab. It has been checked in dry runs on Linux PowerShell with Windows commands stubbed out, but has not run on Windows yet. Test it on the spare x64 PC (reset it with "Reset this PC" between runs) before using it on customer PCs.
