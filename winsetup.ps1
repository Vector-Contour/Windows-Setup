<#
.SYNOPSIS
    VectorContour Windows Setup: set up a fresh Windows install from one window.

.DESCRIPTION
    The first tab sets up a PC the Vector Contour way (company preset, one button).
    The other tabs are a full Windows utility in the style of Chris Titus Tech's
    WinUtil, built from WinUtil's own catalog (MIT licence, see winutil/LICENSE):
    install and upgrade 200+ apps with winget or Chocolatey, essential and advanced
    tweaks with undo, preference switches, DNS, Windows features, fixes, legacy
    control panels and Windows Update modes. Selections can be saved as a JSON
    preset and replayed without the window. WinUtil's exported configs load too.

    Run from the web (PowerShell as admin):
        irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1 | iex

    Run a preset without the window:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/main/winsetup.ps1))) -Preset .\my-pc.json -Run

    Run locally:
        .\winsetup.ps1                      # open the window
        .\winsetup.ps1 -Preset x.json -Run  # unattended
        .\winsetup.ps1 -Preset x.json -Run -DryRun
        .\winsetup.ps1 -Catalog pinned      # use this repo's copy of the WinUtil catalog
#>
param(
    [string]$Preset,
    [switch]$Run,
    [switch]$DryRun,
    # latest = WinUtil's catalog straight from Chris Titus Tech (falls back to the pinned copy)
    # pinned = the copy in this repo (winutil/config), for a setup that never changes under you
    [ValidateSet('latest', 'pinned')]
    [string]$Catalog = 'latest',
    # Branch of the GitHub repo to load presets, the pinned catalog and (when relaunching
    # as admin) this script from. Only for testing a change before it is merged.
    [string]$Branch = 'main'
)

$AppName = 'VectorContour Windows Setup'
$AppVersion = '1.0.0'
$RepoRaw = "https://raw.githubusercontent.com/Vector-Contour/Windows-Setup/$Branch"
$SourceUrl = "$RepoRaw/winsetup.ps1"
$WinUtilRaw = 'https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/config'

# Setups offered on the Vector Contour tab: label -> file in presets/ ($null = start empty).
# The first one is selected when the window opens.
$CompanyPresets = [ordered]@{
    'Machine PC (reference capture)' = 'machine-pc.json'
    'Office PC (example)'            = 'example.json'
    'Nothing (pick on the other tabs)' = $null
}

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
    if ($Catalog -ne 'latest') { $passArgs += "-Catalog $Catalog" }
    if ($Branch -ne 'main') { $passArgs += "-Branch '$Branch'" }
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
        TaskbarEndTask              = @{
            Label = 'End task on taskbar right-click'; Recommended = $false
            Description = 'Add "End task" to the right-click menu of taskbar apps.'
            On = @(@{ Path = "$adv\TaskbarDeveloperSettings"; Name = 'TaskbarEndTask'; Value = 1 })
            Off = @(@{ Path = "$adv\TaskbarDeveloperSettings"; Name = 'TaskbarEndTask'; Value = 0 })
        }
        TitleBarFullPath            = @{
            Label = 'Full path in File Explorer title bar'; Recommended = $false
            Description = 'Show the whole folder path at the top of File Explorer windows.'
            On = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Value = 1 })
            Off = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Value = 0 })
        }
        DisableNotifications        = @{
            Label = 'Turn off notifications'; Recommended = $false
            Description = 'No pop-up notifications from apps or Windows (Settings > System > Notifications).'
            On = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 })
            Off = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 1 })
        }
        EnableLongPaths             = @{
            Label = 'Allow long file paths'; Recommended = $false
            Description = 'Let apps use paths longer than 260 characters (deep folder trees, long file names).'
            On = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 1 })
            Off = @(@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Value = 0 })
        }
        DisplayScaling100           = @{
            Label = 'Display scaling 100%'; Recommended = $false
            Description = 'Fixed 100% text and app size on every screen. Takes effect after signing out. Undo goes back to the Windows default for each screen.'
            On = @(
                @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'LogPixels'; Value = 96 }
                @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'Win8DpiScaling'; Value = 1 }
            )
            Off = @(
                @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'LogPixels'; Value = $null }
                @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'Win8DpiScaling'; Value = 0 }
            )
        }
        NoEdgeDesktopShortcut       = @{
            Label = 'No Edge shortcut on the desktop'; Recommended = $false
            Description = 'Remove the Microsoft Edge desktop shortcut and stop Edge updates putting it back.'
            On = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcutDefault'; Value = 0 })
            Off = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcutDefault'; Value = $null })
            Apply = { Remove-Shortcuts @('%PUBLIC%\Desktop\Microsoft Edge.lnk', '%USERPROFILE%\Desktop\Microsoft Edge.lnk') }
        }
        DefaultWallpaper            = @{
            Label = 'Plain Windows wallpaper'; Recommended = $false
            Description = 'Use the standard Windows picture instead of Windows Spotlight.'
            Apply = { Set-Wallpaper "$env:windir\Web\Wallpaper\Windows\img0.jpg" }
        }
        # Power: plugged-in (AC) settings, applied to every power plan.
        NeverSleepPluggedIn         = @{
            Label = 'Never sleep when plugged in'; Recommended = $false
            Description = 'The PC stays awake. Undo sets sleep back to 30 minutes.'
            Apply = { Set-PowerSetting 'Sleep after' SUB_SLEEP STANDBYIDLE 0 }
            Undo = { Set-PowerSetting 'Sleep after' SUB_SLEEP STANDBYIDLE 1800 }
        }
        DisplayAlwaysOnPluggedIn    = @{
            Label = 'Never turn off the display when plugged in'; Recommended = $false
            Description = 'The screen stays on. Undo sets it back to 10 minutes.'
            Apply = { Set-PowerSetting 'Turn off display after' SUB_VIDEO VIDEOIDLE 0 }
            Undo = { Set-PowerSetting 'Turn off display after' SUB_VIDEO VIDEOIDLE 600 }
        }
        PowerButtonShutsDown        = @{
            Label = 'Power and sleep buttons shut down'; Recommended = $false
            Description = 'Pressing the power (or sleep) button shuts the PC down instead of sleeping. Undo sets them back to sleep.'
            Apply = {
                Set-PowerSetting 'Power button' SUB_BUTTONS PBUTTONACTION 3 -Battery
                Set-PowerSetting 'Sleep button' SUB_BUTTONS SBUTTONACTION 3 -Battery
            }
            Undo = {
                Set-PowerSetting 'Power button' SUB_BUTTONS PBUTTONACTION 1 -Battery
                Set-PowerSetting 'Sleep button' SUB_BUTTONS SBUTTONACTION 1 -Battery
            }
        }
        BestPerformancePowerMode    = @{
            Label = 'Best performance power mode'; Recommended = $false
            Description = 'Settings > System > Power > Power mode: Best performance. Undo goes back to Balanced.'
            Apply = { Set-PowerMode 'Best performance' }
            Undo = { Set-PowerMode 'Balanced' }
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
        # The rest of WinUtil's default removal list.
        'Microsoft.WindowsCalculator'            = 'Calculator'
        'Microsoft.WindowsAlarms'                = 'Clock (Alarms)'
        'Microsoft.WindowsSoundRecorder'         = 'Sound Recorder'
        'Microsoft.MicrosoftStickyNotes'         = 'Sticky Notes'
        'Microsoft.Windows.DevHome'              = 'Dev Home'
        'Microsoft.StartExperiencesApp'          = 'Start experiences (Start menu ads)'
        'Microsoft.Copilot'                      = 'Copilot'
        'Microsoft.BingSearch'                   = 'Bing Search'
        'Microsoft.OutlookForWindows'            = 'Outlook (new)'
        'Microsoft.XboxGamingOverlay'            = 'Xbox Game Bar'
        'Microsoft.GamingApp'                    = 'Xbox app'
        'Microsoft.WindowsMaps'                  = 'Maps'
        'Microsoft.MicrosoftJournal'             = 'Journal'
        'MSTeams'                                = 'Teams (personal)'
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
        if ($DryRun) { Write-Log '  [would] Install WinGet first' 'Yellow'; return $true }
        # Still missing (old or broken App Installer): install it with Microsoft's module.
        Write-Log '  winget is missing, installing it (takes a minute) ...'
        Repair-Winget
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
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
    # Or, instead of a download, a local installer:
    #   path   - an installer file, or a folder holding one (an .msi is preferred over an .exe).
    #            Relative paths are looked up in the preset's installerRoot, else next to the preset.
    #            Wildcards are fine (SoMove*.exe); *:\ searches every drive (see Resolve-SourcePath).
    function Install-DirectApp($App, [string]$BaseDir, [string]$Root) {
        $name = $App.name
        $type = $App.type
        $target = if ($App.target) { Expand-PathVars $App.target } else { "C:\Tools\$name" }

        if ($App.detect -and (Test-AppInstalled $App.detect)) { Write-Skip "$name (already installed)"; return }
        if (Test-PrivatePending $App.url "Install $name") { return }
        if ($type -in 'zip', 'portable' -and -not $App.detect -and (Test-Path $target)) { Write-Skip "$name (already in $target)"; return }

        $localFile = $null
        if ($App.path) {
            $base = $BaseDir
            if ($Root) {
                $rootDir = Resolve-SourcePath $Root $BaseDir
                if ($rootDir) { $base = $rootDir }
            }
            $found = Resolve-SourcePath $App.path $base
            if ($found -and (Test-Path $found -PathType Container)) {
                $files = @(Get-ChildItem -Path $found -File -Include *.msi, *.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue)
                $found = ($files | Sort-Object @{ e = { $_.Extension -ne '.msi' } }, @{ e = { $_.Name -notmatch 'setup|install' } }, Name |
                        Select-Object -First 1).FullName
                if ($files.Count -gt 1) { Write-Log "    $name : $($files.Count) installers in the folder, using $(Split-Path -Leaf $found)" 'Yellow' }
            }
            if (-not $found) {
                Write-Log "  [fail] $name : installer not found at $($App.path)$(if ($Root) { " (installerRoot $Root)" })" 'Red'
                $script:Stats.Failed++; return
            }
            $localFile = $found
            if (-not $type) { $type = switch -Regex ($found) { '\.msi$' { 'msi' } '\.zip$' { 'zip' } default { 'exe' } } }
        }

        if ($type -ne 'msi' -and $type -notin 'zip', 'portable' -and -not $App.args) {
            Write-Log "    $name has no silent switches, so its installer window may open." 'Yellow'
        }

        $how = if ($localFile) { "from $localFile" } else { '(direct download)' }
        if (-not $localFile) { Write-Log "  Downloading $name ..." }
        Invoke-Step "Install $name $how" {
            if ($localFile) {
                $path = $localFile
                $file = Split-Path -Leaf $path
            }
            else {
                $url = Resolve-DownloadUrl $App
                $file = if (Test-ReleaseSource $url) { $url -replace '^\w+:' } else { [IO.Path]::GetFileName(([Uri]$url).AbsolutePath) }
            }
            if (-not $type) {
                $type = switch -Regex ($file) { '\.msi$' { 'msi' } '\.zip$' { 'zip' } default { 'exe' } }
            }
            if (-not $localFile) {
                if (-not $file) { $file = "$name.$type" }
                $dir = Join-Path $env:TEMP 'winsetup-downloads'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $path = Join-Path $dir $file
                Save-RemoteFile $url $path
            }
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

    function Install-WingetApp([string]$Id, [switch]$Upgrade) {
        winget list --id $Id --exact --accept-source-agreements --disable-interactivity *> $null
        if ($LASTEXITCODE -eq 0) {
            if (-not $Upgrade) { Write-Skip "$Id (already installed)"; return }
            Write-Log "  Upgrading $Id ..."
            Invoke-Step "Upgrade $Id" {
                $out = winget upgrade --id $Id --exact @script:WingetArgs 2>&1
                # -1978335189 = no newer version; -1978335212 = no upgrade available
                if ($LASTEXITCODE -in -1978335189, -1978335212) { Write-Log "    $Id is already the latest version" 'DarkGray'; return }
                if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE. $(($out | Select-Object -Last 1))" }
            }
            return
        }
        Write-Log "  Installing $Id ..."
        Invoke-Step "Install $Id" {
            $out = winget install --id $Id --exact @script:WingetArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE. $(($out | Select-Object -Last 1))" }
        }
    }

    # $Apps: winget IDs, catalog Ids ("direct:..."), "choco:<package>", or direct-download objects.
    # $Manager 'choco' installs catalog apps with Chocolatey (falls back to winget when an
    # app has no Chocolatey package). -Upgrade also upgrades apps that are already installed.
    function Install-Apps($Apps, [string]$BaseDir, [string]$Root, [string]$Manager = 'winget', [switch]$Upgrade) {
        $Apps = @($Apps | Where-Object { $_ })
        if (-not $Apps) { return }
        Write-Section $(if ($Upgrade) { 'Install or upgrade apps' } else { 'Install apps' })
        $wingetReady = $null
        $chocoReady = $null
        foreach ($a in $Apps) {
            $app = if ($a -is [string]) { $AppIndex[$a] } else { $a }
            if ($app -and ($app.url -or $app.github -or $app.page -or $app.path)) { Install-DirectApp $app $BaseDir $Root; continue }

            $id = if ($a -is [string]) { $a } else { $a.id }
            $choco = if ($id -like 'choco:*') { $id.Substring(6) } elseif ($Manager -eq 'choco') { Get-ChocoId $id } else { $null }
            if ($choco) {
                if ($null -eq $chocoReady) { $chocoReady = Initialize-Choco }
                if ($chocoReady) { Install-ChocoApp $choco -Upgrade:$Upgrade; continue }
                if ($id -like 'choco:*') { Write-Log "  [fail] $id (Chocolatey not available)" 'Red'; $script:Stats.Failed++; continue }
            }
            if ($null -eq $wingetReady) { $wingetReady = Initialize-Winget }
            if (-not $wingetReady) { Write-Log "  [fail] $id (winget not available)" 'Red'; $script:Stats.Failed++; continue }
            Install-WingetApp $id -Upgrade:$Upgrade
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
            if (-not [IO.Path]::IsPathRooted($src) -and $BaseDir) {
                $found = Resolve-SourcePath $src $BaseDir
                $src = if ($found) { $found } else { Join-Path $BaseDir $src }
            }
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
            # Tweaks that aren't plain registry values (power, wallpaper...) use script blocks.
            $block = if ($apply) { $tweak.Apply } else { $tweak.Undo }
            if ($block) { & $block }
            elseif (-not $entries) { Write-Skip "$($tweak.Label) (nothing to undo)" }
            if ($script:Stats.Changed -gt $before -and $entries) { $script:RestartExplorer = $true }
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

    # ---- Power ----

    # Current value of a power setting in one plan (AC or DC), or $null if it can't be read.
    function Get-PowerIndex([string]$Scheme, [string]$Sub, [string]$Setting, [switch]$Battery) {
        $out = powercfg /query $Scheme $Sub $Setting 2>$null
        $label = if ($Battery) { 'Current DC Power Setting Index' } else { 'Current AC Power Setting Index' }
        $line = $out | Where-Object { $_ -match $label } | Select-Object -First 1
        if ($line -match '0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($Matches[1], 16) }
        return $null
    }

    # Sets a plugged-in power setting (and on battery with -Battery) in every power plan.
    # $Sub / $Setting are powercfg aliases, e.g. SUB_SLEEP STANDBYIDLE (seconds).
    function Set-PowerSetting([string]$Label, [string]$Sub, [string]$Setting, [int]$Value, [switch]$Battery) {
        $schemes = @(powercfg /list | ForEach-Object { if ($_ -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } })
        $modes = @('AC') + @(if ($Battery) { 'DC' })
        foreach ($s in $schemes) {
            foreach ($m in $modes) {
                $current = Get-PowerIndex $s $Sub $Setting -Battery:($m -eq 'DC')
                if ($current -eq $Value) { Write-Skip "$Label ($m, plan $s) = $Value"; continue }
                Invoke-Step "Set $Label ($m, plan $s) = $Value" {
                    $verb = if ($m -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
                    powercfg $verb $s $Sub $Setting $Value
                    if ($LASTEXITCODE -ne 0) { throw "powercfg exit code $LASTEXITCODE" }
                }
            }
        }
        if (-not $DryRun) { powercfg /setactive SCHEME_CURRENT | Out-Null }
    }

    # The Power mode slider in Settings (a power overlay on top of the plan).
    function Set-PowerMode([string]$Mode) {
        $overlays = @{
            'Best performance' = 'ded574b5-45a0-4f42-8737-46345c09c238'
            'Balanced'         = '00000000-0000-0000-0000-000000000000'
            'Best efficiency'  = '961cc777-2547-4f9d-8174-7d86181b8a7a'
        }
        $guid = $overlays[$Mode]
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
        $current = (Get-ItemProperty -Path $key -Name ActiveOverlayAcPowerScheme -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
        if (-not $current) { $current = $overlays['Balanced'] }
        if ($current -eq $guid) { Write-Skip "Power mode = $Mode"; return }
        Invoke-Step "Set power mode to $Mode" {
            powercfg /overlaysetactive $guid
            if ($LASTEXITCODE -ne 0) { throw "powercfg exit code $LASTEXITCODE" }
        }
    }

    # ---- Desktop: wallpaper, shortcuts, Start layout ----

    # Finds a local file or folder. $Path can use %VARS%, be relative to the preset
    # file ($BaseDir), or start with *:\ to look on every drive (handy for USB sticks
    # whose drive letter changes). Wildcards in the file name are allowed.
    function Resolve-SourcePath([string]$Path, [string]$BaseDir) {
        if (-not $Path) { return $null }
        $p = Expand-PathVars $Path
        # A preset loaded from the web: relative files are downloaded from next to it.
        if ($BaseDir -match '^https?://' -and $p -notmatch '^\*:\\' -and -not [IO.Path]::IsPathRooted($p) -and $p -notmatch '^https?://') {
            $rel = $p -replace '\\', '/'
            $local = Join-Path (Join-Path $env:TEMP 'winsetup-files') ($rel -replace '/', '\')
            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $local) -Force | Out-Null
                Invoke-WebRequest -Uri "$($BaseDir.TrimEnd('/'))/$(($rel -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')" -OutFile $local -UseBasicParsing
                return $local
            }
            catch { Write-Log "    Could not download $rel next to the preset: $($_.Exception.Message)" 'Yellow'; return $null }
        }
        $candidates = @()
        if ($p -match '^\*:\\(.*)$') {
            $rest = $Matches[1]
            $candidates = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { Join-Path $_.Root $rest })
        }
        elseif (-not [IO.Path]::IsPathRooted($p) -and $BaseDir) { $candidates = @(Join-Path $BaseDir $p) }
        else { $candidates = @($p) }
        foreach ($c in $candidates) {
            $hit = Get-Item -Path $c -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
        return $null
    }

    function Set-Wallpaper([string]$Source, [string]$BaseDir) {
        if (-not $Source) { return }
        if ($Source -match '^https?://') {
            $dir = Join-Path $env:PUBLIC 'Pictures\Wallpaper'
            $path = Join-Path $dir ([IO.Path]::GetFileName(([Uri]$Source).AbsolutePath))
            if (-not (Test-Path $path)) {
                Invoke-Step "Download wallpaper $Source" {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Invoke-WebRequest -Uri $Source -OutFile $path -UseBasicParsing
                }
            }
        }
        else {
            $path = Resolve-SourcePath $Source $BaseDir
            if (-not $path) { Write-Log "  [fail] Wallpaper not found: $Source" 'Red'; $script:Stats.Failed++; return }
            # Copy pictures from a USB stick or share so the wallpaper survives it being removed.
            if ($path -notlike "$env:windir*" -and $path -notlike "$env:SystemDrive\Users\*") {
                $dir = Join-Path $env:PUBLIC 'Pictures\Wallpaper'
                $local = Join-Path $dir (Split-Path -Leaf $path)
                if (-not (Test-Path $local)) {
                    $from = $path
                    Invoke-Step "Copy wallpaper to $local" {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                        Copy-Item -Path $from -Destination $local -Force
                    }
                }
                $path = $local
            }
        }
        $current = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper
        if ($current -eq $path) { Write-Skip "Wallpaper = $path"; return }
        Invoke-Step "Set wallpaper to $path" {
            if (-not ('WinSetup.Wallpaper' -as [type])) {
                Add-Type -Namespace WinSetup -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
            }
            # BackgroundType 0 = picture (turns off Windows Spotlight and slideshow).
            $wp = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
            if (-not (Test-Path $wp)) { New-Item -Path $wp -Force | Out-Null }
            New-ItemProperty -Path $wp -Name BackgroundType -PropertyType DWord -Value 0 -Force | Out-Null
            # 20 = SPI_SETDESKWALLPAPER; 3 = save to the profile and tell running apps.
            if (-not [WinSetup.Wallpaper]::SystemParametersInfo(20, 0, $path, 3)) { throw 'Windows refused the picture' }
        }
    }

    # $Shortcuts: objects with name, target, and optionally args, icon, folder
    # (Desktop = your desktop [default], PublicDesktop = everyone's, StartMenu, or any path).
    function New-Shortcuts($Shortcuts) {
        $Shortcuts = @($Shortcuts | Where-Object { $_ })
        if (-not $Shortcuts) { return }
        Write-Section 'Shortcuts'
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($s in $Shortcuts) {
            $folder = switch ($s.folder) {
                { -not $_ -or $_ -eq 'Desktop' } { [Environment]::GetFolderPath('Desktop'); break }
                'PublicDesktop' { Join-Path $env:PUBLIC 'Desktop'; break }
                'StartMenu' { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'; break }
                default { Expand-PathVars $_ }
            }
            $lnk = Join-Path $folder "$($s.name).lnk"
            $target = Expand-PathVars $s.target
            if (Test-Path $lnk) {
                if ($wsh.CreateShortcut($lnk).TargetPath -eq $target) { Write-Skip "$lnk (exists)"; continue }
            }
            $item = $s
            Invoke-Step "Shortcut $lnk -> $target" {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                $sc = $wsh.CreateShortcut($lnk)
                $sc.TargetPath = $target
                if ($item.args) { $sc.Arguments = $item.args }
                if ($item.icon) { $sc.IconLocation = Expand-PathVars $item.icon }
                if (Test-Path $target -PathType Leaf) { $sc.WorkingDirectory = Split-Path -Parent $target }
                $sc.Save()
            }
        }
    }

    function Remove-Shortcuts([string[]]$Paths) {
        foreach ($p in @($Paths | Where-Object { $_ })) {
            $path = Expand-PathVars $p
            if (-not (Test-Path $path)) { Write-Skip "$path (already gone)"; continue }
            Invoke-Step "Remove $path" { Remove-Item -Path $path -Force }
        }
    }

    # Copies whole folders (manuals, drive files...) with robocopy. Newer files win,
    # nothing is deleted at the destination.
    function Copy-Folders($Items, [string]$BaseDir) {
        $Items = @($Items | Where-Object { $_ })
        if (-not $Items) { return }
        Write-Section 'Copy folders'
        foreach ($i in $Items) {
            $src = Resolve-SourcePath $i.source $BaseDir
            $dst = Expand-PathVars $i.destination
            if (-not $src) { Write-Log "  [fail] Source folder not found: $($i.source)" 'Red'; $script:Stats.Failed++; continue }
            Invoke-Step "Copy $src -> $dst" {
                robocopy $src $dst /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                # Robocopy exit codes below 8 mean success.
                if ($LASTEXITCODE -ge 8) { throw "robocopy exit code $LASTEXITCODE" }
            }
        }
    }

    # Windows 11 keeps the Start menu pins in start2.bin (copy it from a set-up PC:
    # %LOCALAPPDATA%\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState).
    function Set-StartLayout([string]$Source, [string]$BaseDir) {
        if (-not $Source) { return }
        Write-Section 'Start menu pins'
        $src = Resolve-SourcePath $Source $BaseDir
        if (-not $src) { Write-Log "  [fail] Start layout not found: $Source" 'Red'; $script:Stats.Failed++; return }
        $dst = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
        if ((Test-Path $dst) -and (Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash) { Write-Skip 'Start pins (up to date)'; return }
        Invoke-Step "Copy Start pins from $src" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Copy-Item -Path $src -Destination $dst -Force
            Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
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

    # ---- WinUtil (Chris Titus Tech) catalog ----
    # The Install, Tweaks, Config and Updates tabs are built from WinUtil's own config
    # files (github.com/ChrisTitusTech/winutil, MIT licence, (c) 2022 CT Tech Group LLC).
    # $WinUtil holds them: Apps, Tweaks, Features, Presets, Dns (or $null when offline).
    # The functions below apply its entries the way WinUtil does, through Invoke-Step,
    # so dry runs, logging and the summary work the same as for everything else.

    # WinUtil's scripts call a few of its own helpers. These stand in for them.
    function Invoke-WinUtilExplorerUpdate([string]$action = 'refresh') {
        if ($DryRun) { return }
        if ($action -eq 'restart') {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            return
        }
        if (-not ('WinSetup.Broadcast' -as [type])) {
            Add-Type -Namespace WinSetup -Name Broadcast -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@
        }
        $r = [IntPtr]::Zero
        [void][WinSetup.Broadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 100, [ref]$r)
    }
    function Invoke-WinutilThemeChange { param($theme) }
    function Write-WinUtilLog { param($Level, $Component, $Message) }
    function Step-WinUtilJob { param($Status, $Percent, $State) }

    function Get-WinUtilEntry([string]$Kind, [string]$Key) {
        if (-not $WinUtil -or -not $WinUtil.$Kind) { return $null }
        $WinUtil.$Kind.$Key
    }

    # Runs one of WinUtil's InvokeScript / UndoScript snippets and copies its output to the log.
    function Invoke-WinUtilScript([string]$Name, [string]$Code) {
        if (-not $Code.Trim()) { return }
        Invoke-Step "Run script: $Name" {
            $ErrorActionPreference = 'Continue'
            $sb = [scriptblock]::Create($Code)
            & $sb *>&1 | ForEach-Object {
                $line = "$_".Trim()
                if ($line) { Write-Log "      $line" 'DarkGray' }
            }
        }
    }

    # WinUtil registry entry -> Set-RegistryEntry. "<RemoveEntry>" removes the value.
    function Set-WinUtilRegistry($Entry, $Value) {
        if ($Entry.Path -like 'HKU:*' -and -not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
        }
        $type = if ($Entry.Type) { $Entry.Type } else { 'DWord' }
        if ($Value -eq '<RemoveEntry>') { Set-RegistryEntry -Path $Entry.Path -Name $Entry.Name -Value $null; return }
        Set-RegistryEntry -Path $Entry.Path -Name $Entry.Name -Type $type -Value $Value
    }

    # Like WinUtil: a service is only changed when it is still at the startup type the
    # tweak expects, so services someone set on purpose are left alone.
    function Set-WinUtilService($Item, [bool]$Undo) {
        $want = if ($Undo) { $Item.OriginalType } else { $Item.StartupType }
        $expect = if ($Undo) { $Item.StartupType } else { $Item.OriginalType }
        $svc = Get-Service -Name $Item.Name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Skip "Service $($Item.Name) (not on this PC)"; return }
        $now = [string]$svc.StartType
        if ($now -eq $want) { Write-Skip "Service $($Item.Name) = $want"; return }
        if ($expect -and $now -ne $expect) { Write-Skip "Service $($Item.Name) left at $now (changed by someone else)"; return }
        Invoke-Step "Service $($Item.Name): $now -> $want" {
            if ($want -eq 'AutomaticDelayedStart') {
                sc.exe config $Item.Name start= delayed-auto | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "sc.exe exit code $LASTEXITCODE" }
            }
            else { Set-Service -Name $Item.Name -StartupType $want }
        }
    }

    # Applies (or undoes) one WinUtil tweak or toggle by its key, e.g. WPFTweaksTelemetry.
    function Invoke-WinUtilTweak([string]$Key, [bool]$Undo = $false) {
        $t = Get-WinUtilEntry 'Tweaks' $Key
        if (-not $t) { Write-Log "  [fail] Unknown WinUtil tweak '$Key'" 'Red'; $script:Stats.Failed++; return }
        Write-Log "  $($t.Content)$(if ($Undo) { ' (undo)' })"
        if ($Key -eq 'WPFTweaksRestorePoint' -and -not $Undo) { New-RestorePoint; return }
        foreach ($s in @($t.service | Where-Object { $_ })) { Set-WinUtilService $s $Undo }
        foreach ($r in @($t.registry | Where-Object { $_ })) {
            if ($r.Values) { continue }   # combo boxes, see Set-WinUtilChoice
            $v = if ($Undo) { $r.OriginalValue } else { $r.Value }
            if ($null -eq $v) { continue }
            Set-WinUtilRegistry $r $v
        }
        $scripts = if ($Undo) { $t.UndoScript } else { $t.InvokeScript }
        foreach ($code in @($scripts | Where-Object { $_ })) { Invoke-WinUtilScript $t.Content $code }
        if (-not $Undo -and $t.appx) { Remove-BuiltInApps @($t.appx) }
    }

    function Invoke-WinUtilTweaks([string[]]$Keys, [bool]$Undo = $false) {
        $Keys = @($Keys | Where-Object { $_ })
        if (-not $Keys) { return }
        Write-Section $(if ($Undo) { 'Undo WinUtil tweaks' } else { 'WinUtil tweaks' })
        # The restore point goes first, like in WinUtil.
        $Keys = @($Keys | Sort-Object { $_ -ne 'WPFTweaksRestorePoint' })
        foreach ($k in $Keys) { Invoke-WinUtilTweak $k $Undo }
    }

    # True when every registry value of a WinUtil toggle is in its "on" state.
    function Get-WinUtilToggleState([string]$Key) {
        $t = Get-WinUtilEntry 'Tweaks' $Key
        if (-not $t -or -not $t.registry) { return $false }
        foreach ($r in $t.registry) {
            $path = $r.Path
            if ($path -like 'HKU:*') { $path = $path -replace '^HKU:', 'Registry::HKEY_USERS' }
            $cur = $null
            if (Test-Path $path) { $cur = (Get-ItemProperty -Path $path -Name $r.Name -ErrorAction SilentlyContinue).($r.Name) }
            if ($null -eq $cur) {
                if ([string]$r.DefaultState -eq 'true') { $cur = $r.Value }
                elseif ([string]$r.DefaultState -eq 'false') { $cur = $r.OriginalValue }
            }
            if ("$cur" -ne "$($r.Value)") { return $false }
        }
        $true
    }

    # $Toggles: hashtable or object of ToggleKey -> $true (on) / $false (off)
    function Set-WinUtilToggles($Toggles) {
        if (-not $Toggles) { return }
        $pairs = if ($Toggles -is [System.Collections.IDictionary]) { @($Toggles.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = $_.Value } }) }
        else { @($Toggles.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
        if (-not $pairs) { return }
        Write-Section 'Preferences'
        foreach ($p in $pairs) {
            $on = [bool]$p.Value
            if ((Get-WinUtilToggleState $p.Name) -eq $on) {
                $t = Get-WinUtilEntry 'Tweaks' $p.Name
                Write-Skip "$(if ($t) { $t.Content } else { $p.Name }) already $(if ($on) { 'on' } else { 'off' })"
                continue
            }
            Invoke-WinUtilTweak $p.Name (-not $on)
        }
    }

    # Combo-box tweaks such as Multiplane Overlay: each registry entry has a value per choice.
    function Set-WinUtilChoice([string]$Key, [string]$Choice) {
        $t = Get-WinUtilEntry 'Tweaks' $Key
        if (-not $t -or -not $Choice) { return }
        Write-Section "$($t.Content) $Choice"
        foreach ($r in @($t.registry | Where-Object { $_.Values })) {
            $v = $r.Values.$Choice
            if ($null -eq $v) { continue }
            Set-WinUtilRegistry $r $v
        }
    }

    # Turns on a WinUtil feature (Windows features plus its follow-up script).
    function Invoke-WinUtilFeatures([string[]]$Keys) {
        $Keys = @($Keys | Where-Object { $_ })
        if (-not $Keys) { return }
        Write-Section 'WinUtil features'
        foreach ($k in $Keys) {
            $f = Get-WinUtilEntry 'Features' $k
            if (-not $f) { Write-Log "  [fail] Unknown WinUtil feature '$k'" 'Red'; $script:Stats.Failed++; continue }
            Write-Log "  $($f.Content)"
            $failedBefore = $script:Stats.Failed
            Set-Features @($f.feature | Where-Object { $_ }) @()
            # Like WinUtil: skip the follow-up script when a feature could not be turned on.
            if ($script:Stats.Failed -gt $failedBefore) { continue }
            foreach ($code in @($f.InvokeScript | Where-Object { $_ })) { Invoke-WinUtilScript $f.Content $code }
        }
    }

    # ---- DNS ----

    function Set-DnsProvider([string]$Provider) {
        if (-not $Provider -or $Provider -eq 'Default') { return }
        Write-Section "DNS: $Provider"
        $dnsList = if ($WinUtil) { $WinUtil.Dns } else { $null }
        if ($Provider -eq 'Fastest') {
            $best = $null; $bestMs = [double]::MaxValue
            foreach ($p in @($dnsList.PSObject.Properties | Where-Object { $_.Value.BenchmarkEligible })) {
                try {
                    $ms = (Measure-Command { Resolve-DnsName -Name 'microsoft.com' -Server $p.Value.Primary -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }).TotalMilliseconds
                    Write-Log "    $($p.Name): $([int]$ms) ms"
                    if ($ms -lt $bestMs) { $bestMs = $ms; $best = $p.Name }
                }
                catch { Write-Log "    $($p.Name): no answer" 'DarkGray' }
            }
            if (-not $best) { Write-Log '  [fail] No DNS provider answered, DNS left as it is' 'Red'; $script:Stats.Failed++; return }
            Write-Log "  Fastest: $best"
            $Provider = $best
        }
        $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
        if (-not $adapters) { Write-Log '  [fail] No connected network adapters' 'Red'; $script:Stats.Failed++; return }
        if ($Provider -eq 'DHCP') {
            foreach ($a in $adapters) {
                Invoke-Step "DNS on $($a.Name): automatic (DHCP)" { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses }
            }
            return
        }
        $d = $dnsList.$Provider
        if (-not $d) { Write-Log "  [fail] Unknown DNS provider '$Provider'" 'Red'; $script:Stats.Failed++; return }
        $servers = @($d.Primary, $d.Secondary, $d.Primary6, $d.Secondary6 | Where-Object { $_ })
        foreach ($a in $adapters) {
            $current = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
            if (-not (Compare-Object $current $servers)) { Write-Skip "DNS on $($a.Name) = $Provider"; continue }
            Invoke-Step "DNS on $($a.Name): $($servers -join ', ')" { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers }
        }
        # Encrypted DNS (DoH) where Windows supports it. Optional: plain DNS still works without it.
        if ($d.DohTemplate -and (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) -and -not $DryRun) {
            foreach ($ip in $servers) {
                try {
                    if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                        Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $d.DohTemplate -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null
                    }
                    else { Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $d.DohTemplate -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null }
                }
                catch { Write-Log "    DoH for $ip not set: $($_.Exception.Message)" 'DarkGray' }
            }
        }
    }

    # ---- Windows Update (WinUtil's Updates tab) ----

    $script:UpdateTasks = '\Microsoft\Windows\InstallService\', '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\UpdateAssistant\',
    '\Microsoft\Windows\WaaSMedic\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\WindowsUpdate\'
    $script:WU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

    function Set-UpdateServices([bool]$On) {
        $want = if ($On) { @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic' } } else { @{ BITS = 'Disabled'; wuauserv = 'Disabled'; UsoSvc = 'Disabled' } }
        foreach ($n in $want.Keys) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            if ([string]$svc.StartType -eq $want[$n]) { Write-Skip "Service $n = $($want[$n])"; continue }
            Invoke-Step "Service $n -> $($want[$n])" {
                if (-not $On) { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
                Set-Service -Name $n -StartupType $want[$n]
            }
        }
        Invoke-Step "$(if ($On) { 'Enable' } else { 'Disable' }) Windows Update scheduled tasks" {
            foreach ($p in $script:UpdateTasks) {
                $tasks = Get-ScheduledTask -TaskPath "$p*" -ErrorAction SilentlyContinue
                if ($On) { $tasks | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
                else { $tasks | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
            }
        }
    }

    # default  = Windows' own settings (removes WinUtil / this tool's update policies)
    # security = WinUtil's recommended: no drivers from Windows Update, feature updates
    #            365 days late, quality (security) updates 4 days late, ask before installing
    # disable  = no Windows Update at all (not recommended)
    function Set-UpdatePolicy([string]$Mode) {
        if (-not $Mode) { return }
        Write-Section "Windows Update: $Mode"
        $au = "$script:WU\AU"
        $dm = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'
        $ds = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
        $do = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
        switch ($Mode) {
            'default' {
                foreach ($n in 'NoAutoUpdate', 'AUOptions', 'NoAutoRebootWithLoggedOnUsers', 'AUPowerManagement') { Set-RegistryEntry -Path $au -Name $n -Value $null }
                foreach ($n in 'ExcludeWUDriversInQualityUpdate', 'DeferFeatureUpdates', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdates', 'DeferQualityUpdatesPeriodInDays') { Set-RegistryEntry -Path $script:WU -Name $n -Value $null }
                Set-RegistryEntry -Path $dm -Name PreventDeviceMetadataFromNetwork -Value $null
                foreach ($n in 'DontPromptForWindowsUpdate', 'DontSearchWindowsUpdate', 'DriverUpdateWizardWuSearchEnabled') { Set-RegistryEntry -Path $ds -Name $n -Value $null }
                Set-RegistryEntry -Path $do -Name DODownloadMode -Value $null
                Set-UpdateServices $true
                $script:RestartNeeded = $true
            }
            'security' {
                Set-RegistryEntry -Path $au -Name NoAutoUpdate -Value $null
                Set-RegistryEntry -Path $do -Name DODownloadMode -Value $null
                Set-UpdateServices $true
                Set-RegistryEntry -Path $dm -Name PreventDeviceMetadataFromNetwork -Value 1
                Set-RegistryEntry -Path $ds -Name DontPromptForWindowsUpdate -Value 1
                Set-RegistryEntry -Path $ds -Name DontSearchWindowsUpdate -Value 1
                Set-RegistryEntry -Path $ds -Name DriverUpdateWizardWuSearchEnabled -Value 0
                Set-RegistryEntry -Path $script:WU -Name ExcludeWUDriversInQualityUpdate -Value 1
                Set-RegistryEntry -Path $script:WU -Name DeferFeatureUpdates -Value 1
                Set-RegistryEntry -Path $script:WU -Name DeferFeatureUpdatesPeriodInDays -Value 365
                Set-RegistryEntry -Path $script:WU -Name DeferQualityUpdates -Value 1
                Set-RegistryEntry -Path $script:WU -Name DeferQualityUpdatesPeriodInDays -Value 4
                Set-RegistryEntry -Path $au -Name NoAutoRebootWithLoggedOnUsers -Value $null
                Set-RegistryEntry -Path $au -Name AUOptions -Value 3
                Set-RegistryEntry -Path $au -Name AUPowerManagement -Value 0
            }
            'disable' {
                Set-RegistryEntry -Path $au -Name NoAutoUpdate -Value 1
                Set-RegistryEntry -Path $au -Name AUOptions -Value 1
                Set-RegistryEntry -Path $do -Name DODownloadMode -Value 0
                Set-UpdateServices $false
                Invoke-Step 'Clear downloaded updates' { Remove-Item -Path "$env:windir\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue }
                $script:RestartNeeded = $true
            }
            default { Write-Log "  [fail] Unknown update mode '$Mode' (use default, security or disable)" 'Red'; $script:Stats.Failed++ }
        }
    }

    function Start-UpdateScan {
        Write-Section 'Check for Windows updates'
        Invoke-Step 'Ask Windows Update to look for updates now' {
            try { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() } catch { }
            UsoClient.exe StartInteractiveScan 2>$null
            Start-Process 'ms-settings:windowsupdate'
        }
    }

    # ---- Fixes, power plans and other one-click actions ----

    function Repair-WindowsUpdate {
        Write-Section 'Reset Windows Update'
        Invoke-Step 'Stop update services' { foreach ($s in 'BITS', 'wuauserv', 'appidsvc', 'cryptsvc') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } }
        Invoke-Step 'Clear the update download cache' {
            Remove-Item "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue
            $dl = "$env:windir\SoftwareDistribution\Download"
            if (Test-Path "$dl.bak") { Remove-Item "$dl.bak" -Recurse -Force -ErrorAction SilentlyContinue }
            Rename-Item $dl 'Download.bak' -ErrorAction SilentlyContinue
            Remove-Item "$env:windir\WindowsUpdate.log" -ErrorAction SilentlyContinue
        }
        Invoke-Step 'Re-register Windows Update components' {
            foreach ($dll in 'atl.dll', 'urlmon.dll', 'mshtml.dll', 'jscript.dll', 'vbscript.dll', 'scrrun.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll',
                'softpub.dll', 'wintrust.dll', 'dssenh.dll', 'rsaenh.dll', 'cryptdlg.dll', 'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'wuapi.dll',
                'wuaueng.dll', 'wups.dll', 'wups2.dll', 'qmgr.dll', 'qmgrprxy.dll') {
                Start-Process -FilePath regsvr32.exe -ArgumentList '/s', $dll -Wait -WindowStyle Hidden
            }
        }
        # WinUtil also wipes every Group Policy setting here. This tool keeps them, so
        # settings applied on purpose (by a preset or by IT) survive the reset.
        Invoke-Step 'Reset WinSock and WinHTTP proxy' { netsh winsock reset | Out-Null; netsh winhttp reset proxy | Out-Null }
        Invoke-Step 'Clear queued downloads' { Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue }
        Invoke-Step 'Start update services' {
            foreach ($s in 'BITS', 'wuauserv', 'CryptSvc') { Set-Service -Name $s -StartupType Manual; Start-Service -Name $s -ErrorAction SilentlyContinue }
            Start-Service AppIDSvc -ErrorAction SilentlyContinue
        }
        Invoke-Step 'Look for updates' { try { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() } catch { } }
        $script:RestartNeeded = $true
    }

    function Reset-Network {
        Write-Section 'Reset network'
        Invoke-Step 'Reset WinSock and TCP/IP' { netsh winsock reset | Out-Null; netsh int ip reset | Out-Null }
        $script:RestartNeeded = $true
    }

    function Repair-SystemFiles {
        Write-Section 'System corruption scan (takes a while)'
        $steps = @(
            @{ Label = 'Check the disk for errors (chkdsk /scan)'; Exe = 'chkdsk.exe'; Args = '/scan /perf'; Ok = 0, 1, 2 }
            @{ Label = 'Scan protected system files (sfc /scannow)'; Exe = 'sfc.exe'; Args = '/scannow'; Ok = 0, 1 }
            @{ Label = 'Repair the Windows image (DISM RestoreHealth)'; Exe = 'dism.exe'; Args = '/online /cleanup-image /restorehealth'; Ok = 0, 3010 }
        )
        foreach ($s in $steps) {
            $step = $s
            Invoke-Step $step.Label {
                $p = Start-Process -FilePath $step.Exe -ArgumentList $step.Args -Wait -PassThru -WindowStyle Hidden
                if ($p.ExitCode -notin $step.Ok) { throw "exit code $($p.ExitCode)" }
            }
        }
    }

    # Reinstalls winget with Microsoft's own module (what "WinGet - Reinstall" does in WinUtil).
    function Repair-Winget {
        Write-Section 'Reinstall WinGet'
        Invoke-Step 'Repair WinGet (Microsoft.WinGet.Client)' {
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -Force | Out-Null }
            Install-Module -Name Microsoft.WinGet.Client -Force -Scope AllUsers -AllowClobber -Repository PSGallery -ErrorAction Stop | Out-Null
            Import-Module Microsoft.WinGet.Client -Force
            Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop | Out-Null
        }
    }

    function Initialize-Choco {
        if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
        Write-Log '  Installing Chocolatey ...'
        Invoke-Step 'Install Chocolatey' {
            $installer = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing).Content
            & ([scriptblock]::Create($installer)) *>&1 | Out-Null
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
        if (-not $DryRun) { Write-Log '  Chocolatey is not available.' 'Red' }
        return [bool]$DryRun
    }

    function Set-NtpPool {
        Write-Section 'Time server: pool.ntp.org'
        Invoke-Step 'Use pool.ntp.org and sync the clock' {
            Start-Service w32time -ErrorAction SilentlyContinue
            w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL | Out-Null
            Restart-Service w32time
            w32tm /resync | Out-Null
        }
    }

    function Enable-SshServer {
        Write-Section 'OpenSSH Server'
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cap -and $cap.State -eq 'Installed') { Write-Skip 'OpenSSH Server (installed)' }
        else { Invoke-Step 'Install OpenSSH Server' { Add-WindowsCapability -Online -Name $(if ($cap) { $cap.Name } else { 'OpenSSH.Server~~~~0.0.1.0' }) | Out-Null } }
        Invoke-Step 'Start sshd and start it with Windows' {
            Set-Service -Name sshd -StartupType Automatic
            Start-Service sshd
            if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            }
        }
    }

    function Get-Pwsh7 {
        $c = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in "$env:ProgramFiles\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe") { if (Test-Path $p) { return $p } }
        $null
    }

    function Install-CttProfile {
        Write-Section 'Chris Titus Tech PowerShell profile'
        if (-not (Get-Pwsh7)) { Install-Apps @('Microsoft.PowerShell') }
        Invoke-Step 'Run the profile setup in PowerShell 7' {
            $pwsh = Get-Pwsh7
            if (-not $pwsh) { throw 'PowerShell 7 is not installed' }
            & $pwsh -NoProfile -NonInteractive -Command "irm 'https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1' | iex" *>&1 | ForEach-Object { Write-Log "      $_" 'DarkGray' }
        }
    }

    function Uninstall-CttProfile {
        Write-Section 'Remove the Chris Titus Tech PowerShell profile'
        $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell'
        $prof = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
        $old = Join-Path $dir 'oldprofile.ps1'
        if (-not (Test-Path $prof)) { Write-Skip 'No PowerShell 7 profile'; return }
        Invoke-Step 'Put the previous profile back' {
            if (Test-Path $old) { Move-Item $old $prof -Force } else { Move-Item $prof "$prof.bak" -Force }
        }
    }

    function Set-UltimatePerformance([bool]$On) {
        Write-Section "Ultimate Performance power plan: $(if ($On) { 'add' } else { 'remove' })"
        $plans = @(powercfg /list | Where-Object { $_ -match 'Ultimate Performance' })
        if ($On) {
            if ($plans) { Write-Skip 'Ultimate Performance plan already exists' }
            else { Invoke-Step 'Add the Ultimate Performance plan' { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null } }
            Invoke-Step 'Make it the active plan' {
                $line = powercfg /list | Where-Object { $_ -match 'Ultimate Performance' } | Select-Object -First 1
                if ($line -match '([0-9a-f-]{36})') { powercfg /setactive $Matches[1] } else { throw 'plan not found' }
            }
            return
        }
        if (-not $plans) { Write-Skip 'No Ultimate Performance plan'; return }
        Invoke-Step 'Switch back to Balanced and delete Ultimate Performance' {
            powercfg /setactive SCHEME_BALANCED
            foreach ($l in $plans) { if ($l -match '([0-9a-f-]{36})') { powercfg /delete $Matches[1] | Out-Null } }
        }
    }

    function Start-Autologon {
        Write-Section 'AutoLogon (Sysinternals)'
        Invoke-Step 'Download and open Autologon' {
            $p = Join-Path $env:TEMP 'Autologon.exe'
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/Autologon.exe' -OutFile $p -UseBasicParsing
            Start-Process -FilePath $p -ArgumentList '/accepteula'
        }
    }

    function Start-ShutUp10 {
        Write-Section 'O&O ShutUp10++'
        Invoke-Step 'Download and open O&O ShutUp10++' {
            $p = Join-Path $env:TEMP 'OOSU10.exe'
            Invoke-WebRequest -Uri 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -OutFile $p -UseBasicParsing
            Start-Process -FilePath $p
        }
    }

    # One-click actions by their WinUtil key, so presets can list them under winutil.actions.
    $script:WinUtilActions = @{
        WPFFixesUpdate               = { Repair-WindowsUpdate }
        WPFFixesNetwork              = { Reset-Network }
        WPFPanelDISM                 = { Repair-SystemFiles }
        WPFFixesWinget               = { Repair-Winget }
        WPFFixesNTPPool              = { Set-NtpPool }
        WPFPanelAutologin            = { Start-Autologon }
        WPFWinUtilSSHServer          = { Enable-SshServer }
        WPFWinUtilInstallPSProfile   = { Install-CttProfile }
        WPFWinUtilUninstallPSProfile = { Uninstall-CttProfile }
        WPFAddUltPerf                = { Set-UltimatePerformance $true }
        WPFRemoveUltPerf             = { Set-UltimatePerformance $false }
        WPFOOSUbutton                = { Start-ShutUp10 }
        UpdateScan                   = { Start-UpdateScan }
    }

    function Invoke-WinUtilActions([string[]]$Keys) {
        foreach ($k in @($Keys | Where-Object { $_ })) {
            if ($script:WinUtilActions.ContainsKey($k)) { & $script:WinUtilActions[$k]; continue }
            # Anything else with a script in feature.json (e.g. the legacy Control Panel pages).
            $f = Get-WinUtilEntry 'Features' $k
            if ($f -and $f.InvokeScript) { Write-Section $f.Content; foreach ($c in $f.InvokeScript) { Invoke-WinUtilScript $f.Content $c }; continue }
            Write-Log "  [fail] Unknown action '$k'" 'Red'; $script:Stats.Failed++
        }
    }

    # ---- Package managers: winget or Chocolatey ----

    # winget ID -> Chocolatey package, from the WinUtil catalog.
    function Get-ChocoId([string]$WingetId) {
        if (-not $WinUtil) { return $null }
        foreach ($p in $WinUtil.Apps.PSObject.Properties) {
            if ($p.Value.winget -eq $WingetId) { if ($p.Value.choco -and $p.Value.choco -ne 'na') { return $p.Value.choco } else { return $null } }
        }
        $null
    }

    function Install-ChocoApp([string]$Id, [switch]$Upgrade) {
        $installed = [bool](choco list --exact $Id --limit-output 2>$null | Where-Object { $_ -like "$Id|*" })
        if ($installed -and -not $Upgrade) { Write-Skip "$Id (already installed, choco)"; return }
        $verb = if ($installed) { 'upgrade' } else { 'install' }
        Write-Log "  choco $verb $Id ..."
        Invoke-Step "choco $verb $Id" {
            $out = choco $verb $Id -y --no-progress 2>&1
            if ($LASTEXITCODE -notin 0, 1641, 3010) { throw "choco exit code $LASTEXITCODE. $(($out | Select-Object -Last 1))" }
        }
    }

    # $Ids are winget IDs (the catalog's tags). Uninstalls with the chosen package manager.
    function Uninstall-Apps([string[]]$Ids, [string]$Manager = 'winget') {
        $Ids = @($Ids | Where-Object { $_ })
        if (-not $Ids) { return }
        Write-Section 'Uninstall apps'
        if ($Manager -eq 'choco' -and -not (Initialize-Choco)) { return }
        if ($Manager -ne 'choco' -and -not (Initialize-Winget)) { return }
        foreach ($id in $Ids) {
            if ($Manager -eq 'choco') {
                $c = Get-ChocoId $id
                if (-not $c) { Write-Log "  [fail] $id has no Chocolatey package" 'Red'; $script:Stats.Failed++; continue }
                Invoke-Step "choco uninstall $c" { choco uninstall $c -y --no-progress 2>&1 | Out-Null; if ($LASTEXITCODE -notin 0, 1605, 1614, 1641, 3010) { throw "choco exit code $LASTEXITCODE" } }
                continue
            }
            winget list --id $id --exact --accept-source-agreements --disable-interactivity *> $null
            if ($LASTEXITCODE -ne 0) { Write-Skip "$id (not installed)"; continue }
            Invoke-Step "Uninstall $id" {
                $out = winget uninstall --id $id --exact --silent --accept-source-agreements --disable-interactivity 2>&1
                if ($LASTEXITCODE -ne 0) { throw "winget exit code $LASTEXITCODE. $(($out | Select-Object -Last 1))" }
            }
        }
    }

    # Installed package IDs (winget IDs, or Chocolatey names), for "Show installed".
    function Get-InstalledPackageIds([string]$Manager = 'winget') {
        if ($Manager -eq 'choco') {
            if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { return @() }
            return @(choco list --limit-output 2>$null | ForEach-Object { ($_ -split '\|')[0] })
        }
        if (-not (Initialize-Winget)) { return @() }
        $tmp = Join-Path $env:TEMP 'winsetup-installed.json'
        winget export -o $tmp --source winget --accept-source-agreements --disable-interactivity *> $null
        if (-not (Test-Path $tmp)) { return @() }
        $j = Get-Content $tmp -Raw | ConvertFrom-Json
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        @($j.Sources | ForEach-Object { $_.Packages } | ForEach-Object { $_.PackageIdentifier })
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
        # WinUtil's "Restore Point - Create" tweak just means: make one first.
        $wuTweaks = @($Config.winutil.tweaks | Where-Object { $_ -and $_ -ne 'WPFTweaksRestorePoint' })
        $wantRestore = @($Config.winutil.tweaks) -contains 'WPFTweaksRestorePoint' -or
            ($Config.restorePoint -ne $false -and ($tweaks.Count -or $Config.registry -or $Config.removeApps -or $wuTweaks -or $Config.updates -or $Config.winutil.toggles))
        if ($wantRestore) { New-RestorePoint }
        # Features first: some apps (e.g. ones needing .NET 3.5 or IIS) won't install without them.
        Set-Features @($Config.features.enable) @($Config.features.disable)
        Invoke-WinUtilFeatures @($Config.winutil.features)
        $manager = if ($Config.packageManager) { [string]$Config.packageManager } else { 'winget' }
        Install-Apps @($Config.apps.install) $BaseDir $Config.installerRoot $manager
        if ($Config.apps.upgradeAll) { Update-AllApps }
        Remove-BuiltInApps @($Config.removeApps)
        foreach ($t in @($Config.folderTemplates | Where-Object { $_ })) { Invoke-FolderTemplate $t $BaseDir }
        New-Folders @($Config.folders)
        Copy-Folders $Config.copyFolders $BaseDir
        Add-QuickAccess @($Config.quickAccess)
        Copy-ConfigFiles $Config.files $BaseDir
        New-Shortcuts $Config.shortcuts
        if ($Config.removeShortcuts) { Write-Section 'Remove shortcuts'; Remove-Shortcuts @($Config.removeShortcuts) }
        if ($Config.wallpaper) { Write-Section 'Wallpaper'; Set-Wallpaper $Config.wallpaper $BaseDir }
        Set-StartLayout $Config.startLayout $BaseDir
        Set-Tweaks $tweaks
        Invoke-WinUtilTweaks $wuTweaks
        Set-WinUtilToggles $Config.winutil.toggles
        if ($Config.winutil.choices) { foreach ($c in $Config.winutil.choices.PSObject.Properties) { Set-WinUtilChoice $c.Name $c.Value } }
        Set-DnsProvider $Config.dns
        Set-UpdatePolicy $Config.updates
        Invoke-WinUtilActions @($Config.winutil.actions)
        Set-RegistryValues $Config.registry
    }
}

. $Engine

# --- WinUtil catalog -----------------------------------------------------------

# WinUtil keeps multi-line scripts as raw line breaks inside JSON strings, which
# Windows PowerShell's JSON reader rejects. Escape them first.
function ConvertFrom-LooseJson([string]$Text) {
    $fixed = [regex]::Replace($Text, '"(?:[^"\\]|\\.)*"', { param($m) $m.Value.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') })
    $fixed | ConvertFrom-Json
}

# Loads WinUtil's app list, tweaks, features, presets and DNS providers. Tries WinUtil
# itself first (always current), then the copy next to this script, then this repo's
# copy. Returns $null when none can be read, and the tabs then show only our own lists.
function Get-WinUtilCatalog([string]$Source = 'latest') {
    $files = [ordered]@{ Apps = 'applications'; Tweaks = 'tweaks'; Features = 'feature'; Presets = 'preset'; Dns = 'dns' }
    $bases = @()
    if ($Source -eq 'latest') { $bases += @{ Name = 'latest from Chris Titus Tech'; Url = $WinUtilRaw } }
    $local = if ($PSCommandPath) { Join-Path (Split-Path -Parent $PSCommandPath) 'winutil\config' } else { $null }
    if ($local -and (Test-Path $local)) { $bases += @{ Name = 'pinned copy (local)'; Dir = $local } }
    $bases += @{ Name = 'pinned copy'; Url = "$RepoRaw/winutil/config" }
    foreach ($b in $bases) {
        try {
            $cat = [ordered]@{ Source = $b.Name }
            foreach ($k in $files.Keys) {
                $text = if ($b.Url) { (Invoke-WebRequest -Uri "$($b.Url)/$($files[$k]).json" -UseBasicParsing -TimeoutSec 20).Content }
                else { Get-Content -Path (Join-Path $b.Dir "$($files[$k]).json") -Raw }
                $cat[$k] = ConvertFrom-LooseJson $text
            }
            # Sanity check, in case WinUtil changes its file layout.
            $apps = @($cat.Apps.PSObject.Properties)
            $tw = @($cat.Tweaks.PSObject.Properties)
            if ($apps.Count -lt 50 -or -not $apps[0].Value.winget -or $tw.Count -lt 20 -or -not $tw[0].Value.Content) { throw 'unexpected file layout' }
            return [pscustomobject]$cat
        }
        catch { Write-Host "  WinUtil catalog ($($b.Name)) not usable: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $null
}

Write-Host "$AppName $AppVersion - loading the WinUtil catalog..." -ForegroundColor Cyan
$WinUtil = Get-WinUtilCatalog $Catalog
if ($WinUtil) { Write-Host "  WinUtil catalog: $($WinUtil.Source)" -ForegroundColor DarkGray }

# Turns a config exported from WinUtil itself ({ WPFTweaks, WPFFeature, WPFInstall, Install })
# into this tool's preset format. Presets already in this format are returned unchanged.
function ConvertFrom-WinUtilExport($Config) {
    $names = @($Config.PSObject.Properties.Name)
    if ($names -contains 'apps' -or -not ($names | Where-Object { $_ -in 'WPFTweaks', 'WPFFeature', 'WPFInstall', 'WPFToggle', 'Install' })) { return $Config }
    $tweaks = @()
    $toggles = [ordered]@{}
    foreach ($k in @($Config.WPFTweaks | Where-Object { $_ })) { if ($k -like 'WPFToggle*') { $toggles[$k] = $true } else { $tweaks += $k } }
    foreach ($k in @($Config.WPFToggle | Where-Object { $_ })) { $toggles[$k] = $true }
    $apps = @()
    foreach ($i in @($Config.Install | Where-Object { $_ })) {
        if ($i.winget -and $i.winget -ne 'na') { $apps += [string]$i.winget } elseif ($i.choco -and $i.choco -ne 'na') { $apps += "choco:$($i.choco)" }
    }
    if (-not $apps -and $WinUtil) {
        foreach ($k in @($Config.WPFInstall | Where-Object { $_ })) { $a = $WinUtil.Apps.($k -replace '^WPFInstall'); if ($a) { $apps += [string]$a.winget } }
    }
    [pscustomobject]@{
        restorePoint = $true
        apps         = [pscustomobject]@{ install = $apps; upgradeAll = $false }
        winutil      = [pscustomobject]@{ tweaks = $tweaks; toggles = [pscustomobject]$toggles; features = @($Config.WPFFeature | Where-Object { $_ }) }
    }
}

# --- Unattended mode ---------------------------------------------------------

# A preset file or URL. BaseDir is where relative files in it (installers, start2.bin...)
# are looked up: the file's folder, or the URL's folder for a preset on the web.
function Read-Preset([string]$PathOrUrl) {
    if ($PathOrUrl -match '^https?://') {
        $text = (Invoke-WebRequest -Uri $PathOrUrl -UseBasicParsing).Content
        return @{ Config = (ConvertFrom-WinUtilExport ($text | ConvertFrom-Json)); BaseDir = ($PathOrUrl -replace '/[^/]*$', '') }
    }
    $full = (Resolve-Path $PathOrUrl).Path
    @{ Config = (ConvertFrom-WinUtilExport (Get-Content -Path $full -Raw | ConvertFrom-Json)); BaseDir = (Split-Path -Parent $full) }
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
        Title="__TITLE__" Width="1240" Height="860" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#14161F" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E4E6F0"/></Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E6F0"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E4E6F0"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E6F0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <DockPanel Background="Transparent">
              <Border x:Name="Track" DockPanel.Dock="Right" Width="38" Height="20" CornerRadius="10" Background="#3A3F55" Margin="12,0,0,0" VerticalAlignment="Center">
                <Ellipse x:Name="Knob" Width="14" Height="14" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#2EA043"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#8FB4FF"/>
      <Setter Property="BorderBrush" Value="#2C3042"/>
      <Setter Property="Margin" Value="0,0,12,12"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Width" Value="250"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="#8FB4FF"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="MinWidth" Value="180"/>
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
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
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
    <Style x:Key="Side" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2C3042"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" Padding="16,9" Margin="0,0,4,0" CornerRadius="6,6,0,0" Cursor="Hand">
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
    <Border DockPanel.Dock="Top" Padding="20,12" Background="#0F1118">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="DryRunBox" Content="Dry run (preview only)" VerticalAlignment="Center" Margin="0,0,16,0"/>
          <Button x:Name="RunAllBtn" Content="Run everything ticked on the tabs" Style="{StaticResource Secondary}"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <Border Background="#3B6FF6" CornerRadius="6" Width="36" Height="36" Margin="0,0,12,0">
            <TextBlock Text="VC" FontWeight="Bold" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="White"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="TitleText" FontSize="19" FontWeight="SemiBold"/>
            <TextBlock x:Name="SubTitle" Foreground="#8A8FA6" FontSize="12"/>
          </StackPanel>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border DockPanel.Dock="Bottom" Background="#0F1118" Height="170" Padding="12,8">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
          <Button x:Name="ClearLogBtn" DockPanel.Dock="Right" Content="Clear" Style="{StaticResource Secondary}" Padding="10,3" Margin="0"/>
          <TextBlock x:Name="CreditText" DockPanel.Dock="Right" Foreground="#5D6278" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0"
                     Text="Install, Tweaks, Config and Updates are based on WinUtil by Chris Titus Tech (MIT licence)"/>
          <TextBlock x:Name="StatusText" Text="Ready" Foreground="#8A8FA6" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox x:Name="LogBox" IsReadOnly="True" Background="#0A0B10" Foreground="#B9F6CA" BorderThickness="0"
                 FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
      </DockPanel>
    </Border>

    <TabControl x:Name="Tabs" Background="#1D2030" BorderThickness="0" Padding="16" Margin="12,10,12,0">

      <!-- ===================== Vector Contour: review and go ===================== -->
      <TabItem Header="Vector Contour">
        <DockPanel>
          <Border DockPanel.Dock="Top" Background="#14161F" CornerRadius="8" Padding="16,14" Margin="0,0,0,12">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center">
                <Button x:Name="GoBtn" Content="Looks good, go" FontSize="16" Padding="26,10" Background="#2EA043" Margin="0,0,0,6"/>
                <Button x:Name="PreviewBtn" Content="Preview first (changes nothing)" Style="{StaticResource Secondary}" Margin="0"/>
              </StackPanel>
              <StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                  <TextBlock Text="Set up this PC as:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="15"/>
                  <ComboBox x:Name="CompanyPresetBox" MinWidth="260" VerticalAlignment="Center"/>
                  <Button x:Name="ReviewLoadBtn" Content="Load a preset file..." Style="{StaticResource Secondary}" Padding="10,4" Margin="10,0,0,0"/>
                </StackPanel>
                <TextBlock x:Name="ReviewTitle" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock x:Name="ReviewSub" Foreground="#8A8FA6" TextWrapping="Wrap" Margin="0,4,0,8"
                           Text="Everything below is ticked and ready: say yes to all with the green button, or untick anything you don't want and open a section to change folder names and locations."/>
                <WrapPanel>
                  <CheckBox x:Name="ReviewRestoreBox" Content="Create a restore point first" IsChecked="True" VerticalAlignment="Center" Margin="0,0,16,0"/>
                  <Button x:Name="ReviewExpandBtn" Content="Show all details" Style="{StaticResource Secondary}" Padding="10,4"/>
                  <Button x:Name="ReviewFromTabsBtn" Content="Use what I picked on the other tabs" Style="{StaticResource Secondary}" Padding="10,4"/>
                </WrapPanel>
              </StackPanel>
            </DockPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="ReviewPanel"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- ===================== Install ===================== -->
      <TabItem Header="Install">
        <DockPanel>
          <ScrollViewer DockPanel.Dock="Left" Width="230" VerticalScrollBarVisibility="Auto" Margin="0,0,14,0">
            <StackPanel>
              <TextBox x:Name="AppSearch" Padding="6,5" Margin="0,0,0,8" Background="#14161F" Foreground="White" BorderBrush="#2C3042" ToolTip="Search apps"/>
              <TextBlock x:Name="AppCountText" Text="Selected apps: 0" Foreground="#8A8FA6" Margin="0,0,0,8"/>
              <Button x:Name="InstallBtn" Content="Install / upgrade selected" Margin="0,0,0,6" HorizontalContentAlignment="Left"/>
              <Button x:Name="UninstallBtn" Content="Uninstall selected" Style="{StaticResource Side}"/>
              <Button x:Name="UpgradeBtn" Content="Upgrade all apps" Style="{StaticResource Side}"/>
              <Button x:Name="GetInstalledBtn" Content="Show installed apps" Style="{StaticResource Side}"/>
              <Button x:Name="AppsNoneBtn" Content="Clear selection" Style="{StaticResource Side}"/>
              <Button x:Name="ExpandAppsBtn" Content="Expand all categories" Style="{StaticResource Side}"/>
              <Button x:Name="CollapseAppsBtn" Content="Collapse all categories" Style="{StaticResource Side}"/>
              <TextBlock Text="Package manager" Foreground="#8FB4FF" Margin="0,10,0,4"/>
              <RadioButton x:Name="WingetRadio" Content="WinGet (recommended)" IsChecked="True" GroupName="Pm"/>
              <RadioButton x:Name="ChocoRadio" Content="Chocolatey" GroupName="Pm"/>
              <CheckBox x:Name="FossOnlyBox" Content="Only free and open source" Margin="0,10,0,0"/>
              <TextBlock Text="Add your own app" Foreground="#8FB4FF" Margin="0,14,0,4"/>
              <TextBlock Text="Download link, GitHub owner/repo (latest release) or winget ID." Foreground="#8A8FA6" FontSize="11" TextWrapping="Wrap"/>
              <TextBox x:Name="AddName" Padding="6,4" Margin="0,4,0,4" Background="#14161F" Foreground="White" BorderBrush="#2C3042" ToolTip="App name"/>
              <TextBox x:Name="AddSource" Padding="6,4" Margin="0,0,0,4" Background="#14161F" Foreground="White" BorderBrush="#2C3042" ToolTip="https://vendor.com/setup.exe  or  owner/repo  or  Vendor.App"/>
              <TextBox x:Name="AddArgs" Padding="6,4" Margin="0,0,0,4" Background="#14161F" Foreground="White" BorderBrush="#2C3042" ToolTip="Silent switches for .exe installers, e.g. /S, /VERYSILENT, /quiet"/>
              <TextBlock Text="name / link or ID / silent switches" Foreground="#5D6278" FontSize="11" Margin="0,0,0,4"/>
              <Button x:Name="AddAppBtn" Content="Add app" Style="{StaticResource Side}"/>
            </StackPanel>
          </ScrollViewer>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="AppPanel"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- ===================== Tweaks ===================== -->
      <TabItem Header="Tweaks">
        <DockPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Pick:" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#8A8FA6"/>
            <Button x:Name="TweakStandardBtn" Content="Standard" Style="{StaticResource Secondary}" ToolTip="WinUtil's recommended set"/>
            <Button x:Name="TweakMinimalBtn" Content="Minimal" Style="{StaticResource Secondary}"/>
            <Button x:Name="TweakAdvancedBtn" Content="Advanced" Style="{StaticResource Secondary}"/>
            <Button x:Name="RecommendedBtn" Content="Vector recommended" Style="{StaticResource Secondary}"/>
            <Button x:Name="TweaksNoneBtn" Content="Clear" Style="{StaticResource Secondary}" Margin="0,0,24,0"/>
            <Button x:Name="ApplyTweaksBtn" Content="Run tweaks"/>
            <Button x:Name="UndoTweaksBtn" Content="Undo selected tweaks" Style="{StaticResource Secondary}"/>
            <CheckBox x:Name="RestorePointBox" Content="Create a restore point first" IsChecked="True" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </WrapPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0">
                <GroupBox Header="Essential tweaks" Width="Auto"><StackPanel x:Name="EssentialPanel"/></GroupBox>
                <GroupBox Header="Advanced tweaks - CAUTION" Width="Auto"><StackPanel x:Name="AdvancedPanel"/></GroupBox>
                <GroupBox Header="Vector Contour tweaks (with undo)" Width="Auto"><StackPanel x:Name="TweakPanel"/></GroupBox>
              </StackPanel>
              <StackPanel Grid.Column="1">
                <GroupBox Header="Preferences (switch to apply now)" Width="Auto"><StackPanel x:Name="TogglePanel"/></GroupBox>
                <GroupBox Header="Performance plans - not for laptops" Width="Auto">
                  <WrapPanel>
                    <Button x:Name="UltPerfOnBtn" Content="Add Ultimate Performance plan" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    <Button x:Name="UltPerfOffBtn" Content="Remove it" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                  </WrapPanel>
                </GroupBox>
                <GroupBox Header="DNS and display" Width="Auto">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                      <TextBlock Text="DNS" Width="130" VerticalAlignment="Center"/>
                      <ComboBox x:Name="DnsBox"/>
                      <Button x:Name="DnsApplyBtn" Content="Set" Style="{StaticResource Secondary}" Padding="10,4" Margin="8,0,0,0"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="Multiplane overlay" Width="130" VerticalAlignment="Center"/>
                      <ComboBox x:Name="MpoBox"/>
                      <Button x:Name="MpoApplyBtn" Content="Set" Style="{StaticResource Secondary}" Padding="10,4" Margin="8,0,0,0"/>
                    </StackPanel>
                  </StackPanel>
                </GroupBox>
                <GroupBox Header="Remove built-in apps" Width="Auto">
                  <StackPanel>
                    <WrapPanel x:Name="BloatPanel"/>
                    <WrapPanel Margin="0,8,0,0">
                      <Button x:Name="RemoveAppsBtn" Content="Remove selected"/>
                      <Button x:Name="BloatDefaultBtn" Content="Select WinUtil's list" Style="{StaticResource Secondary}"/>
                    </WrapPanel>
                  </StackPanel>
                </GroupBox>
                <GroupBox Header="More privacy settings" Width="Auto">
                  <StackPanel>
                    <TextBlock Text="O&amp;O ShutUp10++ is a free privacy tool with hundreds of switches. Downloads and opens it (nothing is installed)." Foreground="#8A8FA6" TextWrapping="Wrap" FontSize="12" Margin="0,0,0,6"/>
                    <Button x:Name="OosuBtn" Content="Open O&amp;O ShutUp10++" Style="{StaticResource Secondary}" HorizontalAlignment="Left"/>
                  </StackPanel>
                </GroupBox>
              </StackPanel>
            </Grid>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <!-- ===================== Config ===================== -->
      <TabItem Header="Config">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <WrapPanel>
            <GroupBox Header="Features" Width="340">
              <StackPanel>
                <StackPanel x:Name="WuFeaturePanel"/>
                <Button x:Name="WuFeatureBtn" Content="Install features" HorizontalAlignment="Left" Margin="0,10,0,0"/>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Windows optional features" Width="340">
              <StackPanel>
                <StackPanel x:Name="FeaturePanel"/>
                <WrapPanel Margin="0,10,0,0">
                  <Button x:Name="EnableFeaturesBtn" Content="Turn on"/>
                  <Button x:Name="DisableFeaturesBtn" Content="Turn off" Style="{StaticResource Secondary}"/>
                </WrapPanel>
              </StackPanel>
            </GroupBox>
            <GroupBox Header="Fixes" Width="300"><StackPanel x:Name="FixesPanel"/></GroupBox>
            <GroupBox Header="Legacy Windows panels" Width="300"><StackPanel x:Name="PanelsPanel"/></GroupBox>
            <GroupBox Header="Remote access and PowerShell" Width="300"><StackPanel x:Name="RemotePanel"/></GroupBox>
          </WrapPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ===================== Updates ===================== -->
      <TabItem Header="Updates">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock x:Name="UpdateStateText" Foreground="#8A8FA6" Margin="0,0,0,12"/>
            <WrapPanel>
              <Border Background="#14161F" CornerRadius="8" Padding="16" Margin="0,0,12,12" Width="320">
                <StackPanel>
                  <TextBlock Text="Default settings" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock TextWrapping="Wrap" Foreground="#8A8FA6" Margin="0,6,0,12"
                             Text="The way Windows ships: updates and drivers install automatically. Removes any update rules set by this tool or WinUtil."/>
                  <Button x:Name="UpdDefaultBtn" Content="Use default settings" Style="{StaticResource Secondary}" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
              <Border Background="#14161F" CornerRadius="8" Padding="16" Margin="0,0,12,12" Width="320" BorderBrush="#2EA043" BorderThickness="1">
                <StackPanel>
                  <TextBlock Text="Security updates only (recommended)" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <TextBlock TextWrapping="Wrap" Foreground="#8A8FA6" Margin="0,6,0,12"
                             Text="Security fixes arrive 4 days after release, big feature updates wait a year, and Windows Update no longer replaces drivers. Windows asks before installing. Good for machine PCs that must stay stable."/>
                  <Button x:Name="UpdSecurityBtn" Content="Use security settings" Background="#2EA043" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
              <Border Background="#14161F" CornerRadius="8" Padding="16" Margin="0,0,12,12" Width="320">
                <StackPanel>
                  <TextBlock Text="Turn off all updates" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock TextWrapping="Wrap" Foreground="#8A8FA6" Margin="0,6,0,12"
                             Text="Stops Windows Update completely, including security fixes. Not recommended: only for PCs that never go online. Undo with Default settings."/>
                  <Button x:Name="UpdDisableBtn" Content="Turn off updates" Background="#B3261E" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
            </WrapPanel>
            <WrapPanel Margin="0,4,0,0">
              <Button x:Name="UpdScanBtn" Content="Check for Windows updates now" Style="{StaticResource Secondary}"/>
              <Button x:Name="UpdAppsBtn" Content="Upgrade all apps (winget)" Style="{StaticResource Secondary}"/>
              <Button x:Name="UpdRepairBtn" Content="Reset Windows Update" Style="{StaticResource Secondary}"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ===================== Folders ===================== -->
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

      <!-- ===================== Presets and about ===================== -->
      <TabItem Header="Presets">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock TextWrapping="Wrap" Foreground="#8A8FA6" Margin="0,0,0,12" MaxWidth="760" HorizontalAlignment="Left"
                       Text="Save everything you have selected on the other tabs as a preset file. Load it on the next PC, or run it without the window. WinUtil's own exported config files load here too."/>
            <TextBox x:Name="PresetCmd" IsReadOnly="True" Background="#0A0B10" Foreground="#B9F6CA" BorderThickness="0"
                     FontFamily="Consolas" Padding="8" Margin="0,0,0,16" HorizontalAlignment="Left" MaxWidth="900" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,24">
              <Button x:Name="ExportBtn" Content="Save selections as preset..."/>
              <Button x:Name="ImportBtn" Content="Load preset..." Style="{StaticResource Secondary}"/>
            </StackPanel>
            <TextBlock Text="About" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <TextBlock x:Name="AboutText" TextWrapping="Wrap" Foreground="#8A8FA6" MaxWidth="760" HorizontalAlignment="Left"/>
          </StackPanel>
        </ScrollViewer>
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
    if ($n -notin 'Track', 'Knob', 'Bd') { $ui[$n] = $window.FindName($n) }
}
$ui.TitleText.Text = $AppName
$ui.SubTitle.Text = 'Pick what you want, then run. Everything already in place is skipped.'
$ui.PresetCmd.Text = "& ([scriptblock]::Create((irm $SourceUrl))) -Preset C:\path\to\preset.json -Run"
$wuSource = if ($WinUtil) { $WinUtil.Source } else { 'not loaded (offline?)' }
$ui.AboutText.Text = "$AppName $AppVersion. Vector Contour's setup steps are on the first tab.`n`n" +
"The Install, Tweaks, Config and Updates tabs are built from WinUtil by Chris Titus Tech (github.com/ChrisTitusTech/winutil), " +
"used under the MIT licence, Copyright (c) 2022 CT Tech Group LLC. Its app list, tweaks and features are read from WinUtil's own " +
"config files when the window opens, so they stay current. Catalog used this time: $wuSource."

# Shared state with the background runspace.
$sync = [hashtable]::Synchronized(@{})
$sync.LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$sync.Busy = $false

function New-Text([string]$Text, [string]$Color = '#8A8FA6', [int]$Size = 12) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = $Color
    $t.FontSize = $Size
    $t.TextWrapping = 'Wrap'
    $t
}

# A checkbox with a title and, optionally, a grey description underneath.
function New-LabeledBox([string]$Title, [string]$Description, $Tag, [string]$Tip) {
    $cb = New-Object System.Windows.Controls.CheckBox
    if ($Description) {
        $label = New-Object System.Windows.Controls.StackPanel
        [void]$label.Children.Add((New-Text $Title '#E4E6F0' 13))
        [void]$label.Children.Add((New-Text $Description))
        $cb.Content = $label
        $cb.Margin = '0,4'
    }
    else { $cb.Content = $Title }
    $cb.Tag = $Tag
    if ($Tip) { $cb.ToolTip = $Tip }
    $cb
}

# --- Install tab ---

$appBoxes = New-Object System.Collections.Generic.List[object]
$appExpanders = New-Object System.Collections.Generic.List[object]
$customApps = @{}   # Tag -> direct-download object or winget ID added from the window / a preset
$catalogTags = @{}  # Tag (winget ID or catalog Id) -> checkbox
$chocoToTag = @{}   # Chocolatey package -> tag, for "Show installed" with Chocolatey

function Update-AppCount { $ui.AppCountText.Text = "Selected apps: $(@($appBoxes | Where-Object IsChecked).Count)" }

function New-AppBox([string]$Label, [string]$Tag, [string]$Tip, [bool]$Foss) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Label
    $cb.Tag = $Tag
    $cb.ToolTip = $Tip
    $cb.Width = 225
    $cb.Margin = '0,3,8,3'
    if ($Foss) { $cb.Foreground = '#B9F6CA' }
    $cb.Add_Click({ Update-AppCount })
    $appBoxes.Add($cb)
    $catalogTags[$Tag] = $cb
    $cb
}

function Add-AppCategory([string]$Name, $Boxes) {
    $exp = New-Object System.Windows.Controls.Expander
    $exp.Header = $Name
    $exp.IsExpanded = $true
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Margin = '18,6,0,6'
    foreach ($b in $Boxes) { [void]$wrap.Children.Add($b) }
    $exp.Content = $wrap
    [void]$ui.AppPanel.Children.Add($exp)
    $appExpanders.Add($exp)
    $exp
}

# "Your apps" first: apps added from the window or from a preset.
$customWrap = New-Object System.Windows.Controls.WrapPanel
$customWrap.Margin = '18,6,0,6'
$customExp = New-Object System.Windows.Controls.Expander
$customExp.Header = 'Your apps'
$customExp.IsExpanded = $true
$customExp.Content = $customWrap
$customExp.Visibility = 'Collapsed'
[void]$ui.AppPanel.Children.Add($customExp)

$wingetIds = @{}
if ($WinUtil) {
    $groups = @{}
    foreach ($p in $WinUtil.Apps.PSObject.Properties) {
        $a = $p.Value
        $id = [string]$a.winget
        if (-not $id -or $id -eq 'na') { $id = "choco:$($a.choco)" }
        $wingetIds[$id] = $true
        if ($a.choco -and $a.choco -ne 'na') { $chocoToTag[[string]$a.choco] = $id }
        $tip = "$($a.description)`n`nwinget: $($a.winget)   choco: $($a.choco)$(if ($a.foss) { '   (free and open source)' })`n$($a.link)"
        $cat = if ($a.category) { [string]$a.category } else { 'Other' }
        if (-not $groups[$cat]) { $groups[$cat] = New-Object System.Collections.Generic.List[object] }
        $groups[$cat].Add((New-AppBox $a.content $id $tip ([bool]$a.foss)))
    }
    foreach ($cat in ($groups.Keys | Sort-Object)) { [void](Add-AppCategory $cat ($groups[$cat] | Sort-Object { $_.Content })) }
}
# Apps from this tool's own list that WinUtil doesn't have (and all of them when WinUtil is offline).
$extra = New-Object System.Collections.Generic.List[object]
foreach ($cat in $AppCatalog.Keys) {
    foreach ($app in $AppCatalog[$cat]) {
        if ($wingetIds.ContainsKey($app.Id)) { continue }
        $tip = if ($app.github) { "Latest release from github.com/$($app.github)" } elseif ($app.url -or $app.page) { 'Direct download' } else { "winget: $($app.Id)" }
        $extra.Add((New-AppBox $app.Name $app.Id $tip $false))
    }
}
if ($extra.Count) { [void](Add-AppCategory 'More (Vector Contour list)' $extra) }

# $App is a winget ID string or a direct-download object. Returns the checkbox.
function Add-CustomApp($App) {
    if ($App -is [string]) { $tag = $App; $label = $App; $tip = "winget: $App" }
    else {
        $tag = "custom:$($App.name)"; $label = $App.name
        $tip = if ($App.github) { "Latest release from github.com/$($App.github)" } elseif ($App.page) { "Latest link on $($App.page)" } elseif ($App.path) { "Local installer: $($App.path)" } else { $App.url }
    }
    if ($catalogTags.ContainsKey($tag)) { $customApps[$tag] = $App; return $catalogTags[$tag] }
    $cb = New-AppBox $label $tag $tip $false
    $cb.IsChecked = $true
    [void]$customWrap.Children.Add($cb)
    $customApps[$tag] = $App
    $customExp.Visibility = 'Visible'
    Update-AppCount
    $cb
}

# Checked apps as Install-Apps / presets expect them: strings, or objects for custom direct apps.
function Get-CheckedApps {
    @(foreach ($tag in (Get-Checked $appBoxes)) {
            if ($customApps.ContainsKey($tag)) { $customApps[$tag] } else { $tag }
        })
}

function Update-AppFilter {
    $q = $ui.AppSearch.Text.Trim()
    $foss = [bool]$ui.FossOnlyBox.IsChecked
    foreach ($cb in $appBoxes) {
        $match = (-not $q -or $cb.Content -like "*$q*" -or $cb.Tag -like "*$q*") -and (-not $foss -or "$($cb.Foreground)" -eq '#FFB9F6CA')
        $cb.Visibility = if ($match) { 'Visible' } else { 'Collapsed' }
    }
    foreach ($e in @($appExpanders) + @($customExp)) {
        if ($e -eq $customExp -and -not $customWrap.Children.Count) { continue }
        $any = @($e.Content.Children | Where-Object { $_.Visibility -eq 'Visible' }).Count
        $e.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
        if ($q -and $any) { $e.IsExpanded = $true }
    }
}

function Get-PackageManager { if ($ui.ChocoRadio.IsChecked) { 'choco' } else { 'winget' } }

# --- Tweaks tab ---

$wuTweakBoxes = @()
$toggleBoxes = @()
$script:ToggleChanges = [ordered]@{}
$script:SettingToggles = $false

if ($WinUtil) {
    foreach ($p in $WinUtil.Tweaks.PSObject.Properties) {
        $t = $p.Value
        $tip = "$($t.Description)$(if ($t.link) { "`n$($t.link)" })"
        if ($t.Type -eq 'Toggle') {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $window.FindResource('Switch')
            $cb.Content = $t.Content
            $cb.Tag = $p.Name
            $cb.ToolTip = $tip
            try { $cb.IsChecked = Get-WinUtilToggleState $p.Name } catch { }
            $cb.Add_Click({
                    $on = [bool]$this.IsChecked
                    if ($sync.Busy) { $this.IsChecked = -not $on; $sync.LogQueue.Enqueue('Busy with another job. Try again when it finishes.'); return }
                    $script:ToggleChanges[[string]$this.Tag] = $on
                    $job = @{}; $job[[string]$this.Tag] = $on
                    Start-EngineJob 'Set-WinUtilToggles $Job' $job
                })
            [void]$ui.TogglePanel.Children.Add($cb)
            $toggleBoxes += $cb
            continue
        }
        if ($t.Type) { continue }   # buttons and combo boxes have their own controls
        $cb = New-LabeledBox $t.Content $null $p.Name $tip
        if ($t.category -like 'Essential*') { [void]$ui.EssentialPanel.Children.Add($cb) }
        else { [void]$ui.AdvancedPanel.Children.Add($cb) }
        $wuTweakBoxes += $cb
    }
    foreach ($n in @('Default', 'DHCP', 'Fastest') + @($WinUtil.Dns.PSObject.Properties.Name)) { [void]$ui.DnsBox.Items.Add($n) }
    $mpo = $WinUtil.Tweaks.WPFMultiplaneOverlay
    if ($mpo) { foreach ($c in ([string]$mpo.ComboItems -split '\|')) { [void]$ui.MpoBox.Items.Add($c) } }
}
else {
    [void]$ui.EssentialPanel.Children.Add((New-Text 'WinUtil tweaks need an internet connection. Close and reopen the tool when the PC is online.'))
    [void]$ui.DnsBox.Items.Add('Default')
}
$ui.DnsBox.SelectedIndex = 0
if ($ui.MpoBox.Items.Count) { $ui.MpoBox.SelectedIndex = 0 }

$tweakBoxes = @()
foreach ($key in $TweakCatalog.Keys) {
    $t = $TweakCatalog[$key]
    $title = if ($t.Recommended) { "$($t.Label)  (recommended)" } else { $t.Label }
    $cb = New-LabeledBox $title $t.Description $key $null
    [void]$ui.TweakPanel.Children.Add($cb)
    $tweakBoxes += $cb
}

$bloatBoxes = @()
foreach ($key in $BuiltInAppCatalog.Keys) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $BuiltInAppCatalog[$key]
    $cb.Tag = $key
    $cb.ToolTip = $key
    $cb.Width = 200
    [void]$ui.BloatPanel.Children.Add($cb)
    $bloatBoxes += $cb
}

# --- Config tab ---

$wuFeatureBoxes = @()
if ($WinUtil) {
    foreach ($p in $WinUtil.Features.PSObject.Properties) {
        $f = $p.Value
        if ($p.Name -eq 'WPFFeatureInstall') { continue }   # that's the "Install features" button
        $tip = "$($f.Description)$(if ($f.link) { "`n$($f.link)" })"
        if (-not $f.Type) {
            $cb = New-LabeledBox $f.Content $null $p.Name $tip
            [void]$ui.WuFeaturePanel.Children.Add($cb)
            $wuFeatureBoxes += $cb
            continue
        }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $f.Content
        $b.Tag = $p.Name
        $b.ToolTip = $tip
        $b.Style = $window.FindResource('Side')
        $panel = switch -Wildcard ($f.category) {
            'Fixes' { $ui.FixesPanel }
            'Legacy*' { $ui.PanelsPanel }
            default { $ui.RemotePanel }
        }
        if ($f.category -like 'Legacy*') {
            # Control Panel pages just open, no job needed.
            $b.Add_Click({
                    $code = [string](@((Get-WinUtilEntry 'Features' $this.Tag).InvokeScript)[0]).Trim()
                    try { if ($code -match '^[\w.]+$') { Start-Process $code } else { & ([scriptblock]::Create($code)) } }
                    catch { $sync.LogQueue.Enqueue("Could not open $($this.Content): $($_.Exception.Message)") }
                })
        }
        else { $b.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions @($Job)' @([string]$this.Tag) }) }
        [void]$panel.Children.Add($b)
    }
}
else { [void]$ui.WuFeaturePanel.Children.Add((New-Text 'WinUtil features need an internet connection.')) }

$featureBoxes = @()
foreach ($key in $FeatureCatalog.Keys) {
    $cb = New-LabeledBox $FeatureCatalog[$key] $null $key $key
    [void]$ui.FeaturePanel.Children.Add($cb)
    $featureBoxes += $cb
}

# --- Updates tab ---

function Update-UpdateState {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $no = (Get-ItemProperty -Path "$wu\AU" -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
    $defer = (Get-ItemProperty -Path $wu -Name DeferFeatureUpdates -ErrorAction SilentlyContinue).DeferFeatureUpdates
    $mode = if ($no -eq 1) { 'turned off' } elseif ($defer -eq 1) { 'security updates only' } else { 'Windows default' }
    $ui.UpdateStateText.Text = "This PC is set to: $mode."
}

# --- Folders tab ---

$templateBoxes = @()
foreach ($key in $FolderTemplates.Keys) {
    $t = $FolderTemplates[$key]
    $tip = ($t.Folders -join "`n")
    if ($t.Pin) { $tip += "`n`nPinned to Quick Access:`n" + ($t.Pin -join "`n") }
    $cb = New-LabeledBox $t.Label $t.Description $key $tip
    [void]$ui.TemplatePanel.Children.Add($cb)
    $templateBoxes += $cb
}

$ui.FolderBox.Text = "C:\Tools`r`n%USERPROFILE%\Projects"

function Get-Checked($Boxes) { @($Boxes | Where-Object IsChecked | ForEach-Object { [string]$_.Tag }) }
function Set-Checked($Boxes, [string[]]$Tags) { foreach ($b in $Boxes) { $b.IsChecked = $Tags -contains [string]$b.Tag } }

# --- Background runner ---

$allButtons = @('RunAllBtn', 'InstallBtn', 'UninstallBtn', 'UpgradeBtn', 'GetInstalledBtn', 'ApplyTweaksBtn', 'UndoTweaksBtn', 'RemoveAppsBtn',
    'EnableFeaturesBtn', 'DisableFeaturesBtn', 'WuFeatureBtn', 'CreateFoldersBtn', 'ImportBtn', 'GoBtn', 'PreviewBtn', 'ReviewLoadBtn',
    'ReviewFromTabsBtn', 'UltPerfOnBtn', 'UltPerfOffBtn', 'DnsApplyBtn', 'MpoApplyBtn', 'OosuBtn', 'UpdDefaultBtn', 'UpdSecurityBtn',
    'UpdDisableBtn', 'UpdScanBtn', 'UpdAppsBtn', 'UpdRepairBtn')
$script:OnJobDone = $null

# Runs $Script (text) in a new runspace with the engine loaded and $Job available.
# $OnDone runs on the UI thread when the job has finished.
function Start-EngineJob([string]$Script, $Job, [scriptblock]$OnDone) {
    if ($sync.Busy) { $sync.LogQueue.Enqueue('Busy with another job. Try again when it finishes.'); return }
    $sync.Busy = $true
    $sync.UiLocked = $true
    $script:OnJobDone = $OnDone
    foreach ($b in $allButtons) { $ui[$b].IsEnabled = $false }
    foreach ($t in $toggleBoxes) { $t.IsEnabled = $false }
    $ui.StatusText.Text = 'Working... (you can keep browsing, buttons come back when it is done)'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('Job', $Job)
    $rs.SessionStateProxy.SetVariable('DryRun', [bool]$ui.DryRunBox.IsChecked)
    $rs.SessionStateProxy.SetVariable('AppName', $AppName)
    $rs.SessionStateProxy.SetVariable('WinUtil', $WinUtil)

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
            foreach ($t in $toggleBoxes) { $t.IsEnabled = $true }
            $ui.StatusText.Text = 'Done'
            Update-UpdateState
            if ($script:OnJobDone) {
                $done = $script:OnJobDone
                $script:OnJobDone = $null
                try { & $done } catch { $ui.LogBox.AppendText("$($_.Exception.Message)`r`n") }
            }
        }
    })
$timer.Start()

# --- Build and load presets ---

# Preset sections the window has no controls for (power is a tweak, but wallpaper,
# shortcuts, copied folders, files, registry...). Kept from the loaded preset so
# saving or running from the window doesn't drop them.
$script:LoadedPreset = $null
$script:LoadedBaseDir = $null
$PassThroughKeys = 'installerRoot', 'files', 'registry', 'copyFolders', 'shortcuts', 'removeShortcuts', 'wallpaper', 'startLayout', 'updates'

function Get-SelectionPreset {
    $tweaks = [ordered]@{}
    foreach ($k in (Get-Checked $tweakBoxes)) { $tweaks[$k] = $true }
    $toggles = [ordered]@{}
    if ($script:LoadedPreset.winutil.toggles) { foreach ($p in $script:LoadedPreset.winutil.toggles.PSObject.Properties) { $toggles[$p.Name] = [bool]$p.Value } }
    foreach ($k in $script:ToggleChanges.Keys) { $toggles[$k] = $script:ToggleChanges[$k] }
    $dns = [string]$ui.DnsBox.SelectedItem
    $p = [ordered]@{
        restorePoint    = [bool]$ui.RestorePointBox.IsChecked
        packageManager  = Get-PackageManager
        apps            = [ordered]@{ install = @(Get-CheckedApps); upgradeAll = $false }
        removeApps      = @(Get-Checked $bloatBoxes)
        folderTemplates = @(Get-Checked $templateBoxes)
        folders         = @($ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() })
        quickAccess     = @(if ($ui.PinFoldersBox.IsChecked) { $ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() } })
        files           = @()
        tweaks          = $tweaks
        winutil         = [ordered]@{ tweaks = @(Get-Checked $wuTweakBoxes); toggles = $toggles; features = @(Get-Checked $wuFeatureBoxes); actions = @() }
        dns             = $(if ($dns -and $dns -ne 'Default') { $dns } else { $null })
        registry        = @()
        features        = [ordered]@{ enable = @(Get-Checked $featureBoxes); disable = @() }
    }
    if ($script:LoadedPreset) {
        foreach ($k in $PassThroughKeys) {
            if ($null -ne $script:LoadedPreset.$k) { $p[$k] = $script:LoadedPreset.$k }
        }
        $p.apps.upgradeAll = [bool]$script:LoadedPreset.apps.upgradeAll
        $p.features.disable = @($script:LoadedPreset.features.disable | Where-Object { $_ })
        # Features in the preset that aren't in the Config tab list.
        $p.features.enable = @($p.features.enable) + @($script:LoadedPreset.features.enable | Where-Object { $_ -and -not $FeatureCatalog.Contains($_) })
        $p.winutil.actions = @($script:LoadedPreset.winutil.actions | Where-Object { $_ })
        if ($script:LoadedPreset.winutil.choices) { $p.winutil.choices = $script:LoadedPreset.winutil.choices }
    }
    $p
}

function Set-SelectionFromPreset($Config, [string]$BaseDir, [string]$Name = 'preset') {
    $script:LoadedPreset = $Config
    $script:LoadedBaseDir = $BaseDir
    # Anything not in the catalog (other winget IDs, direct downloads) goes under "Your apps".
    $tags = foreach ($a in @($Config.apps.install | Where-Object { $_ })) {
        if ($a -isnot [string]) { [string](Add-CustomApp $a).Tag }
        elseif ($catalogTags.ContainsKey($a)) { $a }
        else { [string](Add-CustomApp $a).Tag }
    }
    Set-Checked $appBoxes @($tags)
    Update-AppCount
    if ($Config.packageManager -eq 'choco') { $ui.ChocoRadio.IsChecked = $true } else { $ui.WingetRadio.IsChecked = $true }
    Set-Checked $bloatBoxes @($Config.removeApps)
    Set-Checked $featureBoxes @($Config.features.enable)
    Set-Checked $wuFeatureBoxes @($Config.winutil.features)
    Set-Checked $wuTweakBoxes @($Config.winutil.tweaks)
    $on = @()
    if ($Config.tweaks) { $on = @($Config.tweaks.PSObject.Properties | Where-Object Value | ForEach-Object Name) }
    Set-Checked $tweakBoxes $on
    if ($Config.dns -and $ui.DnsBox.Items.Contains([string]$Config.dns)) { $ui.DnsBox.SelectedItem = [string]$Config.dns } else { $ui.DnsBox.SelectedIndex = 0 }
    if ($Config.folders) { $ui.FolderBox.Text = (@($Config.folders) -join "`r`n") }
    Set-Checked $templateBoxes @($Config.folderTemplates | Where-Object { $_ -is [string] })
    $ui.PinFoldersBox.IsChecked = [bool]$Config.quickAccess
    if ($null -ne $Config.restorePoint) { $ui.RestorePointBox.IsChecked = [bool]$Config.restorePoint }
    Build-Review $Config $Name
}

# --- Review & go ---
# One page listing everything that will happen, all ticked. Untick to skip, edit the
# text boxes to change paths, then one button runs it.

$script:ReviewItems = New-Object System.Collections.ArrayList
$script:ReviewExpanders = New-Object System.Collections.ArrayList

function New-ReviewText([string]$Text) {
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $Text
    $tb.Padding = '6,3'
    $tb.Background = '#1D2030'
    $tb.Foreground = 'White'
    $tb.BorderBrush = '#2C3042'
    $tb.FontFamily = 'Consolas'
    $tb.VerticalAlignment = 'Center'
    $tb
}

# One line in a section: a checkbox, and a text box when $EditText is given.
function New-ReviewRow([string]$Key, [string]$Label, $Value, $EditText, [string]$Tip) {
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = '0,3'
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.IsChecked = $true
    $cb.VerticalAlignment = 'Center'
    $cb.Margin = '0'
    if ($Label) { $cb.Content = $Label }
    if ($Tip) { $cb.ToolTip = $Tip }
    [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left')
    [void]$row.Children.Add($cb)
    $tb = $null
    if ($null -ne $EditText) {
        $cb.Margin = '0,0,8,0'
        $tb = New-ReviewText ([string]$EditText)
        [void]$row.Children.Add($tb)
    }
    [void]$script:ReviewItems.Add([pscustomobject]@{ Key = $Key; Box = $cb; Text = $tb; Value = $Value })
    $row
}

# A collapsible card. The header checkbox ticks or unticks the whole section.
# $AddKey adds a "+ Add" button that appends an empty editable row.
function Add-ReviewSection([string]$Title, [string]$Summary, $Rows, [string[]]$Keys, [string]$AddKey, [string]$AddLabel) {
    $Rows = @($Rows | Where-Object { $_ })
    if (-not $Rows -and -not $AddKey) { return }
    $card = New-Object System.Windows.Controls.Border
    $card.Background = '#14161F'
    $card.CornerRadius = 8
    $card.Padding = '12,8'
    $card.Margin = '0,0,0,8'

    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $all = New-Object System.Windows.Controls.CheckBox
    $all.IsChecked = $true
    $all.Tag = $Keys
    $all.Margin = '0,0,10,0'
    $all.VerticalAlignment = 'Center'
    $all.ToolTip = 'Tick or untick this whole section'
    $all.Add_Click({ foreach ($i in $script:ReviewItems) { if ($this.Tag -contains $i.Key) { $i.Box.IsChecked = $this.IsChecked } } })
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title
    $t.FontSize = 14
    $t.FontWeight = 'SemiBold'
    $t.VerticalAlignment = 'Center'
    $s = New-Object System.Windows.Controls.TextBlock
    $s.Text = "   $Summary"
    $s.Foreground = '#8A8FA6'
    $s.VerticalAlignment = 'Center'
    [void]$head.Children.Add($all)
    [void]$head.Children.Add($t)
    [void]$head.Children.Add($s)

    $list = New-Object System.Windows.Controls.StackPanel
    $list.Margin = '28,6,0,4'
    foreach ($r in $Rows) { [void]$list.Children.Add($r) }
    if ($AddKey) {
        $add = New-Object System.Windows.Controls.Button
        $add.Content = "+ $AddLabel"
        $add.Style = $window.FindResource('Secondary')
        $add.HorizontalAlignment = 'Left'
        $add.Padding = '10,3'
        $add.Margin = '0,6,0,0'
        $add.Tag = @{ Panel = $list; Key = $AddKey }
        $add.Add_Click({
                $p = $this.Tag
                $p.Panel.Children.Insert($p.Panel.Children.Count - 1, (New-ReviewRow $p.Key '' $null ''))
            })
        [void]$list.Children.Add($add)
    }

    $exp = New-Object System.Windows.Controls.Expander
    $exp.Header = $head
    $exp.Content = $list
    $exp.Foreground = '#E4E6F0'
    $exp.IsExpanded = $false
    [void]$script:ReviewExpanders.Add($exp)
    $card.Child = $exp
    [void]$ui.ReviewPanel.Children.Add($card)
}

function Get-AppLabel($App) {
    if ($App -is [string]) {
        if ($catalogTags.ContainsKey($App)) { return [string]$catalogTags[$App].Content }
        if ($AppIndex.ContainsKey($App)) { return $AppIndex[$App].Name }
        return $App
    }
    if ($App.path) { return "$($App.name)  (installer: $($App.path))" }
    return "$($App.name)  (download)"
}

function Get-WinUtilLabel([string]$Kind, [string]$Key) {
    $e = Get-WinUtilEntry $Kind $Key
    if ($e) { [string]$e.Content } else { $Key }
}

# Name/value pairs from a JSON object or a hashtable.
function Get-Pairs($Obj) {
    if (-not $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } }) }
    @($Obj.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

$UpdateLabels = @{ default = 'Windows default update settings'; security = 'Security updates only (recommended)'; disable = 'Turn off all Windows updates' }

function Build-Review($Config, [string]$Name) {
    $ui.ReviewPanel.Children.Clear()
    $script:ReviewItems.Clear()
    $script:ReviewExpanders.Clear()
    $ui.ReviewTitle.Text = "Ready to set up this PC with: $Name"
    $ui.ReviewRestoreBox.IsChecked = ($Config.restorePoint -ne $false)

    $apps = @($Config.apps.install | Where-Object { $_ })
    $rows = @(foreach ($a in $apps) { New-ReviewRow 'apps' (Get-AppLabel $a) $a $null $(if ($a -is [string]) { "winget: $a" }) })
    if ($Config.installerRoot) {
        $rows += New-ReviewRow 'installerRoot' 'Installers from (*:\ = any drive):' $null $Config.installerRoot 'Where the machine software installers are, e.g. a USB stick'
    }
    if ($Config.apps.upgradeAll) { $rows += New-ReviewRow 'upgradeAll' 'Upgrade every app to its latest version afterwards' $true $null }
    if ($Config.packageManager -eq 'choco') { $rows += New-ReviewRow 'packageManager' 'Install catalog apps with Chocolatey instead of winget' 'choco' $null }
    Add-ReviewSection 'Apps' "$($apps.Count) to install" $rows @('apps', 'installerRoot', 'upgradeAll', 'packageManager')

    $on = @($Config.features.enable | Where-Object { $_ })
    $off = @($Config.features.disable | Where-Object { $_ })
    $wf = @($Config.winutil.features | Where-Object { $_ })
    $rows = @(foreach ($f in $on) { New-ReviewRow 'featuresOn' $(if ($FeatureCatalog.Contains($f)) { $FeatureCatalog[$f] } else { $f }) $f $null $f })
    $rows += @(foreach ($f in $off) { New-ReviewRow 'featuresOff' "Turn off: $(if ($FeatureCatalog.Contains($f)) { $FeatureCatalog[$f] } else { $f })" $f $null $f })
    $rows += @(foreach ($f in $wf) { New-ReviewRow 'wuFeatures' (Get-WinUtilLabel 'Features' $f) $f $null $f })
    Add-ReviewSection 'Windows features' "$($on.Count + $wf.Count) on$(if ($off) { ", $($off.Count) off" })" $rows @('featuresOn', 'featuresOff', 'wuFeatures')

    $tw = Get-Pairs $Config.tweaks
    $rows = @(foreach ($p in $tw) {
            $t = $TweakCatalog[$p.Name]
            $label = if ($t) { $t.Label } else { $p.Name }
            if ($p.Value) { New-ReviewRow 'tweaks' $label $p.Name $null $(if ($t) { $t.Description }) }
            else { New-ReviewRow 'tweaksUndo' "Undo: $label" $p.Name $null $(if ($t) { $t.Description }) }
        })
    $wt = @($Config.winutil.tweaks | Where-Object { $_ })
    $rows += @(foreach ($k in $wt) { New-ReviewRow 'wuTweaks' (Get-WinUtilLabel 'Tweaks' $k) $k $null "WinUtil: $k" })
    $tg = Get-Pairs $Config.winutil.toggles
    $rows += @(foreach ($p in $tg) { New-ReviewRow 'wuToggles' "$(Get-WinUtilLabel 'Tweaks' $p.Name): $(if ($p.Value) { 'on' } else { 'off' })" $p $null "WinUtil: $($p.Name)" })
    $ch = Get-Pairs $Config.winutil.choices
    $rows += @(foreach ($p in $ch) { New-ReviewRow 'wuChoices' "$(Get-WinUtilLabel 'Tweaks' $p.Name): $($p.Value)" $p $null })
    Add-ReviewSection 'Windows settings' "$($tw.Count + $wt.Count + $tg.Count + $ch.Count) settings" $rows @('tweaks', 'tweaksUndo', 'wuTweaks', 'wuToggles', 'wuChoices')

    $rows = @()
    if ($Config.updates) { $rows += New-ReviewRow 'updates' $(if ($UpdateLabels[[string]$Config.updates]) { $UpdateLabels[[string]$Config.updates] } else { "Windows Update: $($Config.updates)" }) ([string]$Config.updates) $null }
    if ($Config.dns) { $rows += New-ReviewRow 'dns' 'DNS provider:' $null $Config.dns 'Default, DHCP, Fastest, Google, Cloudflare, Quad9, ...' }
    $act = @($Config.winutil.actions | Where-Object { $_ })
    $rows += @(foreach ($k in $act) { New-ReviewRow 'wuActions' (Get-WinUtilLabel 'Features' $k) $k $null $k })
    Add-ReviewSection 'Updates, network and fixes' "$($rows.Count) items" $rows @('updates', 'dns', 'wuActions')

    $rm = @($Config.removeApps | Where-Object { $_ })
    $rows = @(foreach ($r in $rm) { New-ReviewRow 'removeApps' $(if ($BuiltInAppCatalog.Contains($r)) { $BuiltInAppCatalog[$r] } else { $r }) $r $null $r })
    Add-ReviewSection 'Remove built-in apps' "$($rm.Count) apps" $rows @('removeApps')

    $tpl = @($Config.folderTemplates | Where-Object { $_ })
    $fold = @($Config.folders | Where-Object { $_ })
    $rows = @(foreach ($t in $tpl) {
            $label = if ($t -is [string]) { "Template: $($FolderTemplates[$t].Label)" } else { "Template: $($t.label)" }
            $tip = if ($t -is [string]) { $FolderTemplates[$t].Folders -join "`n" } else { @($t.folders) -join "`n" }
            New-ReviewRow 'folderTemplates' $label $t $null $tip
        })
    $rows += @(foreach ($f in $fold) { New-ReviewRow 'folders' '' $null $f })
    $copy = @($Config.copyFolders | Where-Object { $_ })
    $rows += @(foreach ($c in $copy) { New-ReviewRow 'copyFolders' "Copy everything in $($c.source) to" $c $c.destination })
    Add-ReviewSection 'Folders' "$($fold.Count) folders$(if ($tpl) { ", $($tpl.Count) templates" })$(if ($copy) { ", $($copy.Count) copied" })" $rows @('folderTemplates', 'folders', 'copyFolders') 'folders' 'Add a folder'

    $qa = @($Config.quickAccess | Where-Object { $_ })
    $rows = @(foreach ($q in $qa) { New-ReviewRow 'quickAccess' '' $null $q })
    Add-ReviewSection 'Pinned to Quick Access' "$($qa.Count) folders" $rows @('quickAccess') 'quickAccess' 'Pin another folder'

    $sc = @($Config.shortcuts | Where-Object { $_ })
    $rows = @(foreach ($x in $sc) { New-ReviewRow 'shortcuts' "$($x.name)  ->" $x $x.target 'Shortcut on the desktop; edit where it points' })
    $rows += @(foreach ($x in @($Config.removeShortcuts | Where-Object { $_ })) { New-ReviewRow 'removeShortcuts' "Delete $x" $x $null })
    if ($Config.wallpaper) { $rows += New-ReviewRow 'wallpaper' 'Wallpaper:' $null $Config.wallpaper }
    if ($Config.startLayout) { $rows += New-ReviewRow 'startLayout' 'Start menu pins from:' $null $Config.startLayout }
    Add-ReviewSection 'Desktop and Start' "$($sc.Count) shortcuts$(if ($Config.wallpaper) { ', wallpaper' })$(if ($Config.startLayout) { ', Start pins' })" $rows @('shortcuts', 'removeShortcuts', 'wallpaper', 'startLayout')

    $files = @($Config.files | Where-Object { $_ })
    $reg = @($Config.registry | Where-Object { $_ })
    $rows = @(foreach ($f in $files) { New-ReviewRow 'files' "File: $($f.destination)" $f $null $(if ($f.source) { "From $($f.source)" }) })
    $rows += @(foreach ($r in $reg) { New-ReviewRow 'registry' "Registry: $($r.path)\$($r.name) = $($r.value)" $r $null })
    Add-ReviewSection 'Files and registry' "$($files.Count) files, $($reg.Count) values" $rows @('files', 'registry')

    if (-not $script:ReviewItems.Count) {
        [void]$ui.ReviewPanel.Children.Add((New-Text 'Nothing selected yet. Pick a setup above, load a preset, or pick things on the other tabs and click "Use what I picked on the other tabs".' '#8A8FA6' 13))
    }
}

# Turns the ticked review rows back into a preset.
function Get-ReviewPreset {
    $c = [ordered]@{
        restorePoint = [bool]$ui.ReviewRestoreBox.IsChecked
        apps = [ordered]@{ install = @(); upgradeAll = $false }
        removeApps = @(); folderTemplates = @(); folders = @(); copyFolders = @(); quickAccess = @()
        files = @(); shortcuts = @(); removeShortcuts = @(); tweaks = [ordered]@{}; registry = @()
        features = [ordered]@{ enable = @(); disable = @() }
        winutil = [ordered]@{ tweaks = @(); toggles = [ordered]@{}; choices = [ordered]@{}; features = @(); actions = @() }
    }
    foreach ($i in $script:ReviewItems) {
        if (-not $i.Box.IsChecked) { continue }
        $text = if ($i.Text) { $i.Text.Text.Trim() } else { $null }
        if ($i.Text -and -not $text) { continue }
        switch ($i.Key) {
            'apps' { $c.apps.install += , $i.Value }
            'installerRoot' { $c.installerRoot = $text }
            'upgradeAll' { $c.apps.upgradeAll = $true }
            'packageManager' { $c.packageManager = $i.Value }
            'featuresOn' { $c.features.enable += $i.Value }
            'featuresOff' { $c.features.disable += $i.Value }
            'wuFeatures' { $c.winutil.features += $i.Value }
            'tweaks' { $c.tweaks[$i.Value] = $true }
            'tweaksUndo' { $c.tweaks[$i.Value] = $false }
            'wuTweaks' { $c.winutil.tweaks += $i.Value }
            'wuToggles' { $c.winutil.toggles[$i.Value.Name] = [bool]$i.Value.Value }
            'wuChoices' { $c.winutil.choices[$i.Value.Name] = [string]$i.Value.Value }
            'wuActions' { $c.winutil.actions += $i.Value }
            'updates' { $c.updates = $i.Value }
            'dns' { $c.dns = $text }
            'removeApps' { $c.removeApps += $i.Value }
            'folderTemplates' { $c.folderTemplates += , $i.Value }
            'folders' { $c.folders += $text }
            'copyFolders' { $o = $i.Value | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $o.destination = $text; $c.copyFolders += $o }
            'quickAccess' { $c.quickAccess += $text }
            'shortcuts' { $o = $i.Value | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $o.target = $text; $c.shortcuts += $o }
            'removeShortcuts' { $c.removeShortcuts += $i.Value }
            'wallpaper' { $c.wallpaper = $text }
            'startLayout' { $c.startLayout = $text }
            'files' { $c.files += , $i.Value }
            'registry' { $c.registry += , $i.Value }
        }
    }
    $c
}

# Runs a whole preset in the background, exactly like -Run would.
function Start-PresetJob($Config, [bool]$Preview) {
    $json = @{ Config = $Config; BaseDir = $script:LoadedBaseDir } | ConvertTo-Json -Depth 10
    $was = $ui.DryRunBox.IsChecked
    if ($Preview) { $ui.DryRunBox.IsChecked = $true }
    Start-EngineJob '$j = $Job | ConvertFrom-Json; Invoke-Preset $j.Config $j.BaseDir' $json
    $ui.DryRunBox.IsChecked = $was
}

function Start-Review([bool]$Preview) { Start-PresetJob (Get-ReviewPreset) $Preview }

function Import-PresetDialog {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Preset (*.json)|*.json'
    if ($dlg.ShowDialog()) {
        try {
            $cfg = ConvertFrom-WinUtilExport (Get-Content -Path $dlg.FileName -Raw | ConvertFrom-Json)
            Set-SelectionFromPreset $cfg (Split-Path -Parent $dlg.FileName) (Split-Path -Leaf $dlg.FileName)
            $ui.Tabs.SelectedIndex = 0
            $sync.LogQueue.Enqueue("Loaded preset $($dlg.FileName). Check the Vector Contour tab, then go.")
        }
        catch { $sync.LogQueue.Enqueue("Could not read preset: $($_.Exception.Message)") }
    }
}

# Company setups offered on the first tab. Loaded from the presets folder next to the
# script when there is one, otherwise from GitHub (so the one-liner always gets the latest).
function Get-PresetLocation([string]$File) {
    $dir = if ($PSCommandPath) { Join-Path (Split-Path -Parent $PSCommandPath) 'presets' } else { $null }
    if ($dir -and (Test-Path (Join-Path $dir $File))) { return Join-Path $dir $File }
    "$RepoRaw/presets/$File"
}

function Open-CompanyPreset([string]$Label) {
    if (-not $CompanyPresets.Contains($Label)) { return }
    $entry = $CompanyPresets[$Label]
    if (-not $entry) {
        $script:LoadedPreset = $null
        $script:LoadedBaseDir = $null
        Build-Review ([pscustomobject](Get-SelectionPreset)) $Label
        return
    }
    try {
        $loaded = Read-Preset (Get-PresetLocation $entry)
        Set-SelectionFromPreset $loaded.Config $loaded.BaseDir $Label
        $sync.LogQueue.Enqueue("Loaded the '$Label' setup.")
    }
    catch {
        $sync.LogQueue.Enqueue("Could not load the '$Label' setup: $($_.Exception.Message)")
        Build-Review ([pscustomobject]@{}) $Label
    }
}

# --- Wire up buttons ---

$ui.ClearLogBtn.Add_Click({ $ui.LogBox.Clear() })

$ui.AppSearch.Add_TextChanged({ Update-AppFilter })
$ui.FossOnlyBox.Add_Click({ Update-AppFilter })
$ui.ExpandAppsBtn.Add_Click({ foreach ($e in $appExpanders) { $e.IsExpanded = $true } })
$ui.CollapseAppsBtn.Add_Click({ foreach ($e in $appExpanders) { $e.IsExpanded = $false } })
$ui.AppsNoneBtn.Add_Click({ Set-Checked $appBoxes @(); Update-AppCount })

$ui.InstallBtn.Add_Click({
        $apps = Get-CheckedApps
        if (-not $apps) { $sync.LogQueue.Enqueue('Tick some apps first.'); return }
        # Round-trip through JSON so custom apps reach the runspace as plain data.
        $root = if ($script:LoadedPreset) { $script:LoadedPreset.installerRoot } else { $null }
        $json = @{ Apps = @($apps); BaseDir = $script:LoadedBaseDir; Root = $root; Manager = (Get-PackageManager) } | ConvertTo-Json -Depth 6
        Start-EngineJob '$j = $Job | ConvertFrom-Json; Install-Apps @($j.Apps) $j.BaseDir $j.Root $j.Manager -Upgrade' $json
    })

$ui.UninstallBtn.Add_Click({
        $ids = @(Get-Checked $appBoxes | Where-Object { $_ -notlike 'custom:*' -and $_ -notlike 'direct:*' })
        if (-not $ids) { $sync.LogQueue.Enqueue('Tick the apps to uninstall first.'); return }
        $answer = [System.Windows.MessageBox]::Show("Uninstall $($ids.Count) app(s)?", $AppName, 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        Start-EngineJob 'Uninstall-Apps $Job.Ids $Job.Manager' @{ Ids = $ids; Manager = (Get-PackageManager) }
    })

$ui.UpgradeBtn.Add_Click({ Start-EngineJob 'Update-AllApps' $null })
$ui.UpdAppsBtn.Add_Click({ Start-EngineJob 'Update-AllApps' $null })

$ui.GetInstalledBtn.Add_Click({
        $sync.LogQueue.Enqueue('Looking up installed apps (takes a moment)...')
        $sync.Installed = $null
        Start-EngineJob '$sync.Installed = @(Get-InstalledPackageIds $Job)' (Get-PackageManager) {
            $ids = @($sync.Installed)
            if ((Get-PackageManager) -eq 'choco') { $ids = @($ids | ForEach-Object { if ($chocoToTag.ContainsKey($_)) { $chocoToTag[$_] } }) }
            $hit = @($appBoxes | Where-Object { $ids -contains [string]$_.Tag })
            Set-Checked $appBoxes @($hit | ForEach-Object { [string]$_.Tag })
            Update-AppCount
            $sync.LogQueue.Enqueue("$($hit.Count) apps from the list are installed; they are now ticked (Install / upgrade updates them, Uninstall removes them).")
        }
    })

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

# Tweaks
function Select-WinUtilPreset([string]$Name) {
    if (-not $WinUtil -or -not $WinUtil.Presets.$Name) { return }
    Set-Checked $wuTweakBoxes @($WinUtil.Presets.$Name)
}
$ui.TweakStandardBtn.Add_Click({ Select-WinUtilPreset 'Standard' })
$ui.TweakMinimalBtn.Add_Click({ Select-WinUtilPreset 'Minimal' })
$ui.TweakAdvancedBtn.Add_Click({ Select-WinUtilPreset 'Advanced' })
$ui.TweaksNoneBtn.Add_Click({ Set-Checked $tweakBoxes @(); Set-Checked $wuTweakBoxes @() })
$ui.RecommendedBtn.Add_Click({
        Set-Checked $tweakBoxes @($TweakCatalog.Keys | Where-Object { $TweakCatalog[$_].Recommended })
    })

function Start-TweakJob([bool]$Apply) {
    $mine = Get-Checked $tweakBoxes
    $theirs = Get-Checked $wuTweakBoxes
    if (-not $mine -and -not $theirs) { $sync.LogQueue.Enqueue('Tick some tweaks first.'); return }
    $table = @{}
    foreach ($k in $mine) { $table[$k] = $Apply }
    $restore = $ui.RestorePointBox.IsChecked -and $theirs -notcontains 'WPFTweaksRestorePoint'
    $cmd = "$(if ($restore) { 'New-RestorePoint; ' })Set-Tweaks `$Job.Mine; Invoke-WinUtilTweaks `$Job.Theirs $(if ($Apply) { '$false' } else { '$true' })"
    Start-EngineJob $cmd @{ Mine = $table; Theirs = @($theirs) }
}
$ui.ApplyTweaksBtn.Add_Click({ Start-TweakJob $true })
$ui.UndoTweaksBtn.Add_Click({ Start-TweakJob $false })

$ui.UltPerfOnBtn.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions WPFAddUltPerf' $null })
$ui.UltPerfOffBtn.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions WPFRemoveUltPerf' $null })
$ui.OosuBtn.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions WPFOOSUbutton' $null })
$ui.DnsApplyBtn.Add_Click({
        $d = [string]$ui.DnsBox.SelectedItem
        if (-not $d -or $d -eq 'Default') { $sync.LogQueue.Enqueue('Default leaves DNS as it is. Pick a provider, or DHCP to go back to automatic.'); return }
        Start-EngineJob 'Set-DnsProvider $Job' $d
    })
$ui.MpoApplyBtn.Add_Click({ Start-EngineJob 'Set-WinUtilChoice WPFMultiplaneOverlay $Job' ([string]$ui.MpoBox.SelectedItem) })

$ui.RemoveAppsBtn.Add_Click({
        $names = Get-Checked $bloatBoxes
        if (-not $names) { $sync.LogQueue.Enqueue('Tick some built-in apps first.'); return }
        Start-EngineJob 'Remove-BuiltInApps $Job' $names
    })
$ui.BloatDefaultBtn.Add_Click({
        $list = @()
        if ($WinUtil -and $WinUtil.Presets.AppxDefault) { $list = @($WinUtil.Presets.AppxDefault | ForEach-Object { ($_ -replace '^WPFAppx', '') -replace '_', '.' }) }
        Set-Checked $bloatBoxes $list
    })

# Config
$ui.WuFeatureBtn.Add_Click({
        $f = Get-Checked $wuFeatureBoxes
        if (-not $f) { $sync.LogQueue.Enqueue('Tick some features first.'); return }
        Start-EngineJob 'Invoke-WinUtilFeatures $Job' $f
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

# Updates
$ui.UpdDefaultBtn.Add_Click({ Start-EngineJob 'Set-UpdatePolicy default' $null })
$ui.UpdSecurityBtn.Add_Click({ Start-EngineJob 'Set-UpdatePolicy security' $null })
$ui.UpdDisableBtn.Add_Click({
        $answer = [System.Windows.MessageBox]::Show("This stops all Windows updates, including security fixes, until you choose Default settings again.`n`nTurn off updates?", $AppName, 'YesNo', 'Warning')
        if ($answer -eq 'Yes') { Start-EngineJob 'Set-UpdatePolicy disable' $null }
    })
$ui.UpdScanBtn.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions UpdateScan' $null })
$ui.UpdRepairBtn.Add_Click({ Start-EngineJob 'Invoke-WinUtilActions WPFFixesUpdate' $null })

# Folders
$ui.CreateFoldersBtn.Add_Click({
        $folders = @($ui.FolderBox.Text -split "`r?`n" | Where-Object { $_.Trim() })
        $job = @{ Templates = @(Get-Checked $templateBoxes); Folders = $folders; Pin = [bool]$ui.PinFoldersBox.IsChecked }
        Start-EngineJob 'foreach ($t in $Job.Templates) { Invoke-FolderTemplate $t }; New-Folders $Job.Folders; if ($Job.Pin) { Add-QuickAccess $Job.Folders }' $job
    })

# Run everything: round-trip through JSON so it behaves exactly like a saved preset.
$ui.RunAllBtn.Add_Click({ Start-PresetJob (Get-SelectionPreset) $false })

$ui.ExportBtn.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Preset (*.json)|*.json'
        $dlg.FileName = 'my-pc.json'
        if ($dlg.ShowDialog()) {
            Get-SelectionPreset | ConvertTo-Json -Depth 8 | Set-Content -Path $dlg.FileName -Encoding UTF8
            $sync.LogQueue.Enqueue("Saved preset to $($dlg.FileName)")
        }
    })

$ui.ImportBtn.Add_Click({ Import-PresetDialog })
$ui.ReviewLoadBtn.Add_Click({ Import-PresetDialog })
$ui.GoBtn.Add_Click({ Start-Review $false })
$ui.PreviewBtn.Add_Click({ Start-Review $true })
$ui.ReviewFromTabsBtn.Add_Click({ Build-Review ([pscustomobject](Get-SelectionPreset)) 'your selections' })
$ui.ReviewExpandBtn.Add_Click({
        $open = $ui.ReviewExpandBtn.Content -eq 'Show all details'
        foreach ($e in $script:ReviewExpanders) { $e.IsExpanded = $open }
        $ui.ReviewExpandBtn.Content = if ($open) { 'Hide details' } else { 'Show all details' }
    })

# --- Start ---

Set-Checked $tweakBoxes @($TweakCatalog.Keys | Where-Object { $TweakCatalog[$_].Recommended })
Update-AppCount
Update-UpdateState

foreach ($k in $CompanyPresets.Keys) { [void]$ui.CompanyPresetBox.Items.Add($k) }
if ($Preset) {
    try {
        $loaded = Read-Preset $Preset
        Set-SelectionFromPreset $loaded.Config $loaded.BaseDir ([IO.Path]::GetFileName($Preset))
        $sync.LogQueue.Enqueue("Loaded preset $Preset")
    }
    catch { $sync.LogQueue.Enqueue("Could not read preset: $($_.Exception.Message)") }
}
else {
    # The company setup is the default: open the tool and press the green button.
    $ui.CompanyPresetBox.SelectedIndex = 0
    Open-CompanyPreset ([string]$ui.CompanyPresetBox.SelectedItem)
}
$ui.CompanyPresetBox.Add_SelectionChanged({ Open-CompanyPreset ([string]$ui.CompanyPresetBox.SelectedItem) })

$sync.LogQueue.Enqueue("$AppName $AppVersion ready. Running as administrator. WinUtil catalog: $wuSource.")
[void]$window.ShowDialog()
$timer.Stop()
