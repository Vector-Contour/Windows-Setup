<#
.SYNOPSIS
    Takes a read-only snapshot of how this Windows PC is set up.

.DESCRIPTION
    Records installed apps, built-in (Appx) apps, registry settings, services,
    scheduled tasks, optional features, startup items, folders, app config files,
    Quick Access and taskbar pins, power, region and default-app settings.

    Nothing on the PC is changed. Everything is written to a new folder next to
    this script (or to -OutputRoot), and zipped so it can be uploaded.

    Take one snapshot on a fresh install ("before"), set the PC up the way you
    want it, then take another ("after") and run compare-state.ps1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\capture-state.ps1 -Label before
    powershell -ExecutionPolicy Bypass -File .\capture-state.ps1 -Label after
#>
[CmdletBinding()]
param(
    [string]$Label = 'snapshot',
    [string]$OutputRoot = $PSScriptRoot,
    # How deep to list folders in the user profile and on C:\.
    [int]$FolderDepth = 4,
    # Skip the full HKCU registry walk (much faster, much less detail).
    [switch]$SkipFullHKCU,
    [switch]$NoZip
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Off

if (-not $OutputRoot) { $OutputRoot = (Get-Location).Path }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeLabel = ($Label -replace '[^\w\-]', '_')
$Out = Join-Path $OutputRoot "snapshot-$safeLabel-$env:COMPUTERNAME-$stamp"
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$Log = Join-Path $Out 'capture.log'

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Step([string]$Text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $Log -Value $line
}
function Write-Note([string]$Text) {
    Write-Host "    $Text" -ForegroundColor DarkYellow
    Add-Content -Path $Log -Value "    $Text"
}
function Save-Json($Data, [string]$Name) {
    $path = Join-Path $Out $Name
    if ($null -eq $Data) { $Data = @() }
    ConvertTo-Json -InputObject @($Data) -Depth 6 | Set-Content -Path $path -Encoding UTF8
}
function Invoke-Step([string]$Name, [scriptblock]$Body) {
    Write-Step $Name
    try { & $Body } catch { Write-Note "Failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- registry walk
# Each value becomes one tab-separated line: Path, Name, Type, Value.
# Binary values over 128 bytes are stored as a length and hash.

# Keys that change on their own all the time (recent files, window positions,
# usage counters, caches). They are skipped so the diff shows real settings.
$NoisyKeys = @(
    '\\Bags($|\\)', '\\BagMRU', 'MRU', '\\RecentDocs', '\\UserAssist', '\\TypedPaths', '\\WordWheelQuery',
    '\\ComDlg32', '\\FeatureUsage', '\\SessionInfo', '\\CloudStore\\', '\\Local Settings\\',
    '\\MuiCache', '\\Shell\\BagMRU', '\\Explorer\\StreamMRU', '\\Explorer\\Streams', '\\JumplistData',
    '\\Notifications\\Data', '\\SystemCertificates', '\\IrisService', '\\Diagnostics\\', '\\InstallService',
    '\\DeliveryOptimization\\Usage', '\\Store\\Cache', '\\GameDVR\\', '\\Search\\RecentApps',
    '\\Windows\\CurrentVersion\\Authentication\\LogonUI\\', '\\Ext\\Stats', '\\Internet Settings\\5.0\\Cache',
    '\\SearchSettings\\', '\\TaskManager$', '\\Accessibility\\ATConfig', '\\SettingSync\\', '\\WinTrust\\',
    '\\Explorer\\AutoplayHandlers\\', '\\Explorer\\TWinUI\\', '\\ApplicationFrame\\', '\\CapabilityAccessManager\\ConsentStore\\[^\\]+\\NonPackaged\\',
    '\\LastUsedTime', '\\Microsoft\\Edge\\Stability', '\\Microsoft\\Windows\\CurrentVersion\\Group Policy\\'
)
$NoisyRegex = ($NoisyKeys -join '|')

function Format-RegValue($Value, $Kind) {
    if ($null -eq $Value) { return '' }
    switch ($Kind) {
        'Binary' {
            $bytes = [byte[]]$Value
            if ($bytes.Length -le 128) { return ($bytes | ForEach-Object { $_.ToString('x2') }) -join '' }
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            return "len=$($bytes.Length);sha256=$hash"
        }
        'MultiString' { return (@($Value) -join ' | ') }
        default { return [string]$Value }
    }
}

function Export-RegistryTree {
    param(
        [Microsoft.Win32.RegistryKey]$Hive,
        [string]$HiveName,
        [string[]]$SubPaths,
        [string]$File,
        [switch]$FilterNoise
    )
    $writer = New-Object IO.StreamWriter((Join-Path $Out $File), $true, [Text.Encoding]::UTF8)
    $script:regCount = 0
    $walk = {
        param([Microsoft.Win32.RegistryKey]$Key, [string]$Display)
        if ($FilterNoise -and $Display -match $NoisyRegex) { return }
        try { $names = $Key.GetValueNames() } catch { $names = @() }
        foreach ($n in $names) {
            try {
                $kind = $Key.GetValueKind($n).ToString()
                $val = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $txt = (Format-RegValue $val $kind) -replace "[`t`r`n]", ' '
                $name = if ($n -eq '') { '(Default)' } else { $n }
                $writer.WriteLine("$Display`t$name`t$kind`t$txt")
                $script:regCount++
            } catch { }
        }
        try { $subs = $Key.GetSubKeyNames() } catch { $subs = @() }
        foreach ($s in $subs) {
            try { $child = $Key.OpenSubKey($s, $false) } catch { $child = $null }
            if ($child) {
                & $walk $child "$Display\$s"
                $child.Close()
            }
        }
    }
    foreach ($p in $SubPaths) {
        try { $k = if ($p) { $Hive.OpenSubKey($p, $false) } else { $Hive } } catch { $k = $null }
        if (-not $k) { continue }
        $display = if ($p) { "$HiveName\$p" } else { $HiveName }
        & $walk $k $display
    }
    $writer.Close()
    Write-Note "$($script:regCount) values -> $File"
}

# ---------------------------------------------------------------- start
Write-Step "Snapshot '$Label' -> $Out"
if (-not $IsAdmin) {
    Write-Note 'Not running as administrator: optional features, provisioned apps, default apps'
    Write-Note 'and some HKLM keys will be missing. Re-run from an admin PowerShell for a full snapshot.'
}

Invoke-Step 'System info' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Label        = $Label
        CapturedAt   = (Get-Date).ToString('s')
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        UserProfile  = $env:USERPROFILE
        IsAdmin      = $IsAdmin
        OS           = $os.Caption
        Version      = $cv.DisplayVersion
        Build        = "$($cv.CurrentBuild).$($cv.UBR)"
        Edition      = $cv.EditionID
        Arch         = $env:PROCESSOR_ARCHITECTURE
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        RAMGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Script       = 'capture-state.ps1 v1'
    } | ConvertTo-Json | Set-Content (Join-Path $Out 'system.json') -Encoding UTF8
}

# ---------------------------------------------------------------- apps
Invoke-Step 'Installed apps (winget export)' {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Note 'winget not found (App Installer may still be updating). Skipped.'; return }
    $file = Join-Path $Out 'apps-winget.json'
    & winget export -o $file --include-versions --accept-source-agreements 2>&1 |
        Out-File (Join-Path $Out 'apps-winget-export.log') -Encoding UTF8
    $list = & winget list --accept-source-agreements 2>$null
    $list | Out-File (Join-Path $Out 'apps-winget-list.txt') -Encoding UTF8
}

Invoke-Step 'Installed programs (Programs and Features)' {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = foreach ($r in $roots) {
        Get-ItemProperty $r -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher
                    Scope = if ($r -like 'HKCU*') { 'User' } else { 'Machine' }
                    InstallLocation = $_.InstallLocation; KeyName = $_.PSChildName
                }
            }
    }
    Save-Json ($items | Sort-Object Name -Unique) 'apps-programs.json'
}

Invoke-Step 'Built-in Store apps (Appx)' {
    $appx = Get-AppxPackage | Where-Object { -not $_.IsFramework } |
        Select-Object Name, Version, Publisher, PackageFamilyName, NonRemovable, SignatureKind | Sort-Object Name
    Save-Json $appx 'appx-user.json'
    if ($IsAdmin) {
        $prov = Get-AppxProvisionedPackage -Online | Select-Object DisplayName, Version, PackageName | Sort-Object DisplayName
        Save-Json $prov 'appx-provisioned.json'
    }
}

# ---------------------------------------------------------------- registry
Invoke-Step 'Registry: policies (HKCU + HKLM)' {
    Export-RegistryTree -Hive ([Microsoft.Win32.Registry]::CurrentUser) -HiveName 'HKCU' `
        -SubPaths @('Software\Policies', 'Software\Microsoft\Windows\CurrentVersion\Policies') -File 'reg-policies-hkcu.tsv'
    Export-RegistryTree -Hive ([Microsoft.Win32.Registry]::LocalMachine) -HiveName 'HKLM' `
        -SubPaths @('SOFTWARE\Policies', 'SOFTWARE\WOW6432Node\Policies', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
                    'SOFTWARE\Microsoft\PolicyManager\current') -File 'reg-policies-hklm.tsv'
}

if (-not $SkipFullHKCU) {
    Invoke-Step 'Registry: all of HKCU (your user settings, can take a few minutes)' {
        # Classes is skipped here (file associations live under FileExts\...\UserChoice,
        # which is included) because it is huge and mostly written by installers.
        $hkcu = [Microsoft.Win32.Registry]::CurrentUser
        $top = $hkcu.GetSubKeyNames() | Where-Object { $_ -ne 'Software' }
        $soft = $hkcu.OpenSubKey('Software').GetSubKeyNames() | Where-Object { $_ -ne 'Classes' } | ForEach-Object { "Software\$_" }
        Export-RegistryTree -Hive $hkcu -HiveName 'HKCU' -SubPaths (@($top) + @($soft)) -File 'reg-hkcu.tsv' -FilterNoise
    }
} else {
    Invoke-Step 'Registry: HKCU settings areas' {
        Export-RegistryTree -Hive ([Microsoft.Win32.Registry]::CurrentUser) -HiveName 'HKCU' -SubPaths @(
            'Control Panel', 'Environment', 'Keyboard Layout', 'Printers',
            'Software\Microsoft\Windows\CurrentVersion\Explorer',
            'Software\Microsoft\Windows\CurrentVersion\Search',
            'Software\Microsoft\Windows\CurrentVersion\Themes',
            'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
            'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo',
            'Software\Microsoft\Windows\CurrentVersion\Privacy',
            'Software\Microsoft\Windows\CurrentVersion\PushNotifications',
            'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings',
            'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager',
            'Software\Microsoft\Windows\CurrentVersion\Run',
            'Software\Microsoft\Windows\CurrentVersion\RunOnce',
            'Software\Microsoft\Windows\CurrentVersion\GameDVR',
            'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications',
            'Software\Microsoft\Windows\DWM', 'Software\Microsoft\Clipboard', 'Software\Microsoft\GameBar',
            'Software\Microsoft\InputPersonalization', 'Software\Microsoft\Personalization',
            'Software\Microsoft\Siuf', 'Software\Microsoft\Lighting', 'Software\Microsoft\Narrator',
            'Software\Microsoft\Windows\Shell\Copilot', 'Software\Microsoft\Edge'
        ) -File 'reg-hkcu.tsv' -FilterNoise
    }
}

Invoke-Step 'Registry: machine-wide settings areas (HKLM)' {
    Export-RegistryTree -Hive ([Microsoft.Win32.Registry]::LocalMachine) -HiveName 'HKLM' -SubPaths @(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update',
        'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings',
        'SOFTWARE\Microsoft\Windows\Windows Error Reporting',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State',
        'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
        'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
        'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore',
        'SOFTWARE\Microsoft\Windows Defender\Features',
        'SOFTWARE\Microsoft\Windows Search',
        'SOFTWARE\Microsoft\Dsh',
        'SOFTWARE\Microsoft\PolicyManager\default\Start',
        'SYSTEM\CurrentControlSet\Control\Power',
        'SYSTEM\CurrentControlSet\Control\Session Manager\Power',
        'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
        'SYSTEM\CurrentControlSet\Control\Terminal Server',
        'SYSTEM\CurrentControlSet\Control\FileSystem',
        'SYSTEM\CurrentControlSet\Control\Lsa',
        'SYSTEM\CurrentControlSet\Control\Remote Assistance',
        'SYSTEM\CurrentControlSet\Control\CrashControl',
        'SYSTEM\CurrentControlSet\Control\PriorityControl',
        'SYSTEM\CurrentControlSet\Control\TimeZoneInformation',
        'SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'SYSTEM\CurrentControlSet\Control\Keyboard Layout',
        'SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters',
        'SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters',
        'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces',
        'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    ) -File 'reg-hklm.tsv' -FilterNoise
}

# ---------------------------------------------------------------- system state
Invoke-Step 'Services' {
    $svc = Get-CimInstance Win32_Service | ForEach-Object {
        # Per-user services get a random suffix each logon (e.g. CDPUserSvc_4f2a1).
        $name = $_.Name -replace '_[0-9a-f]{4,8}$', '_*'
        $delayed = $false
        if ($_.StartMode -eq 'Auto') {
            $d = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)" -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
            $delayed = ($d -eq 1)
        }
        [pscustomobject]@{
            Name = $name; DisplayName = $_.DisplayName
            StartMode = if ($delayed) { 'AutoDelayed' } else { $_.StartMode }
            State = $_.State; PathName = $_.PathName
        }
    }
    Save-Json ($svc | Sort-Object Name -Unique) 'services.json'
}

Invoke-Step 'Scheduled tasks' {
    $tasks = Get-ScheduledTask | ForEach-Object {
        $actions = ($_.Actions | ForEach-Object { (("$($_.Execute) $($_.Arguments)").Trim()) }) -join ' ; '
        [pscustomobject]@{ Task = "$($_.TaskPath)$($_.TaskName)"; State = [string]$_.State; Author = $_.Author; Action = $actions }
    }
    Save-Json ($tasks | Sort-Object Task) 'scheduled-tasks.json'
}

Invoke-Step 'Optional features and capabilities' {
    if (-not $IsAdmin) { Write-Note 'Needs administrator. Skipped.'; return }
    $f = Get-WindowsOptionalFeature -Online | Select-Object FeatureName, @{ n = 'State'; e = { [string]$_.State } } | Sort-Object FeatureName
    Save-Json $f 'features.json'
    $c = Get-WindowsCapability -Online | Select-Object Name, @{ n = 'State'; e = { [string]$_.State } } | Sort-Object Name
    Save-Json $c 'capabilities.json'
}

Invoke-Step 'Startup items' {
    $s = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User | Sort-Object Location, Name
    Save-Json $s 'startup.json'
}

Invoke-Step 'Environment variables' {
    $vars = foreach ($scope in 'User', 'Machine') {
        $h = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in $h.Keys) { [pscustomobject]@{ Scope = $scope; Name = $k; Value = $h[$k] } }
    }
    Save-Json ($vars | Sort-Object Scope, Name) 'environment.json'
}

Invoke-Step 'Power, region, language and network settings' {
    $p = [ordered]@{}
    $p.ActivePowerPlan = (& powercfg /getactivescheme) -join ''
    $p.PowerPlans = (& powercfg /list) -join "`n"
    try { $p.Hibernate = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch { }
    $p.TimeZone = (Get-TimeZone).Id
    $p.Culture = (Get-Culture).Name
    $p.UICulture = (Get-UICulture).Name
    try { $p.HomeLocation = (Get-WinHomeLocation).HomeLocation } catch { }
    try { $p.Languages = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) } catch { }
    try { $p.SystemLocale = (Get-WinSystemLocale).Name } catch { }
    try { $p.NetworkProfiles = @(Get-NetConnectionProfile | ForEach-Object { "$($_.InterfaceAlias)=$($_.NetworkCategory)" }) } catch { }
    try { $p.Firewall = @(Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) } catch { }
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $p.Defender = [ordered]@{
            RealTimeDisabled = $mp.DisableRealtimeMonitoring; CloudProtection = $mp.MAPSReporting
            SampleSubmission = $mp.SubmitSamplesConsent; PUAProtection = $mp.PUAProtection
            ExclusionPath = $mp.ExclusionPath; ExclusionProcess = $mp.ExclusionProcess
        }
    } catch { }
    try { $p.RDPEnabled = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0) } catch { }
    try {
        $sr = Get-ComputerRestorePoint -ErrorAction Stop
        $p.RestorePoints = @($sr).Count
    } catch { }
    try { $p.BitLocker = @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object { "$($_.MountPoint)=$($_.ProtectionStatus)" }) } catch { }
    $p.HostsFile = @(Get-Content "$env:windir\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    $p | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out 'settings-misc.json') -Encoding UTF8
}

Invoke-Step 'Default apps (file and link associations)' {
    if ($IsAdmin) {
        & dism /online /Export-DefaultAppAssociations:"$(Join-Path $Out 'default-apps.xml')" | Out-Null
    } else { Write-Note 'Needs administrator for the DISM export; UserChoice keys are still in reg-hkcu.tsv.' }
}

# ---------------------------------------------------------------- files and folders
Invoke-Step 'Pinned items (Quick Access, taskbar, Start)' {
    $pins = [ordered]@{}
    try {
        $shell = New-Object -ComObject Shell.Application
        $qa = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
        $pins.QuickAccess = @($qa.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Path })
    } catch { }
    $tb = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $pins.Taskbar = @(Get-ChildItem $tb -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    $start = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_*\LocalState\start*.bin" -ErrorAction SilentlyContinue
    $pins.StartLayoutFiles = @($start | ForEach-Object { "$($_.Name) $((Get-FileHash $_.FullName).Hash)" })
    $pins.DesktopShortcuts = @(
        Get-ChildItem ([Environment]::GetFolderPath('Desktop')), "$env:PUBLIC\Desktop" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
    $pins | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out 'pins.json') -Encoding UTF8
    if ($start) {
        $dest = Join-Path $Out 'start-layout'
        New-Item -ItemType Directory $dest -Force | Out-Null
        $start | Copy-Item -Destination $dest
    }
}

function Get-Tree([string]$Root, [int]$Depth, [string[]]$Skip) {
    if (-not (Test-Path $Root)) { return }
    Get-ChildItem -LiteralPath $Root -Recurse -Depth ($Depth - 1) -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
            -not ($Skip | Where-Object { $rel -like $_ })
        } |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                Type = if ($_.PSIsContainer) { 'Dir' } else { 'File' }
                Size = if ($_.PSIsContainer) { $null } else { $_.Length }
                Modified = $_.LastWriteTime.ToString('s')
                Attributes = [string]$_.Attributes
            }
        }
}

Invoke-Step "Folder tree: user profile (depth $FolderDepth)" {
    $skip = @('AppData*', 'NTUSER*', 'ntuser*', '*\node_modules*', '*\.git\*', 'OneDrive*\*\*\*', 'MicrosoftEdgeBackups*')
    Save-Json (Get-Tree $env:USERPROFILE $FolderDepth $skip) 'tree-profile.json'
}

Invoke-Step 'Folder tree: C:\ top level (depth 2) and Public' {
    $skip = @('Windows*', 'Program Files*', 'ProgramData*', '$*', 'System Volume Information*', 'Recovery*',
              'pagefile.sys', 'hiberfil.sys', 'swapfile.sys', 'DumpStack*', 'Users*', 'PerfLogs*', 'Config.Msi*')
    $items = @(Get-Tree "$env:SystemDrive\" 2 $skip) + @(Get-Tree $env:PUBLIC 3 @())
    Save-Json $items 'tree-system.json'
}

Invoke-Step 'App config files (AppData, ProgramData and dot-folders)' {
    # Settings files apps write when you configure them, e.g. VS Code settings.json.
    $exts = '.json', '.ini', '.xml', '.cfg', '.conf', '.config', '.yaml', '.yml', '.toml', '.reg', '.plist', '.properties', '.txt'
    $skip = '\\(Cache|Code Cache|GPUCache|cache2|Crashpad|CrashDumps|Logs?|Temp|tmp|IndexedDB|Service Worker|blob_storage|' +
            'Local Storage|Session Storage|WebStorage|shared_proto_db|Packages\\[^\\]+\\(AC|TempState|LocalCache)|' +
            'Microsoft\\Windows\\(INetCache|WebCache|Explorer|Recent|History|Notifications|WER)|D3DSCache|' +
            'node_modules|\.git|extensions\\[^\\]+\\node_modules|Squirrel|SquirrelTemp|Installer)\\'
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, "$env:USERPROFILE\Documents") +
             @(Get-ChildItem $env:USERPROFILE -Directory -Force -Filter '.*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    if ($IsAdmin) { $roots += $env:ProgramData }
    $files = foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        Get-ChildItem -LiteralPath $r -Recurse -Depth 5 -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLower() -and $_.Length -lt 2MB -and $_.FullName -notmatch $skip }
    }
    $rows = foreach ($f in $files) {
        $h = $null
        try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1 -ErrorAction Stop).Hash } catch { }
        [pscustomobject]@{ Path = $f.FullName; Size = $f.Length; Modified = $f.LastWriteTime.ToString('s'); SHA1 = $h }
    }
    Save-Json $rows 'config-files.json'
    Write-Note "$(@($rows).Count) config files listed"
}

# ---------------------------------------------------------------- finish
Write-Step 'Done'
$zip = $null
if (-not $NoZip) {
    $zip = "$Out.zip"
    try {
        Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $zip -Force
    } catch { Write-Note "Could not zip: $($_.Exception.Message)"; $zip = $null }
}
Write-Host ''
Write-Host "Snapshot folder: $Out" -ForegroundColor Green
if ($zip) { Write-Host "Zip for upload:  $zip" -ForegroundColor Green }
Write-Host 'Nothing on this PC was changed.' -ForegroundColor Green
