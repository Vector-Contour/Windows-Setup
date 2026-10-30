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

The exe is a small launcher with `winsetup.ps1` built in. It writes the script to `%TEMP%\VectorContourSetup` and starts it in PowerShell as administrator. To rebuild it after changing the script:

- On Windows: `powershell -ExecutionPolicy Bypass -File .\launcher\build.ps1`
- On a Mac: `brew install mono`, then `sh launcher/build.sh`

The exe isn't code-signed, so Windows SmartScreen will say "Windows protected your PC" (click **More info**, then **Run anyway**). Some antivirus tools also distrust unsigned launchers that run PowerShell. Before you hand it to customers, sign it with a code-signing certificate.

### From the web

Open PowerShell **as administrator** and run:

```powershell
irm https://vectorcontour.com/win | iex
```

If PowerShell isn't elevated, the script reopens itself in an admin window.

Running a preset with no window:

```powershell
& ([scriptblock]::Create((irm https://vectorcontour.com/win))) -Preset C:\path\my-pc.json -Run
# preview only:
& ([scriptblock]::Create((irm https://vectorcontour.com/win))) -Preset C:\path\my-pc.json -Run -DryRun
```

`-Preset` also takes a URL, so you can host presets on the website too.

Running from a local copy:

```powershell
powershell -ExecutionPolicy Bypass -File .\winsetup.ps1
powershell -ExecutionPolicy Bypass -File .\winsetup.ps1 -Preset .\presets\example.json -Run -DryRun
```

## Hosting on vectorcontour.com

`irm` just downloads the script text, so `https://vectorcontour.com/win` has to return the raw contents of `winsetup.ps1`. There are two ways to do that:

1. **Recommended: redirect to a GitHub release.** Keep this folder in a GitHub repo, attach `winsetup.ps1` to each release, and make `/win` a 302 redirect to
   `https://github.com/<owner>/<repo>/releases/latest/download/winsetup.ps1`.
   You ship an update by publishing a release, and the website never changes. (Chris Titus's `christitus.com/win` works this way.)
2. **Serve the file directly.** Upload `winsetup.ps1` and make `/win` return it with `Content-Type: text/plain; charset=utf-8`. Save it **without a BOM**.

Both need HTTPS, because people pipe the response straight into PowerShell. Keep the `$SourceUrl` line at the top of the script pointing at the same URL. The script uses it to relaunch itself as admin.

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
| `files` | `{source, destination}` (the source can be a URL or a path relative to the preset) or `{destination, content}` for a text file |
| `tweaks` | `TweakName: true` to apply, `false` to undo |
| `registry` | Raw values: `{path, name, type, value}` |
| `features.enable` / `features.disable` | Optional feature names |

## Status

Version 0.1.0. It hasn't been run on Windows yet. Test it in a VM or on a spare PC before you publish the link. The winget IDs were written from memory and should be checked with `winget search`.
