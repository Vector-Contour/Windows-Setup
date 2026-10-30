<#
.SYNOPSIS
    Compares two snapshots from capture-state.ps1 and writes a readable report.

.DESCRIPTION
    Shows everything that changed between a "before" and an "after" snapshot:
    apps installed or removed, built-in apps removed, optional features,
    services, scheduled tasks, startup items, registry values, folders,
    app config files, pins, power/region/default-app settings.

    Writes a folder containing:
      report.md              the readable report (upload this)
      suggested-preset.json  the changes in the setup tool's preset format
      changes.json           every change, machine-readable
    and zips it for upload. Read-only: nothing on the PC is changed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\compare-state.ps1 -Before .\snapshot-before-... -After .\snapshot-after-...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,
    [string]$OutputDir,
    # Also list registry values that look automatic (timestamps, counters, caches).
    [switch]$IncludeNoise,
    # Copy the new or changed app config files from this PC into the report folder,
    # so they can be shipped with the tool. Check them for passwords or tokens first.
    [switch]$CollectChangedFiles,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

function Open-Snapshot([string]$Path) {
    # A wildcard like .\snapshot-before-* matches both the folder and its zip.
    $found = @(Resolve-Path $Path | ForEach-Object { $_.Path })
    $dirs = @($found | Where-Object { Test-Path $_ -PathType Container })
    $pick = @(if ($dirs.Count) { $dirs } else { $found })
    if ($pick.Count -gt 1) { throw "'$Path' matches more than one snapshot. Give the full folder name:`n  $($pick -join "`n  ")" }
    $p = $pick[0]
    if ($p -like '*.zip') {
        $dest = Join-Path $env:TEMP ('snap-' + [IO.Path]::GetFileNameWithoutExtension($p))
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Expand-Archive -LiteralPath $p -DestinationPath $dest -Force
        return $dest
    }
    return $p
}
$B = Open-Snapshot $Before
$A = Open-Snapshot $After

function Read-Json([string]$Dir, [string]$Name) {
    $f = Join-Path $Dir $Name
    if (-not (Test-Path $f)) { return $null }
    $raw = Get-Content $f -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return @() }
    # Enumerate so arrays come back as arrays in Windows PowerShell 5.1.
    return @(foreach ($i in (ConvertFrom-Json $raw)) { $i })
}
function Read-JsonObject([string]$Dir, [string]$Name) {
    $f = Join-Path $Dir $Name
    if (-not (Test-Path $f)) { return $null }
    return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$sysB = Read-JsonObject $B 'system.json'
$sysA = Read-JsonObject $A 'system.json'
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path $A -Parent) ("report-$($sysA.ComputerName)-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Profile paths differ between PCs, so show them as %USERPROFILE%.
$ProfileB = if ($sysB.UserProfile) { $sysB.UserProfile } else { $env:USERPROFILE }
$ProfileA = if ($sysA.UserProfile) { $sysA.UserProfile } else { $env:USERPROFILE }
function ConvertTo-Portable([string]$Path) {
    if (-not $Path) { return $Path }
    foreach ($pr in @($ProfileA, $ProfileB)) {
        if ($pr -and $Path.StartsWith($pr, [StringComparison]::OrdinalIgnoreCase)) {
            return '%USERPROFILE%' + $Path.Substring($pr.Length)
        }
    }
    return $Path
}

# Generic keyed diff. Returns Added, Removed and Changed lists.
function Compare-Keyed($Old, $New, [scriptblock]$Key, [scriptblock]$Value) {
    $o = @{}; $n = @{}
    foreach ($i in @($Old)) { if ($null -ne $i) { $o[(& $Key $i)] = $i } }
    foreach ($i in @($New)) { if ($null -ne $i) { $n[(& $Key $i)] = $i } }
    $added = @(); $removed = @(); $changed = @()
    foreach ($k in $n.Keys) {
        if (-not $o.ContainsKey($k)) { $added += $n[$k] }
        elseif ($Value) {
            $ov = & $Value $o[$k]; $nv = & $Value $n[$k]
            if ($ov -ne $nv) { $changed += [pscustomobject]@{ Key = $k; Before = $ov; After = $nv; Item = $n[$k] } }
        }
    }
    foreach ($k in $o.Keys) { if (-not $n.ContainsKey($k)) { $removed += $o[$k] } }
    [pscustomobject]@{ Added = $added; Removed = $removed; Changed = ($changed | Sort-Object Key) }
}

# ---------------------------------------------------------------- report writer
$md = New-Object Collections.Generic.List[string]
function Add-Line([string]$Text = '') { $md.Add($Text) }
function Esc([string]$Text, [int]$Max = 140) {
    if ($null -eq $Text) { return '' }
    $t = [string]$Text -replace '\|', '\|' -replace "[`r`n]+", ' '
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    return $t
}
function Add-Table([string[]]$Headers, $Rows) {
    $Rows = @($Rows)
    # A single row arrives unrolled; wrap it back up.
    if ($Rows.Count -and -not ($Rows[0] -is [array])) { $Rows = , $Rows }
    if (-not $Rows.Count) { Add-Line '_No changes._'; Add-Line; return }
    Add-Line ('| ' + ($Headers -join ' | ') + ' |')
    Add-Line ('|' + (($Headers | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) { Add-Line ('| ' + ((@($r) | ForEach-Object { Esc $_ }) -join ' | ') + ' |') }
    Add-Line
}

$summary = [ordered]@{}
$changes = [ordered]@{}
$preset = [ordered]@{
    restorePoint = $true
    apps = [ordered]@{ install = @(); upgradeAll = $true }
    removeApps = @()
    folders = @()
    quickAccess = @()
    tweaks = [ordered]@{}
    registry = @()
    features = [ordered]@{ enable = @(); disable = @() }
    _notYetInTool = [ordered]@{}
}

# ---------------------------------------------------------------- apps
function Get-WingetIds([string]$Dir) {
    $j = Read-JsonObject $Dir 'apps-winget.json'
    if (-not $j) { return $null }
    $ids = foreach ($s in @($j.Sources)) {
        foreach ($p in @($s.Packages)) {
            [pscustomobject]@{ Id = $p.PackageIdentifier; Version = $p.Version; Source = $s.SourceDetails.Name }
        }
    }
    return @($ids)
}
$wB = Get-WingetIds $B; $wA = Get-WingetIds $A
$winget = Compare-Keyed $wB $wA { param($i) $i.Id } $null
$prog = Compare-Keyed (Read-Json $B 'apps-programs.json') (Read-Json $A 'apps-programs.json') { param($i) "$($i.Name)" } { param($i) "$($i.Version)" }
$appx = Compare-Keyed (Read-Json $B 'appx-user.json') (Read-Json $A 'appx-user.json') { param($i) $i.Name } $null
$prov = Compare-Keyed (Read-Json $B 'appx-provisioned.json') (Read-Json $A 'appx-provisioned.json') { param($i) $i.DisplayName } $null

$preset.apps.install = @($winget.Added | ForEach-Object { $_.Id } | Sort-Object)
$preset.removeApps = @($appx.Removed | ForEach-Object { $_.Name } | Sort-Object)
$changes.wingetAdded = $winget.Added; $changes.wingetRemoved = $winget.Removed
$changes.programsAdded = $prog.Added; $changes.programsRemoved = $prog.Removed
$changes.appxAdded = $appx.Added; $changes.appxRemoved = $appx.Removed; $changes.provisionedRemoved = $prov.Removed
$summary['Apps installed (winget)'] = @($winget.Added).Count
$summary['Programs added (Programs and Features)'] = @($prog.Added).Count
$summary['Built-in apps removed'] = @($appx.Removed).Count

# Programs that appeared but have no winget match: candidates for direct downloads.
$wingetNames = @($winget.Added | ForEach-Object { ($_.Id -split '\.')[-1] })
$noWinget = @($prog.Added | Where-Object {
    $n = $_.Name -replace '\s', ''
    -not ($wingetNames | Where-Object { $_ -and $n -like "*$_*" })
})

# ---------------------------------------------------------------- features, services, tasks, startup
$feat = Compare-Keyed (Read-Json $B 'features.json') (Read-Json $A 'features.json') { param($i) $i.FeatureName } { param($i) $i.State }
foreach ($c in $feat.Changed) {
    if ($c.After -eq 'Enabled') { $preset.features.enable += $c.Key }
    elseif ($c.After -like 'Disabled*') { $preset.features.disable += $c.Key }
}
$caps = Compare-Keyed (Read-Json $B 'capabilities.json') (Read-Json $A 'capabilities.json') { param($i) $i.Name } { param($i) $i.State }
$svc = Compare-Keyed (Read-Json $B 'services.json') (Read-Json $A 'services.json') { param($i) $i.Name } { param($i) $i.StartMode }
$svcState = Compare-Keyed (Read-Json $B 'services.json') (Read-Json $A 'services.json') { param($i) $i.Name } { param($i) $i.State }
$task = Compare-Keyed (Read-Json $B 'scheduled-tasks.json') (Read-Json $A 'scheduled-tasks.json') { param($i) $i.Task } { param($i) $i.State }
$start = Compare-Keyed (Read-Json $B 'startup.json') (Read-Json $A 'startup.json') { param($i) "$($i.Location)|$($i.Name)" } { param($i) $i.Command }
$envv = Compare-Keyed (Read-Json $B 'environment.json') (Read-Json $A 'environment.json') { param($i) "$($i.Scope):$($i.Name)" } { param($i) $i.Value }

$changes.features = $feat; $changes.capabilities = $caps; $changes.services = $svc; $changes.scheduledTasks = $task
$changes.startup = $start; $changes.environment = $envv
$summary['Optional features changed'] = @($feat.Changed).Count
$summary['Windows capabilities changed'] = @($caps.Changed).Count
$summary['Service start types changed'] = @($svc.Changed).Count
$summary['Scheduled tasks enabled/disabled'] = @($task.Changed).Count
$summary['Startup items added/removed'] = @($start.Added).Count + @($start.Removed).Count

$preset._notYetInTool.services = @($svc.Changed | ForEach-Object { [ordered]@{ name = $_.Key; startMode = $_.After; was = $_.Before } })
$preset._notYetInTool.scheduledTasks = @($task.Changed | ForEach-Object { [ordered]@{ task = $_.Key; state = $_.After; was = $_.Before } })
$preset._notYetInTool.capabilities = @($caps.Changed | ForEach-Object { [ordered]@{ name = $_.Key; state = $_.After } })
$preset._notYetInTool.environment = @(
    @($envv.Added) | ForEach-Object { [ordered]@{ scope = $_.Scope; name = $_.Name; value = $_.Value } }
    @($envv.Changed) | ForEach-Object { [ordered]@{ scope = $_.Item.Scope; name = $_.Item.Name; value = $_.After } }
)

# ---------------------------------------------------------------- registry
function Read-Reg([string]$Dir) {
    $h = @{}
    foreach ($f in (Get-ChildItem $Dir -Filter 'reg-*.tsv' -ErrorAction SilentlyContinue)) {
        foreach ($line in [IO.File]::ReadLines($f.FullName)) {
            $p = $line.Split("`t")
            if ($p.Count -lt 4) { continue }
            $h["$($p[0])`t$($p[1])"] = "$($p[2])`t$($p[3])"
        }
    }
    return $h
}
$rB = Read-Reg $B; $rA = Read-Reg $A

# Values Windows and apps update by themselves. Shown separately, not in the preset.
$AutoName = '(?i)(time$|timestamp|lastupdate|^last|last(used|run|write|check|access|seen|modified)|count$|counter|' +
            'cache|session|usage|mru|history$|guid$|seed|nonce|etag|hash$|checksum|position|placement|bounds|' +
            'windowpos|slot|token|uptime|progress|pending|^\{|^S-1-|cookie|serial)'
$AutoPath = '(?i)(\\Explorer\\(Taskband|StuckRects|MMStuckRects|Discardable|HideDesktopIcons\\ClassicStartMenu|' +
            'StartPage2?|FileExts\\[^\\]+\\OpenWith)|\\Bluetooth|\\Shell Extensions\\Cached|\\Store\\|\\Spartan|' +
            '\\CDP\\|\\Holographic|\\SmartActionPlatform|\\UFH|\\WindowsCopilot\\.*State|\\OneDrive\\Accounts|' +
            '\\Microsoft\\Office\\.*\\(Common\\(Roaming|Licensing|Identity|Internet|ExperimentConfigs|ExperimentEcs|' +
            'ServicesManagerCache|Feedback|ClientTelemetry)|Registration)|\\Microsoft\\Edge\\(BLBeacon|ExtensionInstallMeta)|' +
            '\\Policies\\Microsoft\\Cryptography|\\PolicyManager\\current\\device\\(Update|Licensing)|' +
            '\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\\(AutoLogonChecked|LastUsedUsername)|\\WinRT\\|\\UpdateTimes|' +
            '\\Microsoft\\Input\\|\\DirectX\\|\\Speech_OneCore\\|\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\|' +
            '\\Microsoft\\IdentityCRL|\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\(Results|UpdateHistory))'

$regRows = New-Object Collections.Generic.List[object]
foreach ($k in $rA.Keys) {
    if (-not $rB.ContainsKey($k)) { $regRows.Add(@('Added', $k, $null, $rA[$k])) }
    elseif ($rB[$k] -ne $rA[$k]) { $regRows.Add(@('Changed', $k, $rB[$k], $rA[$k])) }
}
foreach ($k in $rB.Keys) { if (-not $rA.ContainsKey($k)) { $regRows.Add(@('Removed', $k, $rB[$k], $null)) } }

$regReal = @(); $regAuto = @()
foreach ($r in $regRows) {
    $path, $name = $r[1].Split("`t")
    $after = if ($r[3]) { $r[3].Split("`t", 2) } else { @($null, $null) }
    $beforeV = if ($r[2]) { $r[2].Split("`t", 2)[1] } else { $null }
    $row = [pscustomobject]@{
        Change = $r[0]; Path = $path; Name = $name; Type = if ($after[0]) { $after[0] } else { $r[2].Split("`t")[0] }
        Before = $beforeV; After = $after[1]
    }
    $auto = ($name -match $AutoName -or $path -match $AutoPath -or "$($row.After)" -like 'len=*' -or "$($row.After)".Length -gt 300)
    if ($auto) { $regAuto += $row } else { $regReal += $row }
}
$regReal = @($regReal | Sort-Object Path, Name)
$regAuto = @($regAuto | Sort-Object Path, Name)
$changes.registry = $regReal; $changes.registryProbablyAutomatic = $regAuto
$summary['Registry values changed (settings)'] = $regReal.Count
$summary['Registry values changed (probably automatic, not in preset)'] = $regAuto.Count

$typeMap = @{ String = 'String'; ExpandString = 'ExpandString'; DWord = 'DWord'; QWord = 'QWord'; MultiString = 'MultiString' }
$regSkipped = @()
foreach ($r in $regReal) {
    if ($r.Change -eq 'Removed') { continue }
    if (-not $typeMap.ContainsKey($r.Type)) { $regSkipped += $r; continue }
    $psPath = $r.Path -replace '^HKCU\\', 'HKCU:\' -replace '^HKLM\\', 'HKLM:\'
    $value = switch ($r.Type) {
        'DWord' { [long]$r.After }
        'QWord' { [long]$r.After }
        'MultiString' { @($r.After -split ' \| ') }
        default { $r.After }
    }
    $preset.registry += [ordered]@{ path = $psPath; name = $r.Name; type = $typeMap[$r.Type]; value = $value }
}
$preset._notYetInTool.registryRemoved = @($regReal | Where-Object { $_.Change -eq 'Removed' } |
    ForEach-Object { [ordered]@{ path = $_.Path; name = $_.Name; was = $_.Before } })
$preset._notYetInTool.registryBinary = @($regSkipped | ForEach-Object { [ordered]@{ path = $_.Path; name = $_.Name; type = $_.Type; value = $_.After } })

# ---------------------------------------------------------------- folders and files
function Read-Tree([string]$Dir) { @(Read-Json $Dir 'tree-profile.json') + @(Read-Json $Dir 'tree-system.json') | Where-Object { $_ } }
$tree = Compare-Keyed (Read-Tree $B) (Read-Tree $A) { param($i) (ConvertTo-Portable $i.Path).ToLower() } $null

# Only report the top-most new folder; count what is inside it.
$newDirs = @($tree.Added | Where-Object { $_.Type -eq 'Dir' } | ForEach-Object { ConvertTo-Portable $_.Path } | Sort-Object)
$topDirs = New-Object Collections.Generic.List[string]
foreach ($d in $newDirs) {
    if (-not ($topDirs | Where-Object { $d.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })) { $topDirs.Add($d) }
}
$newFiles = @($tree.Added | Where-Object { $_.Type -eq 'File' } | ForEach-Object {
    [pscustomobject]@{ Path = (ConvertTo-Portable $_.Path); Size = $_.Size } })
$looseFiles = @($newFiles | Where-Object { $f = $_.Path; -not ($topDirs | Where-Object { $f.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }) })
$goneItems = @($tree.Removed | ForEach-Object { ConvertTo-Portable $_.Path } | Sort-Object)
# Downloads and Desktop contents are usually leftovers, not part of the setup.
$preset.folders = @($topDirs | Where-Object { $_ -notmatch '\\(Downloads|\$Recycle\.Bin)\\' })
$changes.foldersAdded = $topDirs; $changes.filesAdded = $newFiles; $changes.foldersOrFilesRemoved = $goneItems
$summary['Folders created'] = $topDirs.Count
$summary['Files added (profile and C:\)'] = $newFiles.Count

$cfg = Compare-Keyed (Read-Json $B 'config-files.json') (Read-Json $A 'config-files.json') { param($i) $i.Path.ToLower() } { param($i) $i.SHA1 }
$cfgNew = @($cfg.Added | ForEach-Object { [pscustomobject]@{ Change = 'Added'; Path = $_.Path; Size = $_.Size } })
$cfgMod = @($cfg.Changed | ForEach-Object { [pscustomobject]@{ Change = 'Modified'; Path = $_.Item.Path; Size = $_.Item.Size } })
$cfgAll = @($cfgNew + $cfgMod | Sort-Object Path)
$changes.configFiles = $cfgAll
$summary['App config files added or modified'] = $cfgAll.Count

# ---------------------------------------------------------------- pins, misc settings, default apps
$pinB = Read-JsonObject $B 'pins.json'; $pinA = Read-JsonObject $A 'pins.json'
$pinRows = @()
foreach ($prop in 'QuickAccess', 'Taskbar', 'DesktopShortcuts', 'StartLayoutFiles') {
    $ob = @($pinB.$prop); $na = @($pinA.$prop)
    foreach ($x in $na) { if ($x -and $ob -notcontains $x) { $pinRows += , @($prop, 'Added', (ConvertTo-Portable $x)) } }
    foreach ($x in $ob) { if ($x -and $na -notcontains $x) { $pinRows += , @($prop, 'Removed', (ConvertTo-Portable $x)) } }
}
$preset.quickAccess = @($pinRows | Where-Object { $_[0] -eq 'QuickAccess' -and $_[1] -eq 'Added' } | ForEach-Object { $_[2] })
$preset._notYetInTool.taskbarPins = @($pinA.Taskbar)
$changes.pins = $pinRows
$summary['Pins changed (Quick Access, taskbar, desktop, Start)'] = $pinRows.Count

$miscB = Read-JsonObject $B 'settings-misc.json'; $miscA = Read-JsonObject $A 'settings-misc.json'
$miscRows = @()
if ($miscA) {
    foreach ($p in $miscA.PSObject.Properties.Name) {
        $vb = if ($miscB) { ConvertTo-Json -InputObject $miscB.$p -Compress -Depth 4 } else { '' }
        $va = ConvertTo-Json -InputObject $miscA.$p -Compress -Depth 4
        if ($vb -ne $va) { $miscRows += , @($p, $vb, $va) }
    }
}
$changes.otherSettings = $miscRows
$summary['Power, region, network, Defender settings changed'] = $miscRows.Count
if ($miscRows.Count) {
    $preset._notYetInTool.otherSettings = [ordered]@{}
    foreach ($m in $miscRows) { $preset._notYetInTool.otherSettings[$m[0]] = $miscA.($m[0]) }
}

function Read-Assoc([string]$Dir) {
    $f = Join-Path $Dir 'default-apps.xml'
    if (-not (Test-Path $f)) { return @() }
    try { return @(([xml](Get-Content $f -Raw)).DefaultAssociations.Association) } catch { return @() }
}
$assoc = Compare-Keyed (Read-Assoc $B) (Read-Assoc $A) { param($i) $i.Identifier } { param($i) "$($i.ApplicationName) ($($i.ProgId))" }
$changes.defaultApps = $assoc
$summary['Default apps changed'] = @($assoc.Changed).Count + @($assoc.Added).Count
if (@($assoc.Changed).Count + @($assoc.Added).Count) {
    Copy-Item (Join-Path $A 'default-apps.xml') (Join-Path $OutputDir 'default-apps.xml') -ErrorAction SilentlyContinue
    $preset._notYetInTool.defaultAppsXml = 'default-apps.xml (in this report folder)'
}

# ---------------------------------------------------------------- optional: collect changed config files
$collected = @()
if ($CollectChangedFiles) {
    $dest = Join-Path $OutputDir 'files'
    foreach ($c in $cfgAll) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $rel = (ConvertTo-Portable $c.Path) -replace '^%USERPROFILE%', 'USERPROFILE' -replace '^([A-Za-z]):', '$1'
        $target = Join-Path $dest $rel
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $c.Path -Destination $target -Force
        $collected += $rel
    }
}

# ---------------------------------------------------------------- write report.md
Add-Line '# Windows setup capture: what changed'
Add-Line
Add-Line "- **Before:** $($sysB.Label) on $($sysB.ComputerName), $($sysB.CapturedAt)"
Add-Line "- **After:** $($sysA.Label) on $($sysA.ComputerName), $($sysA.CapturedAt)"
Add-Line "- **Windows:** $($sysA.OS) $($sysA.Version) (build $($sysA.Build), $($sysA.Arch)), $($sysA.Manufacturer) $($sysA.Model)"
if ($sysB.Build -ne $sysA.Build) { Add-Line "- **Note:** Windows was updated between snapshots ($($sysB.Build) to $($sysA.Build)), so some changes below come from the update." }
if (-not $sysA.IsAdmin -or -not $sysB.IsAdmin) { Add-Line '- **Note:** a snapshot was taken without administrator rights, so features, provisioned apps and default apps may be missing.' }
Add-Line
Add-Line '## Summary'
Add-Line
Add-Table @('Area', 'Changes') ($summary.GetEnumerator() | ForEach-Object { , @($_.Key, $_.Value) })

Add-Line '## Apps installed with winget'
Add-Table @('winget ID', 'Version') ($winget.Added | Sort-Object Id | ForEach-Object { , @($_.Id, $_.Version) })
if (@($winget.Removed).Count) {
    Add-Line '### Removed (winget)'
    Add-Table @('winget ID') ($winget.Removed | Sort-Object Id | ForEach-Object { , @($_.Id) })
}
Add-Line '## Programs added (Programs and Features)'
Add-Line 'Programs marked "no winget match" may need a direct download entry in the tool.'
Add-Line
Add-Table @('Name', 'Version', 'Publisher', 'Scope', 'Note') ($prog.Added | Sort-Object Name | ForEach-Object {
    , @($_.Name, $_.Version, $_.Publisher, $_.Scope, $(if ($noWinget -contains $_) { 'no winget match' } else { '' })) })
if (@($prog.Removed).Count) {
    Add-Line '### Programs removed'
    Add-Table @('Name', 'Version', 'Publisher') ($prog.Removed | Sort-Object Name | ForEach-Object { , @($_.Name, $_.Version, $_.Publisher) })
}
if (@($prog.Changed).Count) {
    Add-Line '### Programs updated'
    Add-Table @('Name', 'Before', 'After') ($prog.Changed | ForEach-Object { , @($_.Key, $_.Before, $_.After) })
}

Add-Line '## Built-in apps removed'
Add-Table @('Package', 'Version') ($appx.Removed | Sort-Object Name | ForEach-Object { , @($_.Name, $_.Version) })
if (@($prov.Removed).Count) {
    Add-Line '### Removed from the install image too (provisioned)'
    Add-Table @('Package') ($prov.Removed | Sort-Object DisplayName | ForEach-Object { , @($_.DisplayName) })
}
if (@($appx.Added).Count) {
    Add-Line '### Store / Appx apps added'
    Add-Table @('Package', 'Version') ($appx.Added | Sort-Object Name | ForEach-Object { , @($_.Name, $_.Version) })
}

Add-Line '## Optional features'
Add-Table @('Feature', 'Before', 'After') ($feat.Changed | ForEach-Object { , @($_.Key, $_.Before, $_.After) })
Add-Line '## Windows capabilities (optional add-ons)'
Add-Table @('Capability', 'Before', 'After') ($caps.Changed | ForEach-Object { , @($_.Key, $_.Before, $_.After) })

Add-Line '## Services: start type'
Add-Table @('Service', 'Display name', 'Before', 'After') ($svc.Changed | ForEach-Object { , @($_.Key, $_.Item.DisplayName, $_.Before, $_.After) })
if (@($svc.Added).Count) {
    Add-Line '### New services (usually installed by an app)'
    Add-Table @('Service', 'Display name', 'Start') ($svc.Added | Sort-Object Name | ForEach-Object { , @($_.Name, $_.DisplayName, $_.StartMode) })
}

Add-Line '## Scheduled tasks'
Add-Table @('Task', 'Before', 'After') ($task.Changed | ForEach-Object { , @($_.Key, $_.Before, $_.After) })
if (@($task.Added).Count) {
    Add-Line '### New tasks (usually created by an app)'
    Add-Table @('Task', 'State', 'Action') ($task.Added | Sort-Object Task | ForEach-Object { , @($_.Task, $_.State, $_.Action) })
}
if (@($task.Removed).Count) {
    Add-Line '### Tasks deleted'
    Add-Table @('Task') ($task.Removed | Sort-Object Task | ForEach-Object { , @($_.Task) })
}

Add-Line '## Startup items'
$startRows = @(
    @($start.Added) | ForEach-Object { , @('Added', $_.Name, $_.Command, $_.Location) }
    @($start.Removed) | ForEach-Object { , @('Removed', $_.Name, $_.Command, $_.Location) }
)
Add-Table @('Change', 'Name', 'Command', 'Location') $startRows

Add-Line '## Registry settings'
Add-Line 'Values changed in HKCU (your user) and the machine-wide areas captured. These go into `registry` in the suggested preset, and can be grouped into named tweaks in the tool.'
Add-Line
$groups = $regReal | Group-Object Path
foreach ($g in $groups) {
    Add-Line "**$($g.Name)**"
    Add-Line
    Add-Table @('Change', 'Value', 'Type', 'Before', 'After') ($g.Group | ForEach-Object { , @($_.Change, $_.Name, $_.Type, $_.Before, $_.After) })
}
if (-not $regReal.Count) { Add-Line '_No changes._'; Add-Line }

if ($IncludeNoise -and $regAuto.Count) {
    Add-Line '## Registry values that look automatic'
    Add-Line 'Timestamps, counters, window positions, caches and similar. Listed for completeness; check here if a setting seems to be missing above.'
    Add-Line
    Add-Table @('Change', 'Key', 'Value', 'After') ($regAuto | ForEach-Object { , @($_.Change, $_.Path, $_.Name, $_.After) })
} elseif ($regAuto.Count) {
    Add-Line "_$($regAuto.Count) registry values that look automatic (timestamps, counters, caches) are left out of this report but are in changes.json. Run with -IncludeNoise to list them._"
    Add-Line
}

Add-Line '## Environment variables'
$envRows = @(
    @($envv.Added) | ForEach-Object { , @('Added', $_.Scope, $_.Name, '', $_.Value) }
    @($envv.Changed) | ForEach-Object { , @('Changed', $_.Item.Scope, $_.Item.Name, $_.Before, $_.After) }
    @($envv.Removed) | ForEach-Object { , @('Removed', $_.Scope, $_.Name, $_.Value, '') }
)
Add-Table @('Change', 'Scope', 'Name', 'Before', 'After') $envRows

Add-Line '## Power, region, network and security settings'
Add-Table @('Setting', 'Before', 'After') $miscRows

Add-Line '## Default apps'
$assocRows = @(
    @($assoc.Changed) | ForEach-Object { , @($_.Key, $_.Before, $_.After) }
    @($assoc.Added) | ForEach-Object { , @($_.Identifier, '', "$($_.ApplicationName) ($($_.ProgId))") }
)
Add-Table @('Type / protocol', 'Before', 'After') $assocRows

Add-Line '## Pins and shortcuts'
Add-Table @('Where', 'Change', 'Item') $pinRows

Add-Line '## Folders created'
Add-Table @('Folder', 'Items inside') ($topDirs | ForEach-Object {
    $d = $_
    $n = @($newFiles | Where-Object { $_.Path.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase) }).Count
    , @($d, $n) })
Add-Line '## Files added outside new folders'
Add-Table @('File', 'Size') ($looseFiles | Select-Object -First 300 | ForEach-Object { , @($_.Path, $_.Size) })
if ($looseFiles.Count -gt 300) { Add-Line "_...and $($looseFiles.Count - 300) more (see changes.json)._"; Add-Line }
if ($goneItems.Count) {
    Add-Line '## Files and folders removed'
    Add-Table @('Path') ($goneItems | Select-Object -First 200 | ForEach-Object { , @($_) })
}

Add-Line '## App config files added or changed'
Add-Line 'Settings files apps wrote while you configured them. The tool can copy these onto new PCs with `files` in a preset.'
if ($CollectChangedFiles) { Add-Line "Copies are in the files folder of this report ($($collected.Count) files). Check them for passwords or tokens before sharing." }
else { Add-Line 'Re-run compare with -CollectChangedFiles on the reference PC to copy them into the report.' }
Add-Line
Add-Table @('Change', 'File', 'Size') ($cfgAll | ForEach-Object { , @($_.Change, (ConvertTo-Portable $_.Path), $_.Size) })

$md | Set-Content (Join-Path $OutputDir 'report.md') -Encoding UTF8
ConvertTo-Json -InputObject $preset -Depth 8 | Set-Content (Join-Path $OutputDir 'suggested-preset.json') -Encoding UTF8
ConvertTo-Json -InputObject $changes -Depth 6 | Set-Content (Join-Path $OutputDir 'changes.json') -Encoding UTF8
Copy-Item (Join-Path $A 'system.json') (Join-Path $OutputDir 'system-after.json') -ErrorAction SilentlyContinue

$zip = $null
if (-not $NoZip) {
    $zip = "$OutputDir.zip"
    Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -Force
}
Write-Host ''
Write-Host 'Changes found:' -ForegroundColor Cyan
$summary.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-60} {1}' -f $_.Key, $_.Value) }
Write-Host ''
Write-Host "Report:          $(Join-Path $OutputDir 'report.md')" -ForegroundColor Green
Write-Host "Suggested preset: $(Join-Path $OutputDir 'suggested-preset.json')" -ForegroundColor Green
if ($zip) { Write-Host "Zip for upload:  $zip" -ForegroundColor Green }
