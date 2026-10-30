# Capturing a reference PC for the setup tool

These two scripts record exactly what you change on a Windows PC, so every app, setting, file and folder you set up by hand can be turned into options in the VectorContour setup tool.

- `capture-state.ps1` takes a snapshot of the PC. It only reads; nothing on the PC is changed.
- `compare-state.ps1` compares two snapshots and writes a readable report of what changed, plus a `suggested-preset.json` in the tool's preset format.

## Why not just back up the registry?

A full registry backup holds hundreds of thousands of values. Almost all of them are Windows defaults, hardware IDs, licence data, caches and timestamps that are different on every PC, and importing them on another machine can break it. There is no way to tell which values are the ones you chose.

A before-and-after comparison solves that: snapshot a fresh install, make your changes, snapshot again, and the difference is your setup. The comparison also covers things the registry doesn't hold, such as installed apps, removed built-in apps, optional features, services, scheduled tasks, folders and app settings files.

## Step by step

### 1. Start from a fresh Windows install

A virtual machine is ideal, because you can roll back and repeat. Use the same Windows edition you'll set up for customers (for example Windows 11 Pro, x64).

1. Install Windows and finish the first-run setup. Sign in with the account you'll use, and make it an administrator.
2. Run Windows Update until nothing is left, and reboot. Otherwise the update's own changes show up in the report mixed in with yours.
3. Open the Microsoft Store once and let it update everything, so `winget` (App Installer) is current.
4. If you're using a VM, take a VM snapshot now so you can come back to this point.

### 2. Copy the scripts onto the PC

Put `capture-state.ps1` and `compare-state.ps1` in a folder such as `C:\Capture`. If they came from a download or a zip, unblock them once in PowerShell:

```powershell
Get-ChildItem C:\Capture\*.ps1 | Unblock-File
```

### 3. Take the "before" snapshot

Open **PowerShell as administrator** (Start, type PowerShell, right-click, Run as administrator). Run it as the same user account you'll configure, so your own settings are what gets recorded.

```powershell
cd C:\Capture
powershell -ExecutionPolicy Bypass -File .\capture-state.ps1 -Label before
```

It takes about two to ten minutes. It creates a folder like `snapshot-before-PCNAME-20261031-101500` and a `.zip` of it.

### 4. Set up the PC exactly the way you want it

Do everything you'd want the tool to do on a new PC:

- Install every app (from winget, the Store, or vendor websites).
- Remove the built-in apps you don't want.
- Change Settings: personalization, taskbar, Start, File Explorer options, privacy, notifications, power, default apps, and so on.
- Turn Windows features on or off (WSL, Hyper-V, Sandbox, .NET 3.5...).
- Create your folders, pin them to Quick Access, pin apps to the taskbar, add desktop shortcuts.
- Open each app once and set its preferences, so it writes its settings file.
- Any registry tweaks or Group Policy changes you normally make.

Keep a short list as you go of what you changed and why. It helps match each report line to its purpose, and it records things you want the tool to ask about rather than always apply.

Try to avoid unrelated activity during this step (browsing, opening lots of documents), because that adds noise.

### 5. Reboot, then take the "after" snapshot

Rebooting makes sure every setting has been written to disk. Then, in PowerShell as administrator:

```powershell
cd C:\Capture
powershell -ExecutionPolicy Bypass -File .\capture-state.ps1 -Label after
```

### 6. Compare the two

```powershell
powershell -ExecutionPolicy Bypass -File .\compare-state.ps1 -Before .\snapshot-before-* -After .\snapshot-after-*
```

If you have more than one snapshot with the same label, type the full folder names instead of using `*`. You can also point it at the `.zip` files.

This creates a `report-PCNAME-...` folder and a `.zip` of it, containing:

| File | What it is |
|---|---|
| `report.md` | The readable list of everything that changed, grouped by area. |
| `suggested-preset.json` | Your changes in the setup tool's preset format: winget app IDs, apps to remove, features, folders, Quick Access pins and registry values. Things the tool can't do yet (services, scheduled tasks, environment variables, taskbar pins, default apps) are listed under `_notYetInTool`. |
| `changes.json` | Every change in full, for building new tool options. |
| `default-apps.xml` | Only if you changed default apps. |

To also bring along the settings files apps wrote (for example VS Code's `settings.json`), add `-CollectChangedFiles`. Look through the `files` folder before sharing it, because app settings can contain passwords, licence keys or sign-in tokens.

### 7. Send it over

Upload the report `.zip` to this project. The snapshot zips are useful too if they aren't too large, because they let a new comparison be run without the PC. Then we turn the report into tool options: new apps in the Install list, named tweaks with Undo, and anything else from `_notYetInTool`.

## Options

`capture-state.ps1`

- `-Label` name for the snapshot (`before`, `after`, `after-office`...).
- `-OutputRoot` where to save it (default: next to the script).
- `-FolderDepth` how deep to list folders in your user profile (default 4).
- `-SkipFullHKCU` record only the common settings areas of your user registry instead of all of it. Faster, less complete.
- `-NoZip` don't make a zip.

`compare-state.ps1`

- `-Before`, `-After` snapshot folders or zips.
- `-OutputDir` where to write the report.
- `-IncludeNoise` also list registry values that look automatic (timestamps, counters, window positions). They're always in `changes.json`; check here if a setting you changed seems to be missing from the report.
- `-CollectChangedFiles` copy new or changed app config files into the report.
- `-NoZip` don't make a zip.

## What gets recorded

| Area | How |
|---|---|
| Apps | `winget export` and `winget list`, Programs and Features (all three uninstall keys) |
| Built-in apps | `Get-AppxPackage` for your user, provisioned packages for new users |
| Registry | All of HKCU except file-type classes and known noisy keys (recent files, window positions, usage counters); HKCU and HKLM policy keys; MDM policies; HKLM areas for Explorer, Start, search, updates, power, Remote Desktop, file system, network and firewall |
| Services | Start type (including delayed start) and state |
| Scheduled tasks | Enabled or disabled, author and action |
| Optional features | `Get-WindowsOptionalFeature` and `Get-WindowsCapability` |
| Startup items | Run keys, Startup folders (`Win32_StartupCommand`) |
| Folders and files | Your profile (except AppData) to depth 4, top of `C:\`, Public |
| App settings files | `.json`, `.ini`, `.xml`, `.cfg` and similar under AppData, Documents, ProgramData and dot-folders, with a hash so edits are spotted |
| Pins | Quick Access, taskbar, Start layout file, desktop shortcuts |
| Other settings | Power plan and hibernation, time zone, region and languages, network profiles, firewall, Defender preferences, Remote Desktop, BitLocker status, hosts file, environment variables |
| Default apps | DISM default app associations export |

## Good to know

- **Safe to run anywhere.** Both scripts only read from the PC. They write their output to their own folders and nothing else. The only side effect is that `winget` may record that you accepted its source agreement.
- **Not administrator?** The capture still runs, but optional features, provisioned apps, default apps and some machine settings will be missing. The report says so.
- **Some settings live in the cloud or in binary blobs.** Start menu pins on Windows 11, for example, are a binary file; the report shows that it changed, and the file is kept in the snapshot so it can be copied. Settings that sync from a Microsoft account may change by themselves when you sign in.
- **Run it in stages if you like.** You can snapshot after each group of changes (`-Label after-apps`, `-Label after-tweaks`) and compare consecutive snapshots to get a separate report per group.
