# VectorContour Windows Setup

A WinUtil-style tool for setting up a fresh Windows 10/11 install from one window:

- **Install**: tick apps and install the latest version of each with winget. "Upgrade all apps" updates everything already installed. Apps that aren't on winget can be downloaded straight from the vendor's site (see below).
- **Tweaks**: Windows settings (file extensions, Widgets, Bing in Start, ads, telemetry, dark mode, classic right-click menu...). Every tweak has **Undo**. A restore point is created first. You can also remove built-in apps like News, Weather and Solitaire.
- **Features**: turn optional features on or off (WSL, Hyper-V, Windows Sandbox, .NET 3.5...).
- **Folders**: ready-made folder templates (Developer, Business, Creative, IT support, Gaming, Tidy home folders), each with its folders, Quick Access pins and starter files, plus your own list of folders.
- **Presets**: save your selections as JSON, load them on the next PC, or run them with no window.

Anything already in place is skipped, so it is safe to run again. **Dry run** shows what would change without changing anything. Each run is logged in the window (and to `%TEMP%\winsetup-*.log` in unattended mode).

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

To publish a version, create a tag such as `v0.2.0` (GitHub: **Releases > Draft a new release**, type the new tag, publish). The build attaches `winsetup.ps1` and `VectorContourSetup.exe` to that release. Built files are never committed to the repo.

## Your own installers and files

Installers and files that aren't on winget or a vendor link go in this repo's **files** release and are referred to as `files:<name>`. The repo is public, so sensitive files stay out of it and are copied by hand for now. See [docs/hosting-files.md](docs/hosting-files.md) for how to add or replace a file and how to decide what is public.

## Editing the lists

All the lists are near the top of `winsetup.ps1`, inside `$Engine`:

- `$AppCatalog`: apps by category. The `Id` is the winget ID. Find one with `winget search <name>`.
- `$TweakCatalog`: each tweak has the registry values to apply (`On`) and to undo (`Off`).
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
| `features.enable` / `features.disable` | Optional feature names |

## Status

Version 0.1.0. It hasn't been run on Windows yet. Test it in a VM or on a spare PC before you publish the link. The winget IDs were written from memory and should be checked with `winget search`.
