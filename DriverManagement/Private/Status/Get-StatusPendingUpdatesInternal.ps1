#Requires -Version 5.1

function Get-StatusPendingUpdatesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$OemTooling,

        [Parameter()]
        [ValidateRange(1, 2000)]
        [int]$MaxPerProvider = 200
    )

    $pending = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $providers = @{}

    function Add-ProviderStateInternal {
        param(
            [string]$Name,
            [bool]$Required,
            [bool]$Available,
            [bool]$Attempted,
            [bool]$Success,
            [string]$SkippedReason,
            [string]$Error,
            [int]$PendingCount
        )
        $providers[$Name] = [pscustomobject]@{
            Name = $Name
            Required = $Required
            Available = $Available
            Attempted = $Attempted
            Success = $Success
            SkippedReason = $SkippedReason
            Error = $Error
            PendingCount = $PendingCount
        }
    }

    function Add-ScanErrorInternal {
        param(
            [string]$Provider,
            [string]$Stage,
            [string]$Message,
            [hashtable]$Details
        )
        $errors.Add([pscustomobject]@{
                Provider = $Provider
                Stage = $Stage
                Message = $Message
                Details = $Details
            }) | Out-Null
    }

    $detected = $null
    try { $detected = [string]$OemTooling.Detected } catch { $detected = 'Other' }

    $oemRequiredProvider = $null
    if ($detected -eq 'Dell') { $oemRequiredProvider = 'Dell' }
    elseif ($detected -eq 'Lenovo') { $oemRequiredProvider = 'Lenovo' }

    #region Dell (scan-only, requires existing DCU)
    $dellRequired = ($oemRequiredProvider -eq 'Dell')
    $dcuPath = $null
    try { $dcuPath = $OemTooling.Dell.DCU.CliPath } catch { $dcuPath = $null }
    if (-not $dcuPath) {
        try { $dcuPath = Get-DellCommandUpdatePath } catch { $dcuPath = $null }
    }

    if (-not $dcuPath -or -not (Test-Path $dcuPath)) {
        Add-ProviderStateInternal -Name 'Dell' -Required:$dellRequired -Available:$false -Attempted:$false -Success:$false -SkippedReason 'ToolMissing' -Error $null -PendingCount 0
        if ($dellRequired) {
            Add-ScanErrorInternal -Provider 'Dell' -Stage 'Prereq' -Message 'Dell Command Update CLI not found; status mode will not auto-install tooling.' -Details @{ CliPath = $dcuPath }
        }
    }
    else {
        $reportPath = Join-Path $env:ProgramData 'Dell\UpdateScan'
        try { if (-not (Test-Path $reportPath)) { New-Item -Path $reportPath -ItemType Directory -Force | Out-Null } } catch { }
        $applicableXml = Join-Path $reportPath 'DCUApplicableUpdates.xml'

        try {
            $scanArgs = @(
                '/scan'
                '-silent'
                "-report=$reportPath"
                "-updateType=driver,bios,firmware,application"
                "-updateSeverity=security,recommended,optional"
            )
            $null = & $dcuPath @scanArgs 2>&1

            $updates = @()
            if (Test-Path $applicableXml) {
                try {
                    [xml]$updatesXml = Get-Content -Path $applicableXml -ErrorAction Stop
                    $nodes = @($updatesXml.updates.update)
                    foreach ($u in ($nodes | Select-Object -First $MaxPerProvider)) {
                        $updates += [pscustomobject]@{
                            Provider = 'Dell'
                            UpdateType = $u.type
                            Title = $u.name
                            Identifier = $u.releaseid
                            InstalledVersion = $null
                            AvailableVersion = $u.version
                            Severity = $u.urgency
                            RebootRequired = $null
                            Source = 'DCUApplicableUpdates.xml'
                        }
                    }
                }
                catch {
                    Add-ScanErrorInternal -Provider 'Dell' -Stage 'Parse' -Message $_.Exception.Message -Details @{ Report = $applicableXml }
                }
            }

            foreach ($x in $updates) { $pending.Add($x) | Out-Null }
            Add-ProviderStateInternal -Name 'Dell' -Required:$dellRequired -Available:$true -Attempted:$true -Success:$true -SkippedReason $null -Error $null -PendingCount @($updates).Count
        }
        catch {
            Add-ProviderStateInternal -Name 'Dell' -Required:$dellRequired -Available:$true -Attempted:$true -Success:$false -SkippedReason $null -Error $_.Exception.Message -PendingCount 0
            Add-ScanErrorInternal -Provider 'Dell' -Stage 'Scan' -Message $_.Exception.Message -Details @{ CliPath = $dcuPath }
        }
    }
    #endregion

    #region Lenovo (scan-only, requires LSUClient already installed)
    $lenovoRequired = ($oemRequiredProvider -eq 'Lenovo')
    $lsuPresent = $false
    try { $lsuPresent = [bool]$OemTooling.Lenovo.LSUClientModulePresent } catch { $lsuPresent = $false }

    if (-not $lsuPresent) {
        Add-ProviderStateInternal -Name 'Lenovo' -Required:$lenovoRequired -Available:$false -Attempted:$false -Success:$false -SkippedReason 'ToolMissing' -Error $null -PendingCount 0
        if ($lenovoRequired) {
            Add-ScanErrorInternal -Provider 'Lenovo' -Stage 'Prereq' -Message 'LSUClient module not installed; status mode will not auto-install tooling.' -Details @{}
        }
    }
    else {
        try {
            Import-Module LSUClient -Force -ErrorAction Stop
            $allUpdates = @()
            try { $allUpdates = @(Get-LSUpdate) } catch { $allUpdates = @() }

            $updates = @()
            foreach ($u in ($allUpdates | Where-Object { $_.Installer.Unattended } | Select-Object -First $MaxPerProvider)) {
                $updates += [pscustomobject]@{
                    Provider = 'Lenovo'
                    UpdateType = $u.Type
                    Title = $u.Title
                    Identifier = $u.ID
                    InstalledVersion = $null
                    AvailableVersion = $u.Version
                    Severity = $u.Severity
                    RebootRequired = (try { [bool]$u.Reboot.Required } catch { $null })
                    Source = 'LSUClient'
                }
            }

            foreach ($x in $updates) { $pending.Add($x) | Out-Null }
            Add-ProviderStateInternal -Name 'Lenovo' -Required:$lenovoRequired -Available:$true -Attempted:$true -Success:$true -SkippedReason $null -Error $null -PendingCount @($updates).Count
        }
        catch {
            Add-ProviderStateInternal -Name 'Lenovo' -Required:$lenovoRequired -Available:$true -Attempted:$true -Success:$false -SkippedReason $null -Error $_.Exception.Message -PendingCount 0
            Add-ScanErrorInternal -Provider 'Lenovo' -Stage 'Scan' -Message $_.Exception.Message -Details @{}
        }
    }
    #endregion

    #region Intel (scan-only, uses existing Get-IntelDriverUpdates)
    $intelDevices = @()
    try { $intelDevices = @(Get-IntelDevices) } catch { $intelDevices = @() }

    if (-not $intelDevices -or $intelDevices.Count -eq 0) {
        Add-ProviderStateInternal -Name 'Intel' -Required:$false -Available:$false -Attempted:$false -Success:$true -SkippedReason 'NoHardware' -Error $null -PendingCount 0
    }
    else {
        try {
            $intelUpdates = @()
            try { $intelUpdates = @(Get-IntelDriverUpdates) } catch { $intelUpdates = @() }

            $updates = @()
            foreach ($u in ($intelUpdates | Select-Object -First $MaxPerProvider)) {
                $updates += [pscustomobject]@{
                    Provider = 'Intel'
                    UpdateType = 'Driver'
                    Title = $u.PackageName
                    Identifier = $u.PackageId
                    InstalledVersion = $u.InstalledVersion
                    AvailableVersion = $u.AvailableVersion
                    Severity = $null
                    RebootRequired = $null
                    DeviceName = $u.DeviceName
                    Category = $u.Category
                    Source = 'IntelDSAFeed'
                }
            }

            foreach ($x in $updates) { $pending.Add($x) | Out-Null }
            Add-ProviderStateInternal -Name 'Intel' -Required:$false -Available:$true -Attempted:$true -Success:$true -SkippedReason $null -Error $null -PendingCount @($updates).Count
        }
        catch {
            Add-ProviderStateInternal -Name 'Intel' -Required:$false -Available:$true -Attempted:$true -Success:$false -SkippedReason $null -Error $_.Exception.Message -PendingCount 0
            Add-ScanErrorInternal -Provider 'Intel' -Stage 'Scan' -Message $_.Exception.Message -Details @{}
        }
    }
    #endregion

    #region Windows Update (driver updates via COM API; no PSWindowsUpdate install)
    try {
        $wu = Get-WindowsUpdatePendingInternal -DriversOnly -MaxUpdates $MaxPerProvider
        $updates = @()
        if ($wu.Success -and $wu.Updates) {
            foreach ($u in @($wu.Updates)) {
                $updates += [pscustomobject]@{
                    Provider = 'WindowsUpdate'
                    UpdateType = 'Driver'
                    Title = $u.Title
                    Identifier = $u.Identifier
                    InstalledVersion = $null
                    AvailableVersion = $u.AvailableVersion
                    Severity = $null
                    RebootRequired = $u.RebootRequired
                    KBArticleIDs = $u.KBArticleIDs
                    DriverManufacturer = $u.DriverManufacturer
                    DriverModel = $u.DriverModel
                    DriverClass = $u.DriverClass
                    Source = 'WUA'
                }
            }
        }
        foreach ($x in ($updates | Select-Object -First $MaxPerProvider)) { $pending.Add($x) | Out-Null }
        Add-ProviderStateInternal -Name 'WindowsUpdate' -Required:$true -Available:$true -Attempted:$true -Success:$wu.Success -SkippedReason $null -Error $wu.Error -PendingCount @($updates).Count
        if (-not $wu.Success) {
            Add-ScanErrorInternal -Provider 'WindowsUpdate' -Stage 'Scan' -Message $wu.Error -Details @{}
        }
    }
    catch {
        Add-ProviderStateInternal -Name 'WindowsUpdate' -Required:$true -Available:$true -Attempted:$true -Success:$false -SkippedReason $null -Error $_.Exception.Message -PendingCount 0
        Add-ScanErrorInternal -Provider 'WindowsUpdate' -Stage 'Scan' -Message $_.Exception.Message -Details @{}
    }
    #endregion

    # NOTE: Avoid `@($pending)` on generic lists; it can trip dynamic binder edge cases in PS 5.1.
    return [pscustomobject]@{
        PendingUpdates = $pending.ToArray()
        Errors = $errors.ToArray()
        Providers = [pscustomobject]$providers
    }
}



