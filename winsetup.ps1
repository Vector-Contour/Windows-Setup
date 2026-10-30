<#
.SYNOPSIS
    VectorContour Windows Setup: set up a fresh Windows install from one window.

.DESCRIPTION
    Install the latest version of apps (winget), apply and undo Windows tweaks,
    remove built-in apps, turn optional features on or off, and create folders.
    Selections can be saved as a JSON preset and replayed without the window.

    Run from the web (PowerShell as admin):
        irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1 | iex

    Run a preset without the window:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1))) -Preset .\my-pc.json -Run

    Run locally:
        .\winsetup.ps1                      # open the window
        .\winsetup.ps1 -Preset x.json -Run  # unattended
        .\winsetup.ps1 -Preset x.json -Run -DryRun
#>
param(
    [string]$Preset,
    [switch]$Run,
    [switch]$DryRun
)

$AppName = 'VectorContour Windows Setup'
$AppVersion = '0.1.0'
$SourceUrl = 'https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1'

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Elevate / STA -----------------------------------------------------------
# The window needs admin rights (HKLM, features, appx) and an STA thread (WPF).
# When started with "irm | iex" there is no file on disk, so relaunch from the URL.

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
# Appx, restore point and WPF cmdlets are most reliable in Windows PowerShell 5.1.
$isCore = $PSVersionTable.PSEdition -eq 'Core'

if (-not $isAdmin -or $isCore -or (-not $Run -and -not $isSta)) {
    # The relaunched window starts in System32, so pass the preset as a full path.
    if ($Preset -and $Preset -notmatch '^https?://' -and (Test-Path $Preset)) { $Preset = (Resolve-Path $Preset).Path }
    $passArgs = @()
    if ($Preset) { $passArgs += "-Preset '$Preset'" }
    if ($Run) { $passArgs += '-Run' }
    if ($DryRun) { $passArgs += '-DryRun' }
    $passArgs = $passArgs -join ' '

    if ($PSCommandPath) {
        $cmd = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" $passArgs"
    }
    else {
        $cmd = "-NoProfile -ExecutionPolicy Bypass -STA -Command `"& ([scriptblock]::Create((irm '$SourceUrl'))) $passArgs`""
    }
    $verb = if ($isAdmin) { 'Open' } else { 'RunAs' }
    Write-Host 'Restarting as administrator...' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd -Verb $verb
    return
}

# --- Engine ------------------------------------------------------------------
# Everything that changes the system lives in this block. The window runs it in
# a background runspace (so the UI stays responsive); -Run mode runs it here.

$Engine = {

    # Make cmdlet errors throw, so Invoke-Step reports them as failures.
    $ErrorActionPreference = 'Stop'

    # ---- Where files come from ----
    # files:<name>    an asset of the "files" release in this repo (public: anyone can download it)
    # private:<name>  a file from $PrivateFilesUrl. Not set up yet, so private files are copied
    #                 by hand; the run lists them as [by hand] steps. Later this can point at a
    #                 login-protected download (e.g. the wiki) and add its sign-in here.
    $PublicRepo = 'Vector-Contour/Windows-Setup'
    $FilesTag = 'files'
    $PrivateFilesUrl = ''

    # ---- Catalogs ----

    $AppCatalog = [ordered]@{
        'Browsers'      = @(
            @{ Name = 'Google Chrome'; Id = 'Google.Chrome' }
            @{ Name = 'Mozilla Firefox'; Id = 'Mozilla.Firefox' }
            @{ Name = 'Brave'; Id = 'Brave.Brave' }
            @{ Name = 'Vivaldi'; Id = 'Vivaldi.Vivaldi' }
        )
        'Communication' = @(
            @{ Name = 'Discord'; Id = 'Discord.Discord' }
            @{ Name = 'Slack'; Id = 'SlackTechnologies.Slack' }
            @{ Name = 'Zoom'; Id = 'Zoom.Zoom' }
            @{ Name = 'Microsoft Teams'; Id = 'Microsoft.Teams' }
            @{ Name = 'Telegram'; Id = 'Telegram.TelegramDesktop' }
            @{ Name = 'Signal'; Id = 'OpenWhisperSystems.Signal' }
        )
        'Development'   = @(
            @{ Name = 'Visual Studio Code'; Id = 'Microsoft.VisualStudioCode' }
            @{ Name = 'Git'; Id = 'Git.Git' }
            @{ Name = 'GitHub Desktop'; Id = 'GitHub.GitHubDesktop' }
            @{ Name = 'Node.js LTS'; Id = 'OpenJS.NodeJS.LTS' }
            @{ Name = 'Python 3.13'; Id = 'Python.Python.3.13' }
            @{ Name = 'PowerShell 7'; Id = 'Microsoft.PowerShell' }
            @{ Name = 'Windows Terminal'; Id = 'Microsoft.WindowsTerminal' }
            @{ Name = 'Docker Desktop'; Id = 'Docker.DockerDesktop' }
            @{ Name = 'Notepad++'; Id = 'Notepad++.Notepad++' }
            @{ Name = 'PuTTY'; Id = 'PuTTY.PuTTY' }
            @{ Name = 'WinSCP'; Id = 'WinSCP.WinSCP' }
        )
        'Utilities'     = @(
            @{ Name = '7-Zip'; Id = '7zip.7zip' }
            @{ Name = 'PowerToys'; Id = 'Microsoft.PowerToys' }
            @{ Name = 'Everything (file search)'; Id = 'voidtools.Everything' }
            @{ Name = 'WinDirStat'; Id = 'WinDirStat.WinDirStat' }
            @{ Name = 'CPU-Z'; Id = 'CPUID.CPU-Z' }
            @{ Name = 'ShareX'; Id = 'ShareX.ShareX' }
            @{ Name = 'Bitwarden'; Id = 'Bitwarden.Bitwarden' }
            @{ Name = 'KeePassXC'; Id = 'KeePassXCTeam.KeePassXC' }
            @{ Name = '1Password'; Id = 'AgileBits.1Password' }
        )
        'Cloud storage' = @(
            @{ Name = 'Dropbox'; Id = 'Dropbox.Dropbox' }
            @{ Name = 'Google Drive'; Id = 'Google.GoogleDrive' }
        )
        'Media'         = @(
            @{ Name = 'VLC'; Id = 'VideoLAN.VLC' }
            @{ Name = 'OBS Studio'; Id = 'OBSProject.OBSStudio' }
            @{ Name = 'Audacity'; Id = 'Audacity.Audacity' }
            @{ Name = 'HandBrake'; Id = 'HandBrake.HandBrake' }
            @{ Name = 'Paint.NET'; Id = 'dotPDN.PaintDotNet' }
            @{ Name = 'IrfanView'; Id = 'IrfanView.IrfanView' }
        )
        'Documents'     = @(
            @{ Name = 'Adobe Acrobat Reader'; Id = 'Adobe.Acrobat.Reader.64-bit' }
            @{ Name = 'LibreOffice'; Id = 'TheDocumentFoundation.LibreOffice' }
            @{ Name = 'SumatraPDF'; Id = 'SumatraPDF.SumatraPDF' }
            @{ Name = 'Notion'; Id = 'Notion.Notion' }
            @{ Name = 'Obsidian'; Id = 'Obsidian.Obsidian' }
        )
        # Apps not on winget: downloaded straight from the vendor. See Install-DirectApp
        # for the fields (url / github / page, args, type, detect, target).
        'Direct downloads' = @(
            @{ Name = 'Rufus (portable)'; Id = 'direct:rufus'; github = 'pbatard/rufus'; asset = '^rufus-[\d.]+\.exe$'
                type = 'portable'; target = 'C:\Tools\Rufus' }
        )
        'Gaming'        = @(
            @{ Name = 'Steam'; Id = 'Valve.Steam' }
            @{ Name = 'Epic Games Launcher'; Id = 'EpicGames.EpicGamesLauncher' }
            @{ Name = 'GOG Galaxy'; Id = 'GOG.Galaxy' }
        )
    }

    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $theme = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $search = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
    $mouse = 'HKCU:\Control Panel\Mouse'
    $ctxMenu = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'

    # On = registry entries for applying the tweak, Off = entries that undo it.
    # Value $null removes the value; RemoveKey removes the whole key.
    $TweakCatalog = [ordered]@{
        ShowFileExtensions          = @{
            Label = 'Show file extensions'; Recommended = $true
            Description = 'Show .exe, .pdf and so on in File Explorer.'
            On = @(@{ Path = $adv; Name = 'HideFileExt'; Value = 0 })
            Off = @(@{ Path = $adv; Name = 'HideFileExt'; Value = 1 })
        }
        ShowHiddenFiles             = @{
            Label = 'Show hidden files'; Recommended = $false
            Description = 'Show hidden files and folders in File Explorer.'
            On = @(@{ Path = $adv; Name = 'Hidden'; Value = 1 })
            Off = @(@{ Path = $adv; Name = 'Hidden'; Value = 2 })
        }
        ExplorerOpensThisPC         = @{
            Label = 'File Explorer opens This PC'; Recommended = $true
            Description = 'Open File Explorer on This PC instead of Home.'
            On = @(@{ Path = $adv; Name = 'LaunchTo'; Value = 1 })
            Off = @(@{ Path = $adv; Name = 'LaunchTo'; Value = 2 })
        }
        ClassicRightClickMenu       = @{
            Label = 'Classic right-click menu'; Recommended = $false
            Description = 'Bring back the full Windows 10 style context menu (no "Show more options").'
            On = @(@{ Path = "$ctxMenu\InprocServer32"; Name = '(Default)'; Type = 'String'; Value = '' })
            Off = @(@{ Path = $ctxMenu; RemoveKey = $true })
        }
        DarkMode                    = @{
            Label = 'Dark mode'; Recommended = $false
            Description = 'Use the dark theme for Windows and apps.'
            On = @(
                @{ Path = $theme; Name = 'AppsUseLightTheme'; Value = 0 }
                @{ Path = $theme; Name = 'SystemUsesLightTheme'; Value = 0 }
            )
            Off = @(
                @{ Path = $theme; Name = 'AppsUseLightTheme'; Value = 1 }
                @{ Path = $theme; Name = 'SystemUsesLightTheme'; Value = 1 }
            )
        }
        TaskbarAlignLeft            = @{
            Label = 'Taskbar icons on the left'; Recommended = $false
            Description = 'Move the Start button and taskbar icons to the left like Windows 10.'
            On = @(@{ Path = $adv; Name = 'TaskbarAl'; Value = 0 })
            Off = @(@{ Path = $adv; Name = 'TaskbarAl'; Value = 1 })
        }
        HideTaskbarSearch           = @{
            Label = 'Hide taskbar search box'; Recommended = $false
            Description = 'Remove the search box from the taskbar (press Win and type to search).'
            On = @(@{ Path = $search; Name = 'SearchboxTaskbarMode'; Value = 0 })
            Off = @(@{ Path = $search; Name = 'SearchboxTaskbarMode'; Value = 1 })
        }
        HideTaskViewButton          = @{
            Label = 'Hide Task View button'; Recommended = $false
            Description = 'Remove the Task View button from the taskbar.'
            On = @(@{ Path = $adv; Name = 'ShowTaskViewButton'; Value = 0 })
            Off = @(@{ Path = $adv; Name = 'ShowTaskViewButton'; Value = 1 })
        }
        HideWidgets                 = @{
            Label = 'Turn off Widgets'; Recommended = $true
            Description = 'Remove the news and weather Widgets board.'
            On = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 })
            Off = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = $null })
        }
        DisableBingInStartSearch    = @{
            Label = 'No web results in Start search'; Recommended = $true
            Description = 'Start menu search only shows local apps, files and settings.'
            On = @(
                @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
                @{ Path = $search; Name = 'BingSearchEnabled'; Value = 0 }
            )
            Off = @(
                @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = $null }
                @{ Path = $search; Name = 'BingSearchEnabled'; Value = 1 }
            )
        }
        DisableStartMenuSuggestions = @{
            Label = 'No suggested apps and ads'; Recommended = $true
            Description = 'Stop Start menu suggestions and silently installed promoted apps.'
            On = @(
                @{ Path = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
                @{ Path = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
                @{ Path = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0 }
            )
            Off = @(
                @{ Path = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 1 }
                @{ Path = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 1 }
                @{ Path = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 1 }
            )
        }
        DisableTelemetry            = @{
            Label = 'Reduce telemetry'; Recommended = $true
            Description = 'Send the minimum diagnostic data (fully off on Enterprise/Education).'
            On = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 })
            Off = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = $null })
        }
        DisableAdvertisingId        = @{
            Label = 'Turn off advertising ID'; Recommended = $true
            Description = 'Stop apps using your advertising ID for personalised ads.'
            On = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 })
            Off = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 1 })
        }
        EnableClipboardHistory      = @{
            Label = 'Clipboard history (Win+V)'; Recommended = $true
            Description = 'Keep a history of copied items, opened with Win+V.'
            On = @(@{ Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 1 })
            Off = @(@{ Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 0 })
        }
        DisableMouseAcceleration    = @{
            Label = 'Turn off mouse acceleration'; Recommended = $false
            Description = 'Disable "Enhance pointer precision" for consistent mouse movement.'
            On = @(
                @{ Path = $mouse; Name = 'MouseSpeed'; Type = 'String'; Value = '0' }
                @{ Path = $mouse; Name = 'MouseThreshold1'; Type = 'String'; Value = '0' }
                @{ Path = $mouse; Name = 'MouseThreshold2'; Type = 'String'; Value = '0' }
            )
            Off = @(
                @{ Path = $mouse; Name = 'MouseSpeed'; Type = 'String'; Value = '1' }
                @{ Path = $mouse; Name = 'MouseThreshold1'; Type = 'String'; Value = '6' }
                @{ Path = $mouse; Name = 'MouseThreshold2'; Type = 'String'; Value = '10' }
            )
        }
        FasterMenus                 = @{
            Label = 'Faster menus'; Recommended = $false
            Description = 'Shorten the delay before menus open.'
            On = @(@{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; Value = '100' })
            Off = @(@{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay'; Type = 'String'; Value = '400' })
        }
    }

    $BuiltInAppCatalog = [ordered]@{
        'Microsoft.BingNews'                     = 'Microsoft News'
        'Microsoft.BingWeather'                  = 'Weather'
        'Microsoft.GetHelp'                      = 'Get Help'
        'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire Collection'
        'Microsoft.People'                       = 'People'
        'Microsoft.WindowsFeedbackHub'           = 'Feedback Hub'
        'Microsoft.MicrosoftOfficeHub'           = 'Microsoft 365 (Office) hub'
        'Microsoft.ZuneMusic'                    = 'Media Player / Groove'
        'Microsoft.YourPhone'                    = 'Phone Link'
        'Microsoft.Todos'                        = 'Microsoft To Do'
        'Microsoft.PowerAutomateDesktop'         = 'Power Automate'
        'Clipchamp.Clipchamp'                    = 'Clipchamp'
        'MicrosoftCorporationII.QuickAssist'     = 'Quick Assist'
    }

    $FeatureCatalog = [ordered]@{
        'Microsoft-Windows-Subsystem-Linux' = 'Windows Subsystem for Linux (WSL)'
        'VirtualMachinePlatform'            = 'Virtual Machine Platform (needed for WSL 2)'
        'Microsoft-Hyper-V-All'             = 'Hyper-V (Pro/Enterprise)'
        'Containers-DisposableClientVM'     = 'Windows Sandbox (Pro/Enterprise)'
        'NetFx3'                            = '.NET Framework 3.5 (older apps)'
        'TelnetClient'                      = 'Telnet client'
        'WindowsMediaPlayer'                = 'Windows Media Player (legacy)'
        'SMB1Protocol'                      = 'SMB 1.0 (old, insecure file sharing)'
        'MicrosoftWindowsPowerShellV2Root'  = 'PowerShell 2.0 (old, insecure)'
    }

    # Ready-made folder layouts. Folders are created, Pin goes to File Explorer's
    # Quick Access, and Files are starter files (only written if missing, unless overwrite = $true).
    $docs = '%USERPROFILE%\Documents'
    $FolderTemplates = [ordered]@{
        developer = @{
            Label = 'Developer'; Description = 'Code, scratch space and a tools folder.'
            Folders = @('C:\Dev', 'C:\Dev\repos', 'C:\Dev\sandbox', 'C:\Dev\scratch', 'C:\Tools')
            Pin = @('C:\Dev\repos')
            Files = @(@{ destination = 'C:\Dev\README.txt'; content = "repos    - cloned projects`r`nsandbox  - experiments`r`nscratch  - throwaway files`r`n" })
        }
        business  = @{
            Label = 'Business / office'; Description = 'Clients, invoices, contracts and templates in Documents.'
            Folders = @("$docs\Clients", "$docs\Invoices", "$docs\Contracts", "$docs\Templates", "$docs\Admin", "$docs\Archive")
            Pin = @("$docs\Clients", "$docs\Invoices")
            Files = @()
        }
        creative  = @{
            Label = 'Creative'; Description = 'Photo and video projects, assets and exports.'
            Folders = @('%USERPROFILE%\Pictures\Projects', '%USERPROFILE%\Videos\Projects', "$docs\Assets\Fonts", "$docs\Assets\Stock", "$docs\Assets\Brushes", "$docs\Exports")
            Pin = @('%USERPROFILE%\Pictures\Projects', "$docs\Exports")
            Files = @()
        }
        support   = @{
            Label = 'IT support toolkit'; Description = 'C:\Support with tools, drivers, logs, scripts and installers.'
            Folders = @('C:\Support', 'C:\Support\Tools', 'C:\Support\Drivers', 'C:\Support\Logs', 'C:\Support\Scripts', 'C:\Support\Installers')
            Pin = @('C:\Support')
            Files = @(@{ destination = 'C:\Support\README.txt'; content = "Tools       - portable utilities`r`nDrivers     - driver packs for this PC`r`nLogs        - setup and diagnostic logs`r`nScripts     - maintenance scripts`r`nInstallers  - offline installers`r`n" })
        }
        gaming    = @{
            Label = 'Gaming'; Description = 'A games library folder plus captures and screenshots.'
            Folders = @('C:\Games', '%USERPROFILE%\Videos\Captures', '%USERPROFILE%\Pictures\Screenshots\Games')
            Pin = @('C:\Games')
            Files = @()
        }
        tidy      = @{
            Label = 'Tidy home folders'; Description = 'Sort Downloads and Documents into installers, archives, scans and receipts.'
            Folders = @('%USERPROFILE%\Downloads\Installers', '%USERPROFILE%\Downloads\Archives', '%USERPROFILE%\Downloads\Documents', "$docs\Scans", "$docs\Receipts", '%USERPROFILE%\Pictures\Screenshots')
            Pin = @()
            Files = @()
        }
    }

    # Id -> app, for looking up direct-download apps by their catalog Id.
    $AppIndex = @{}
    foreach ($cat in $AppCatalog.Keys) { foreach ($a in $AppCatalog[$cat]) { $AppIndex[$a.Id] = $a } }

    # The progress bar makes Invoke-WebRequest many times slower in Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'

    # ---- Output and bookkeeping ----

    $script:Stats = @{ Changed = 0; Skipped = 0; Failed = 0 }
    $script:RestartNeeded = $false
    $script:RestartExplorer = $false

    # In the window, log lines go to a queue the UI drains; otherwise to the console.
    function Write-Log([string]$Message, [string]$Color = 'Gray') {
        if ($sync -and $sync.LogQueue) {
            $sync.LogQueue.Enqueue($Message)
        }
        else {
            Write-Host $Message -ForegroundColor $Color
        }
    }

    function Write-Section([string]$Title) { Write-Log ''; Write-Log "== $Title ==" 'Cyan' }

    function Write-Skip([string]$Message) {
        Write-Log "  [ok]   $Message" 'DarkGray'
        $script:Stats.Skipped++
    }

    function Invoke-Step([string]$Description, [scriptblock]$Action) {
        if ($DryRun) {
            Write-Log "  [would] $Description" 'Yellow'
            $script:Stats.Changed++
            return
        }
        try {
            & $Action
            Write-Log "  [done] $Description" 'Green'
            $script:Stats.Changed++
        }
        catch {
            Write-Log "  [fail] $Description : $($_.Exception.Message)" 'Red'
            $script:Stats.Failed++
        }
    }

    function Reset-Stats {
        $script:Stats = @{ Changed = 0; Skipped = 0; Failed = 0 }
        $script:RestartNeeded = $false
        $script:RestartExplorer = $false
    }

    function Write-Summary {
        if ($script:RestartExplorer -and -not $DryRun) {
            Write-Log 'Restarting Explorer so the new settings show up...'
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        }
        Write-Section 'Summary'
        $verb = if ($DryRun) { 'Would change' } else { 'Changed' }
        Write-Log "  ${verb}: $($script:Stats.Changed)   Already OK: $($script:Stats.Skipped)   Failed: $($script:Stats.Failed)"
        if ($script:RestartNeeded) { Write-Log '  Restart Windows to finish turning features on or off.' 'Yellow' }
    }

    function Expand-PathVars([string]$Path) { [Environment]::ExpandEnvironmentVariables($Path) }

    # ---- Registry ----

    function Set-RegistryEntry {
        param([string]$Path, [string]$Name, [string]$Type = 'DWord', $Value, [switch]$RemoveKey)
        $label = if ($Name) { "$Path\$Name" } else { $Path }

        if ($RemoveKey) {
            if (-not (Test-Path $Path)) { Write-Skip "$label (already absent)"; return }
            Invoke-Step "Remove $label" { Remove-Item -Path $Path -Recurse -Force }
            return
        }
        if ($null -eq $Value) {
            if ($null -eq (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
                Write-Skip "$label (already absent)"; return
            }
            Invoke-Step "Remove $label" { Remove-ItemProperty -Path $Path -Name $Name -Force }
            return
        }

        $current = $null
        if (Test-Path $Path) { $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name }
        if ($null -ne $current -and "$current" -eq "$Value") { Write-Skip "$label = $Value"; return }

        Invoke-Step "Set $label = $Value" {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            if ($Name -eq '(Default)') { Set-Item -Path $Path -Value $Value }
            else { New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null }
        }
    }

    # ---- Actions ----

    function New-RestorePoint {
        Write-Section 'Restore point'
        Invoke-Step 'Create a system restore point' {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            # Windows only allows one restore point per 24h unless this is set.
            $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            New-ItemProperty -Path $sr -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force | Out-Null
            Checkpoint-Computer -Description "$AppName" -RestorePointType MODIFY_SETTINGS
        }
    }

    function Initialize-Winget {
        if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
        # On a fresh install App Installer is present but may not be registered yet.
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
        if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
        Write-Log '  winget is not available. Update "App Installer" in the Microsoft Store, then try again.' 'Red'
        $script:Stats.Failed++
        return $false
    }

    $script:WingetArgs = @('--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')

    # True when something matching $Pattern (wildcards OK) is in Apps & features.
    function Test-AppInstalled([string]$Pattern) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        [bool](Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern })
    }

    # True for sources the script resolves itself: files:<name> and private:<name>.
    function Test-ReleaseSource([string]$Source) { $Source -match '^(files|private):.+' }

    # Private files aren't downloadable yet: note them as a by-hand step instead of failing.
    function Test-PrivatePending([string]$Source, [string]$What) {
        if ($Source -notmatch '^private:(.+)$' -or $PrivateFilesUrl) { return $false }
        Write-Log "  [by hand] $What : copy $($Matches[1]) onto this PC yourself" 'Yellow'
        $script:Stats.Skipped++
        $true
    }

    # Downloads a files:/private: release asset, or any http(s) link, to $Path.
    function Save-RemoteFile([string]$Source, [string]$Path) {
        if ($Source -match '^files:(.+)$') {
            $url = "https://github.com/$PublicRepo/releases/download/$FilesTag/$([Uri]::EscapeDataString($Matches[1]))"
            Invoke-WebRequest -Uri $url -OutFile $Path -UseBasicParsing
            return
        }
        if ($Source -match '^private:(.+)$') {
            Invoke-WebRequest -Uri "$($PrivateFilesUrl.TrimEnd('/'))/$([Uri]::EscapeDataString($Matches[1]))" -OutFile $Path -UseBasicParsing
            return
        }
        Invoke-WebRequest -Uri $Source -OutFile $Path -UseBasicParsing
    }

    # Works out the download link for a direct app, so it always gets the latest version:
    #   url    - a fixed link (many vendors have a permanent "latest" link),
    #            or files:<name> / private:<name> (see "Where files come from" above)
    #   github - "owner/repo": newest release, first asset whose name matches the "asset" regex
    #   page   - a download page: first match of the "link" regex (group 1 if present)
    function Resolve-DownloadUrl($App) {
        if ($App.url) { return $App.url }
        if ($App.github) {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($App.github)/releases/latest" -Headers @{ 'User-Agent' = 'winsetup' }
            $pattern = if ($App.asset) { $App.asset } else { '\.(exe|msi)$' }
            $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
            if (-not $asset) { throw "no file matching '$pattern' in $($App.github) $($rel.tag_name)" }
            Write-Log "    Latest release: $($rel.tag_name)"
            return $asset.browser_download_url
        }
        if ($App.page) {
            $html = (Invoke-WebRequest -Uri $App.page -UseBasicParsing).Content
            $m = [regex]::Match($html, $App.link)
            if (-not $m.Success) { throw "no link matching '$($App.link)' on $($App.page)" }
            $href = if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value }
            return (New-Object Uri ([Uri]$App.page), ([Net.WebUtility]::HtmlDecode($href))).AbsoluteUri
        }
        throw 'needs url, github or page'
    }

    # Installs an app downloaded from the vendor. Fields besides the source:
    #   type   - exe | msi | zip | portable (guessed from the file name if left out)
    #   args   - silent switches for exe installers, e.g. /S (NSIS), /VERYSILENT (Inno), /quiet
    #   detect - DisplayName in Apps & features (wildcards OK), used to skip it if already installed
    #   target - folder for zip / portable apps (default C:\Tools\<name>)
    #   sha256 - optional checksum for fixed-version links
    function Install-DirectApp($App) {
        $name = $App.name
        $type = $App.type
        $target = if ($App.target) { Expand-PathVars $App.target } else { "C:\Tools\$name" }

        if ($App.detect -and (Test-AppInstalled $App.detect)) { Write-Skip "$name (already installed)"; return }
        if (Test-PrivatePending $App.url "Install $name") { return }
        if ($type -in 'zip', 'portable' -and -not $App.detect -and (Test-Path $target)) { Write-Skip "$name (already in $target)"; return }
        if ($type -ne 'msi' -and $type -notin 'zip', 'portable' -and -not $App.args) {
            Write-Log "    $name has no silent switches, so its installer window may open." 'Yellow'
        }

        Write-Log "  Downloading $name ..."
        Invoke-Step "Install $name (direct download)" {
            $url = Resolve-DownloadUrl $App
            $file = if (Test-ReleaseSource $url) { $url -replace '^\w+:' } else { [IO.Path]::GetFileName(([Uri]$url).AbsolutePath) }
            if (-not $type) {
                $type = switch -Regex ($file) { '\.msi$' { 'msi' } '\.zip$' { 'zip' } default { 'exe' } }
            }
            if (-not $file) { $file = "$name.$type" }
            $dir = Join-Path $env:TEMP 'winsetup-downloads'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $path = Join-Path $dir $file
            Save-RemoteFile $url $path
            if ($App.sha256 -and (Get-FileHash $path -Algorithm SHA256).Hash -ne $App.sha256) { throw 'checksum does not match' }

            $proc = $null
            switch ($type) {
                'msi' {
                    $msiArgs = "/i `"$path`" /qn /norestart $($App.args)"
                    $proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
                }
                'exe' {
                    if ($App.args) { $proc = Start-Process -FilePath $path -ArgumentList $App.args -Wait -PassThru }
                    else { $proc = Start-Process -FilePath $path -Wait -PassThru }
                }
                'zip' { Expand-Archive -Path $path -DestinationPath $target -Force }
                'portable' {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    Copy-Item -Path $path -Destination $target -Force
                }
                default { throw "unknown type '$type'" }
            }
            # 3010 / 1641 = installed, restart required
            if ($proc -and $proc.ExitCode -notin 0, 3010, 1641) { throw "installer exit code $($proc.ExitCode)" }
        }
    }

    function Install-WingetApp([string]$Id) {
        winget list --id $Id --exact --accept-source-agreements --disable-interactivity *> $null
        if ($LASTEXITCODE -eq 0) { Write-Skip "$Id (already installed)"; return }
        Write-Log "  Installing $Id ..."
        Invoke-Step "Install $Id" {
            $out = winget install --id $Id --exact @script:WingetArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE. $(($out | Select-Object -Last 1))" }
        }
    }

    # $Apps: winget IDs, catalog Ids ("direct:..."), or direct-download objects.
    function Install-Apps($Apps) {
        $Apps = @($Apps | Where-Object { $_ })
        if (-not $Apps) { return }
        Write-Section 'Install apps'
        $wingetReady = $null
        foreach ($a in $Apps) {
            $app = if ($a -is [string]) { $AppIndex[$a] } else { $a }
            if ($app -and ($app.url -or $app.github -or $app.page)) { Install-DirectApp $app; continue }

            $id = if ($a -is [string]) { $a } else { $a.id }
            if ($null -eq $wingetReady) { $wingetReady = Initialize-Winget }
            if (-not $wingetReady) { Write-Log "  [fail] $id (winget not available)" 'Red'; $script:Stats.Failed++; continue }
            Install-WingetApp $id
        }
    }

    function Update-AllApps {
        Write-Section 'Upgrade all apps'
        if (-not (Initialize-Winget)) { return }
        Invoke-Step 'Upgrade every installed app to its latest version' {
            winget upgrade --all --include-unknown @script:WingetArgs 2>&1 | Out-Null
        }
    }

    function Remove-BuiltInApps([string[]]$Names) {
        $Names = @($Names | Where-Object { $_ })
        if (-not $Names) { return }
        Write-Section 'Remove built-in apps'
        foreach ($name in $Names) {
            $pkgs = @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)
            $prov = @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -EQ $name)
            if (-not $pkgs -and -not $prov) { Write-Skip "$name (not installed)"; continue }
            Invoke-Step "Remove $name" {
                $pkgs | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                # Removing the provisioned copy stops it coming back for new users.
                $prov | Remove-AppxProvisionedPackage -Online | Out-Null
            }
        }
    }

    function New-Folders([string[]]$Paths) {
        if (-not $Paths) { return }
        Write-Section 'Folders'
        foreach ($p in $Paths) {
            if (-not $p.Trim()) { continue }
            $path = Expand-PathVars $p.Trim()
            if (Test-Path $path) { Write-Skip "$path (exists)"; continue }
            Invoke-Step "Create $path" { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        }
    }

    # Source can be a URL, files:<name> / private:<name>, an absolute path, or a path relative to the preset file.
    function Copy-ConfigFiles($Files, [string]$BaseDir) {
        $Files = @($Files | Where-Object { $_ })
        if (-not $Files) { return }
        Write-Section 'Files'
        foreach ($f in $Files) {
            $dst = Expand-PathVars $f.destination
            if ($null -ne $f.content) {
                # Inline text file. Existing files are kept unless overwrite is set.
                if (Test-Path $dst) {
                    if ((Get-Content -Path $dst -Raw) -eq $f.content) { Write-Skip "$dst (up to date)"; continue }
                    if (-not $f.overwrite) { Write-Skip "$dst (exists, kept)"; continue }
                }
                $text = [string]$f.content
                Invoke-Step "Write $dst" {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                    Set-Content -Path $dst -Value $text -NoNewline -Encoding UTF8
                }
                continue
            }
            $src = Expand-PathVars $f.source
            if ($src -match '^https?://' -or (Test-ReleaseSource $src)) {
                if ((Test-Path $dst) -and -not $f.overwrite -and (Test-ReleaseSource $src)) { Write-Skip "$dst (exists, kept)"; continue }
                if (Test-PrivatePending $src $dst) { continue }
                Invoke-Step "Download $src -> $dst" {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                    Save-RemoteFile $src $dst
                }
                continue
            }
            if (-not [IO.Path]::IsPathRooted($src) -and $BaseDir) { $src = Join-Path $BaseDir $src }
            if (-not (Test-Path $src)) {
                Write-Log "  [fail] Source not found: $src" 'Red'; $script:Stats.Failed++; continue
            }
            if ((Test-Path $dst) -and (Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash) {
                Write-Skip "$dst (up to date)"; continue
            }
            Invoke-Step "Copy $src -> $dst" {
                New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
                Copy-Item -Path $src -Destination $dst -Force
            }
        }
    }

    function Add-QuickAccess([string[]]$Paths) {
        $Paths = @($Paths | Where-Object { $_ -and $_.Trim() })
        if (-not $Paths) { return }
        Write-Section 'Quick Access'
        $shell = New-Object -ComObject Shell.Application
        $pinned = @($shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}').Items() | ForEach-Object { $_.Path })
        foreach ($p in $Paths) {
            $path = Expand-PathVars $p.Trim()
            if ($pinned -contains $path) { Write-Skip "$path (already pinned)"; continue }
            Invoke-Step "Pin $path to Quick Access" {
                if (-not (Test-Path $path)) { throw 'folder does not exist' }
                $shell.Namespace($path).Self.InvokeVerb('pintohome')
            }
        }
    }

    # $Template: a key of $FolderTemplates, or an object with label/folders/pin/files.
    function Invoke-FolderTemplate($Template, [string]$BaseDir) {
        $t = if ($Template -is [string]) { $FolderTemplates[$Template] } else { $Template }
        if (-not $t) { Write-Log "  [fail] Unknown folder template '$Template'" 'Red'; $script:Stats.Failed++; return }
        $label = if ($t.label) { $t.label } else { 'Custom' }
        Write-Section "Template: $label"
        New-Folders @($t.folders)
        Copy-ConfigFiles @($t.files | Where-Object { $_ }) $BaseDir
        Add-QuickAccess @($t.pin)
    }

    # $Tweaks: hashtable of TweakName -> $true (apply) / $false (undo)
    function Set-Tweaks([hashtable]$Tweaks) {
        if (-not $Tweaks -or -not $Tweaks.Count) { return }
        Write-Section 'Tweaks'
        foreach ($name in $Tweaks.Keys) {
            $tweak = $TweakCatalog[$name]
            if (-not $tweak) {
                Write-Log "  [fail] Unknown tweak '$name'" 'Red'; $script:Stats.Failed++; continue
            }
            $apply = [bool]$Tweaks[$name]
            Write-Log "  $($tweak.Label): $(if ($apply) { 'apply' } else { 'undo' })"
            $before = $script:Stats.Changed
            $entries = if ($apply) { $tweak.On } else { $tweak.Off }
            foreach ($e in $entries) { Set-RegistryEntry @e }
            if ($script:Stats.Changed -gt $before) { $script:RestartExplorer = $true }
        }
    }

    function Set-RegistryValues($Entries) {
        if (-not $Entries) { return }
        Write-Section 'Registry'
        foreach ($r in $Entries) {
            $type = if ($r.type) { $r.type } else { 'DWord' }
            Set-RegistryEntry -Path $r.path -Name $r.name -Type $type -Value $r.value
        }
    }

    function Set-Features([string[]]$Enable, [string[]]$Disable) {
        $Enable = @($Enable | Where-Object { $_ })
        $Disable = @($Disable | Where-Object { $_ })
        if (-not $Enable -and -not $Disable) { return }
        Write-Section 'Windows features'
        $wanted = @()
        foreach ($f in $Enable) { $wanted += @{ Name = $f; On = $true } }
        foreach ($f in $Disable) { $wanted += @{ Name = $f; On = $false } }
        foreach ($w in $wanted) {
            $name = $w.Name
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
            if (-not $feature) {
                Write-Log "  [fail] Feature '$name' is not available on this edition of Windows" 'Red'
                $script:Stats.Failed++; continue
            }
            if (($feature.State -eq 'Enabled') -eq $w.On) { Write-Skip "$name ($($feature.State))"; continue }
            if ($w.On) {
                Invoke-Step "Enable $name" {
                    $r = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
                    if ($r.RestartNeeded) { $script:RestartNeeded = $true }
                }
            }
            else {
                Invoke-Step "Disable $name" {
                    $r = Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart
                    if ($r.RestartNeeded) { $script:RestartNeeded = $true }
                }
            }
        }
    }

    # Converts the JSON "tweaks" object into a hashtable.
    function ConvertTo-TweakTable($Obj) {
        $t = @{}
        if ($Obj) { foreach ($p in $Obj.PSObject.Properties) { $t[$p.Name] = [bool]$p.Value } }
        $t
    }

    # Applies a whole preset. Callers wrap it with Reset-Stats / Write-Summary.
    function Invoke-Preset($Config, [string]$BaseDir) {
        $tweaks = ConvertTo-TweakTable $Config.tweaks
        if ($Config.restorePoint -ne $false -and ($tweaks.Count -or $Config.registry -or $Config.removeApps)) { New-RestorePoint }
        Install-Apps @($Config.apps.install)
        if ($Config.apps.upgradeAll) { Update-AllApps }
        Remove-BuiltInApps @($Config.removeApps)
        foreach ($t in @($Config.folderTemplates | Where-Object { $_ })) { Invoke-FolderTemplate $t $BaseDir }
        New-Folders @($Config.folders)
        Add-QuickAccess @($Config.quickAccess)
        Copy-ConfigFiles $Config.files $BaseDir
        Set-Tweaks $tweaks
        Set-RegistryValues $Config.registry
        Set-Features @($Config.features.enable) @($Config.features.disable)
    }
}

. $Engine

# --- Unattended mode ---------------------------------------------------------

function Read-Preset([string]$PathOrUrl) {
    if ($PathOrUrl -match '^https?://') {
        return @{ Config = (Invoke-RestMethod -Uri $PathOrUrl); BaseDir = $null }
    }
    $full = (Resolve-Path $PathOrUrl).Path
    @{ Config = (Get-Content -Path $full -Raw | ConvertFrom-Json); BaseDir = (Split-Path -Parent $full) }
}

if ($Run) {
    if (-not $Preset) { throw '-Run needs -Preset <file or URL>' }
    $logFile = Join-Path $env:TEMP ("winsetup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    Start-Transcript -Path $logFile | Out-Null
    Write-Host "$AppName $AppVersion" -ForegroundColor Cyan
    if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Yellow }
    $p = Read-Preset $Preset
    Reset-Stats
    Invoke-Preset $p.Config $p.BaseDir
    Write-Summary
    Write-Host "Log: $logFile"
    Stop-Transcript | Out-Null
    return
}

# --- Window ------------------------------------------------------------------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="__TITLE__" Width="1120" Height="780" MinWidth="820" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#14161F" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E4E6F0"/></Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E6F0"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#8FB4FF"/>
      <Setter Property="BorderBrush" Value="#2C3042"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Width" Value="250"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#3B6FF6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2C3042"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="18,9" Margin="0,0,4,0" CornerRadius="6,6,0,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header" TextElement.Foreground="#C9CCDA" TextElement.FontSize="14"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1D2030"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel>
    <Border DockPanel.Dock="Top" Padding="20,14" Background="#0F1118">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="DryRunBox" Content="Dry run (preview only)" VerticalAlignment="Center" Margin="0,0,16,0"/>
          <Button x:Name="RunAllBtn" Content="Run everything selected"/>
        </StackPanel>
        <StackPanel>
          <TextBlock x:Name="TitleText" FontSize="20" FontWeight="SemiBold"/>
          <TextBlock Text="Pick what you want, then run. Everything already in place is skipped." Foreground="#8A8FA6"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border DockPanel.Dock="Bottom" Background="#0F1118" Height="170" Padding="12,8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
          <Button x:Name="ClearLogBtn" DockPanel.Dock="Right" Content="Clear" Style="{StaticResource Secondary}" Padding="10,3" Margin="0"/>
          <TextBlock x:Name="StatusText" Text="Ready" Foreground="#8A8FA6" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox x:Name="LogBox" IsReadOnly="True" Background="#0A0B10" Foreground="#B9F6CA" BorderThickness="0"
                 FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
      </DockPanel>
    </Border>

    <TabControl x:Name="Tabs" Background="#1D2030" BorderThickness="0" Padding="16" Margin="12,10,12,0">
      <TabItem Header="Install">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,12">
            <TextBox x:Name="AppSearch" Width="220" Padding="6,5" Margin="0,0,12,0" Background="#14161F" Foreground="White" BorderBrush="#2C3042" ToolTip="Filter apps"/>
            <Button x:Name="InstallBtn" Content="Install selected"/>
            <Button x:Name="UpgradeBtn" Content="Upgrade all apps" Style="{StaticResource Secondary}"/>
            <Button x:Name="AppsNoneBtn" Content="Clear selection" Style="{StaticResource Secondary}"/>
          </StackPanel>
          <Border DockPanel.Dock="Top" Background="#14161F" CornerRadius="6" Padding="10" Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="Not in the list? Add it by download link, GitHub owner/repo (always the latest release), or winget ID." Foreground="#8A8FA6" Margin="0,0,0,6"/>
              <StackPanel Orientation="Horizontal">
                <TextBox x:Name="AddName" Width="150" Padding="6,5" Margin="0,0,8,0" Background="#1D2030" Foreground="White" BorderBrush="#2C3042" ToolTip="App name"/>
                <TextBox x:Name="AddSource" Width="330" Padding="6,5" Margin="0,0,8,0" Background="#1D2030" Foreground="White" BorderBrush="#2C3042" ToolTip="https://vendor.com/setup.exe  or  owner/repo  or  Vendor.App"/>
                <TextBox x:Name="AddArgs" Width="130" Padding="6,5" Margin="0,0,8,0" Background="#1D2030" Foreground="White" BorderBrush="#2C3042" ToolTip="Silent switches, e.g. /S, /VERYSILENT, /quiet"/>
                <Button x:Name="AddAppBtn" Content="Add app" Style="{StaticResource Secondary}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                <TextBlock Text="Name" Width="158" Foreground="#5D6278" FontSize="11"/>
                <TextBlock Text="Link, owner/repo or winget ID" Width="338" Foreground="#5D6278" FontSize="11"/>
                <TextBlock Text="Silent switches (exe only)" Foreground="#5D6278" FontSize="11"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><WrapPanel x:Name="AppPanel"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Tweaks">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="ApplyTweaksBtn" Content="Apply selected"/>
            <Button x:Name="UndoTweaksBtn" Content="Undo selected" Style="{StaticResource Secondary}"/>
            <Button x:Name="RecommendedBtn" Content="Select recommended" Style="{StaticResource Secondary}"/>
            <Button x:Name="TweaksNoneBtn" Content="Clear selection" Style="{StaticResource Secondary}"/>
            <CheckBox x:Name="RestorePointBox" Content="Create a restore point first" IsChecked="True" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <WrapPanel>
              <GroupBox Header="Windows tweaks" Width="520"><StackPanel x:Name="TweakPanel"/></GroupBox>
              <GroupBox Header="Remove built-in apps" Width="300">
                <StackPanel>
                  <StackPanel x:Name="BloatPanel"/>
                  <Button x:Name="RemoveAppsBtn" Content="Remove selected" Margin="0,10,0,0" HorizontalAlignment="Left"/>
                </StackPanel>
              </GroupBox>
            </WrapPanel>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Features">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="EnableFeaturesBtn" Content="Turn on selected"/>
            <Button x:Name="DisableFeaturesBtn" Content="Turn off selected" Style="{StaticResource Secondary}"/>
          </StackPanel>
          <GroupBox Header="Optional Windows features" Width="420" HorizontalAlignment="Left"><StackPanel x:Name="FeaturePanel"/></GroupBox>
        </DockPanel>
      </TabItem>

      <TabItem Header="Folders">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,12">
            <Button x:Name="CreateFoldersBtn" Content="Create selected templates and folders"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <WrapPanel>
              <GroupBox Header="Templates" Width="420">
                <StackPanel>
                  <TextBlock Text="Ready-made layouts. Hover one to see its folders." Foreground="#8A8FA6" FontSize="12" Margin="0,0,0,6"/>
                  <StackPanel x:Name="TemplatePanel"/>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="Your folders" Width="440">
                <StackPanel>
                  <TextBlock Text="One folder per line. Variables like %USERPROFILE% work." Foreground="#8A8FA6" FontSize="12" Margin="0,0,0,6"/>
                  <TextBox x:Name="FolderBox" AcceptsReturn="True" Background="#14161F" Foreground="White" BorderBrush="#2C3042"
                           FontFamily="Consolas" Padding="8" Height="180" VerticalScrollBarVisibility="Auto"/>
                  <CheckBox x:Name="PinFoldersBox" Content="Pin these to Quick Access" Margin="0,8,0,0"/>
                </StackPanel>
              </GroupBox>
            </WrapPanel>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Presets">
        <StackPanel>
          <TextBlock TextWrapping="Wrap" Foreground="#8A8FA6" Margin="0,0,0,12" MaxWidth="640" HorizontalAlignment="Left"
                     Text="Save everything you have selected on the other tabs as a preset file. Load it on the next PC, or run it without the window:"/>
          <TextBox x:Name="PresetCmd" IsReadOnly="True" Background="#0A0B10" Foreground="#B9F6CA" BorderThickness="0"
                   FontFamily="Consolas" Padding="8" Margin="0,0,0,16" HorizontalAlignment="Left" MaxWidth="900" TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="ExportBtn" Content="Save selections as preset..."/>
            <Button x:Name="ImportBtn" Content="Load preset..." Style="{StaticResource Secondary}"/>
          </StackPanel>
        </StackPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$window.Title = "$AppName $AppVersion"

$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object LocalName -EQ 'Name' | Select-Object -ExpandProperty Value
    $ui[$n] = $window.FindName($n)
}
$ui.TitleText.Text = $AppName
$ui.PresetCmd.Text = "& ([scriptblock]::Create((irm $SourceUrl))) -Preset C:\path\to\preset.json -Run"

# Shared state with the background runspace.
$sync = [hashtable]::Synchronized(@{})
$sync.LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$sync.Busy = $false

# --- Build the lists ---

$appBoxes = New-Object System.Collections.Generic.List[object]
$customApps = @{}   # Tag -> direct-download object or winget ID added from the window / a preset
foreach ($cat in $AppCatalog.Keys) {
    $group = New-Object System.Windows.Controls.GroupBox
    $group.Header = $cat
    $stack = New-Object System.Windows.Controls.StackPanel
    foreach ($app in $AppCatalog[$cat]) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.Name
        $cb.Tag = $app.Id
        $cb.ToolTip = if ($app.github) { "Latest release from github.com/$($app.github)" } elseif ($app.url -or $app.page) { 'Direct download' } else { $app.Id }
        [void]$stack.Children.Add($cb)
        $appBoxes.Add($cb)
    }
    $group.Content = $stack
    [void]$ui.AppPanel.Children.Add($group)
}

# "Your apps" group, for apps added from the window or from a preset.
$customGroup = New-Object System.Windows.Controls.GroupBox
$customGroup.Header = 'Your apps'
$customStack = New-Object System.Windows.Controls.StackPanel
$customGroup.Content = $customStack
$customGroup.Visibility = 'Collapsed'
[void]$ui.AppPanel.Children.Insert(0, $customGroup)

# $App is a winget ID string or a direct-download object. Returns the checkbox.
function Add-CustomApp($App) {
    if ($App -is [string]) { $tag = $App; $label = $App; $tip = "winget: $App" }
    else {
        $tag = "custom:$($App.name)"; $label = $App.name
        $tip = if ($App.github) { "Latest release from github.com/$($App.github)" } elseif ($App.page) { "Latest link on $($App.page)" } else { $App.url }
    }
    $existing = $appBoxes | Where-Object { [string]$_.Tag -eq $tag } | Select-Object -First 1
    if ($existing) { $customApps[$tag] = $App; return $existing }
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $label
    $cb.Tag = $tag
    $cb.ToolTip = $tip
    $cb.IsChecked = $true
    [void]$customStack.Children.Add($cb)
    $appBoxes.Add($cb)
    $customApps[$tag] = $App
    $customGroup.Visibility = 'Visible'
    $cb
}

# Checked apps as Install-Apps / presets expect them: strings, or objects for custom direct apps.
function Get-CheckedApps {
    @(foreach ($tag in (Get-Checked $appBoxes)) {
            if ($customApps.ContainsKey($tag)) { $customApps[$tag] } else { $tag }
        })
}

$tweakBoxes = @()
foreach ($key in $TweakCatalog.Keys) {
    $t = $TweakCatalog[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $label = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = if ($t.Recommended) { "$($t.Label)  (recommended)" } else { $t.Label }
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = $t.Description
    $desc.Foreground = '#8A8FA6'
    $desc.FontSize = 12
    $desc.TextWrapping = 'Wrap'
    [void]$label.Children.Add($title)
    [void]$label.Children.Add($desc)
    $cb.Content = $label
    $cb.Tag = $key
    $cb.Margin = '0,4'
    [void]$ui.TweakPanel.Children.Add($cb)
    $tweakBoxes += $cb
}

$bloatBoxes = @()
foreach ($key in $BuiltInAppCatalog.Keys) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $BuiltInAppCatalog[$key]
    $cb.Tag = $key
    $cb.ToolTip = $key
    [void]$ui.BloatPanel.Children.Add($cb)
    $bloatBoxes += $cb
}

$featureBoxes = @()
foreach ($key in $FeatureCatalog.Keys) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $FeatureCatalog[$key]
    $cb.Tag = $key
    $cb.ToolTip = $key
    [void]$ui.FeaturePanel.Children.Add($cb)
    $featureBoxes += $cb
}

$templateBoxes = @()
foreach ($key in $FolderTemplates.Keys) {
    $t = $FolderTemplates[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $label = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $t.Label
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = $t.Description
    $desc.Foreground = '#8A8FA6'
    $desc.FontSize = 12
    $desc.TextWrapping = 'Wrap'
    [void]$label.Children.Add($title)
    [void]$label.Children.Add($desc)
    $cb.Content = $label
    $cb.Tag = $key
    $cb.Margin = '0,4'
    $tip = ($t.Folders -join "`n")
    if ($t.Pin) { $tip += "`n`nPinned to Quick Access:`n" + ($t.Pin -join "`n") }
    $cb.ToolTip = $tip
    [void]$ui.TemplatePanel.Children.Add($cb)
    $templateBoxes += $cb
}

$ui.FolderBox.Text = "C:\Tools`r`n%USERPROFILE%\Projects"

function Get-Checked($Boxes) { @($Boxes | Where-Object IsChecked | ForEach-Object { [string]$_.Tag }) }
function Set-Checked($Boxes, [string[]]$Tags) { foreach ($b in $Boxes) { $b.IsChecked = $Tags -contains [string]$b.Tag } }

# --- Background runner ---

$allButtons = @('RunAllBtn', 'InstallBtn', 'UpgradeBtn', 'ApplyTweaksBtn', 'UndoTweaksBtn', 'RemoveAppsBtn',
    'EnableFeaturesBtn', 'DisableFeaturesBtn', 'CreateFoldersBtn', 'ImportBtn')

# Runs $Script (text) in a new runspace with the engine loaded and $Job available.
function Start-EngineJob([string]$Script, $Job) {
    if ($sync.Busy) { return }
    $sync.Busy = $true
    $sync.UiLocked = $true
    foreach ($b in $allButtons) { $ui[$b].IsEnabled = $false }
    $ui.StatusText.Text = 'Working... (you can keep browsing, buttons come back when it is done)'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('Job', $Job)
    $rs.SessionStateProxy.SetVariable('DryRun', [bool]$ui.DryRunBox.IsChecked)
    $rs.SessionStateProxy.SetVariable('AppName', $AppName)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $body = $Engine.ToString() + "`n" + @"
try {
    Reset-Stats
    if (`$DryRun) { Write-Log 'DRY RUN: nothing will be changed.' }
    $Script
    Write-Summary
}
catch { Write-Log "Error: `$(`$_.Exception.Message)" }
finally { `$sync.Busy = `$false }
"@
    [void]$ps.AddScript($body)
    [void]$ps.BeginInvoke()
}

# Drain log lines and re-enable buttons from the UI thread.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
        $line = $null
        $added = $false
        while ($sync.LogQueue.TryDequeue([ref]$line)) { $ui.LogBox.AppendText("$line`r`n"); $added = $true }
        if ($added) { $ui.LogBox.ScrollToEnd() }
        if ($sync.UiLocked -and -not $sync.Busy) {
            $sync.UiLocked = $false
            foreach ($b in $allButtons) { $ui[$b].IsEnabled = $true }
            $ui.StatusText.Text = 'Done'
        }
    })
$timer.Start()

# --- Build and load presets ---

function Get-SelectionPreset {
    $tweaks = [ordered]@{}
    foreach ($k in (Get-Checked $tweakBoxes)) { $tweaks[$k] = $true }
    [ordered]@{
        restorePoint = [bool]$ui.RestorePointBox.IsChecked
        apps         = [ordered]@{ install = @(Get-CheckedApps); upgradeAll = $false }
        removeApps   = @(Get-Checked $bloatBoxes)
        folderTemplates = @(Get-Checked $templateBoxes)
        folders      = @($ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() })
        quickAccess  = @(if ($ui.PinFoldersBox.IsChecked) { $ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() } })
        files        = @()
        tweaks       = $tweaks
        registry     = @()
        features     = [ordered]@{ enable = @(Get-Checked $featureBoxes); disable = @() }
    }
}

function Set-SelectionFromPreset($Config) {
    # Anything not in the catalog (other winget IDs, direct downloads) goes under "Your apps".
    $tags = foreach ($a in @($Config.apps.install | Where-Object { $_ })) {
        if ($a -isnot [string]) { [string](Add-CustomApp $a).Tag }
        elseif ($AppIndex.ContainsKey($a)) { $a }
        else { [string](Add-CustomApp $a).Tag }
    }
    Set-Checked $appBoxes @($tags)
    Set-Checked $bloatBoxes @($Config.removeApps)
    Set-Checked $featureBoxes @($Config.features.enable)
    $on = @()
    if ($Config.tweaks) { $on = @($Config.tweaks.PSObject.Properties | Where-Object Value | ForEach-Object Name) }
    Set-Checked $tweakBoxes $on
    if ($Config.folders) { $ui.FolderBox.Text = (@($Config.folders) -join "`r`n") }
    Set-Checked $templateBoxes @($Config.folderTemplates | Where-Object { $_ -is [string] })
    $ui.PinFoldersBox.IsChecked = [bool]$Config.quickAccess
    if ($null -ne $Config.restorePoint) { $ui.RestorePointBox.IsChecked = [bool]$Config.restorePoint }
}

# --- Wire up buttons ---

$ui.ClearLogBtn.Add_Click({ $ui.LogBox.Clear() })

$ui.AppSearch.Add_TextChanged({
        $q = $ui.AppSearch.Text.Trim()
        foreach ($cb in $appBoxes) {
            $match = -not $q -or $cb.Content -like "*$q*" -or $cb.Tag -like "*$q*"
            $cb.Visibility = if ($match) { 'Visible' } else { 'Collapsed' }
        }
    })

$ui.AppsNoneBtn.Add_Click({ Set-Checked $appBoxes @() })
$ui.TweaksNoneBtn.Add_Click({ Set-Checked $tweakBoxes @() })
$ui.RecommendedBtn.Add_Click({
        Set-Checked $tweakBoxes @($TweakCatalog.Keys | Where-Object { $TweakCatalog[$_].Recommended })
    })

$ui.InstallBtn.Add_Click({
        $apps = Get-CheckedApps
        if (-not $apps) { $sync.LogQueue.Enqueue('Tick some apps first.'); return }
        # Round-trip through JSON so custom apps reach the runspace as plain data.
        Start-EngineJob '$apps = $Job | ConvertFrom-Json; Install-Apps $apps' (ConvertTo-Json @($apps) -Depth 5)
    })

$ui.UpgradeBtn.Add_Click({ Start-EngineJob 'Update-AllApps' $null })

# Add an app by link: https://... (direct download), owner/repo (GitHub latest release),
# or anything else is treated as a winget ID.
$ui.AddAppBtn.Add_Click({
        $src = $ui.AddSource.Text.Trim()
        $name = $ui.AddName.Text.Trim()
        $silent = $ui.AddArgs.Text.Trim()
        if (-not $src) { $sync.LogQueue.Enqueue('Enter a download link, a GitHub owner/repo, or a winget ID.'); return }
        if ($src -match '^https?://' -or $src -match '^[\w.-]+/[\w.-]+$') {
            if (-not $name) { $sync.LogQueue.Enqueue('Give the app a name too.'); return }
            $app = [ordered]@{ name = $name }
            if ($src -match '^https?://') { $app.url = $src } else { $app.github = $src }
            if ($silent) { $app.args = $silent }
            $app.detect = "*$name*"
            [void](Add-CustomApp ([pscustomobject]$app))
        }
        else {
            [void](Add-CustomApp $src)
        }
        $ui.AddSource.Clear(); $ui.AddName.Clear(); $ui.AddArgs.Clear()
        $sync.LogQueue.Enqueue("Added $(if ($name) { $name } else { $src }) under 'Your apps'. Save a preset to keep it.")
    })

function Start-TweakJob([bool]$Apply) {
    $keys = Get-Checked $tweakBoxes
    if (-not $keys) { $sync.LogQueue.Enqueue('Tick some tweaks first.'); return }
    $table = @{}
    foreach ($k in $keys) { $table[$k] = $Apply }
    $cmd = if ($ui.RestorePointBox.IsChecked) { 'New-RestorePoint; Set-Tweaks $Job' } else { 'Set-Tweaks $Job' }
    Start-EngineJob $cmd $table
}
$ui.ApplyTweaksBtn.Add_Click({ Start-TweakJob $true })
$ui.UndoTweaksBtn.Add_Click({ Start-TweakJob $false })

$ui.RemoveAppsBtn.Add_Click({
        $names = Get-Checked $bloatBoxes
        if (-not $names) { $sync.LogQueue.Enqueue('Tick some built-in apps first.'); return }
        Start-EngineJob 'Remove-BuiltInApps $Job' $names
    })

$ui.EnableFeaturesBtn.Add_Click({
        $f = Get-Checked $featureBoxes
        if (-not $f) { $sync.LogQueue.Enqueue('Tick some features first.'); return }
        Start-EngineJob 'Set-Features -Enable $Job' $f
    })
$ui.DisableFeaturesBtn.Add_Click({
        $f = Get-Checked $featureBoxes
        if (-not $f) { $sync.LogQueue.Enqueue('Tick some features first.'); return }
        Start-EngineJob 'Set-Features -Disable $Job' $f
    })

$ui.CreateFoldersBtn.Add_Click({
        $folders = @($ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() })
        $job = @{ Templates = @(Get-Checked $templateBoxes); Folders = $folders; Pin = [bool]$ui.PinFoldersBox.IsChecked }
        Start-EngineJob 'foreach ($t in $Job.Templates) { Invoke-FolderTemplate $t }; New-Folders $Job.Folders; if ($Job.Pin) { Add-QuickAccess $Job.Folders }' $job
    })

# Run everything: round-trip through JSON so it behaves exactly like a saved preset.
$ui.RunAllBtn.Add_Click({
        $json = Get-SelectionPreset | ConvertTo-Json -Depth 6
        Start-EngineJob '$cfg = $Job | ConvertFrom-Json; Invoke-Preset $cfg $null' $json
    })

$ui.ExportBtn.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Preset (*.json)|*.json'
        $dlg.FileName = 'my-pc.json'
        if ($dlg.ShowDialog()) {
            Get-SelectionPreset | ConvertTo-Json -Depth 6 | Set-Content -Path $dlg.FileName -Encoding UTF8
            $sync.LogQueue.Enqueue("Saved preset to $($dlg.FileName)")
        }
    })

$ui.ImportBtn.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Preset (*.json)|*.json'
        if ($dlg.ShowDialog()) {
            try {
                Set-SelectionFromPreset (Get-Content -Path $dlg.FileName -Raw | ConvertFrom-Json)
                $sync.LogQueue.Enqueue("Loaded preset $($dlg.FileName). Review the tabs, then run.")
            }
            catch { $sync.LogQueue.Enqueue("Could not read preset: $($_.Exception.Message)") }
        }
    })

if ($Preset) {
    try {
        Set-SelectionFromPreset (Read-Preset $Preset).Config
        $sync.LogQueue.Enqueue("Loaded preset $Preset")
    }
    catch { $sync.LogQueue.Enqueue("Could not read preset: $($_.Exception.Message)") }
}

$sync.LogQueue.Enqueue("$AppName $AppVersion ready. Running as administrator.")
[void]$window.ShowDialog()
$timer.Stop()
