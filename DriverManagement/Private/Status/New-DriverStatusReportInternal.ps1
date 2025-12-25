#Requires -Version 5.1

function New-DriverStatusReportInternal {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 1680)]
        [int]$LookbackHours = 24,

        [Parameter()]
        [ValidateRange(50, 5000)]
        [int]$MaxEventsPerChannel = 500,

        [Parameter()]
        [switch]$IncludeDriverInventory
    )

    $now = Get-Date
    $start = $now.AddHours(-1 * $LookbackHours)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

    $pending = Get-PendingRebootStateInternal
    $oemTooling = Get-OemToolingStateInternal
    $devices = Get-PnpNonOkDevicesInternal

    # Scan-only pending update discovery (no installs; may be incomplete if tooling is missing)
    $pendingUpdates = $null
    try { $pendingUpdates = Get-StatusPendingUpdatesInternal -OemTooling $oemTooling } catch { $pendingUpdates = $null }

    $kernelPnp411 = Get-KernelPnp411Internal -StartTime $start -MaxEvents $MaxEventsPerChannel

    $channels = @(
        'Microsoft-Windows-Kernel-PnP/Configuration'
        'Microsoft-Windows-DeviceSetupManager/Admin'
        'Microsoft-Windows-DriverFrameworks-UserMode/Operational'
        'Microsoft-Windows-DriverFrameworks-KernelMode/Operational'
        'System'
    )
    $channelsPresent = foreach ($l in $channels) {
        $x = Get-WinEvent -ListLog $l -ErrorAction SilentlyContinue
        if ($x) {
            [pscustomobject]@{ LogName = $l; Exists = $true; IsEnabled = $x.IsEnabled; RecordCount = $x.RecordCount }
        }
        else {
            [pscustomobject]@{ LogName = $l; Exists = $false; IsEnabled = $null; RecordCount = $null }
        }
    }

    $inventory = $null
    if ($IncludeDriverInventory) {
        $inventory = [pscustomobject]@{
            DriverStore = Get-DriverStoreInventoryInternal
        }
    }

    $health = Get-DriverHealthScoreInternal -NonOkDeviceCount $devices.NonOkCount -KernelPnp411Count $kernelPnp411.Count -IsRebootPending ([bool]$pending.IsRebootPending)

    # Compute machine-readable compliance summary for status mode consumers
    $pendingUpdateCount = 0
    $pendingUpdateItems = @()
    $updateScanErrors = @()
    $providerState = $null

    try { $pendingUpdateItems = @($pendingUpdates.PendingUpdates) } catch { $pendingUpdateItems = @() }
    try { $pendingUpdateCount = @($pendingUpdateItems).Count } catch { $pendingUpdateCount = 0 }
    try { $updateScanErrors = @($pendingUpdates.Errors) } catch { $updateScanErrors = @() }
    try { $providerState = $pendingUpdates.Providers } catch { $providerState = $null }

    $scanIncomplete = $true
    try {
        if ($providerState) {
            $allProviders = @($providerState.PSObject.Properties | ForEach-Object { $_.Value })
            $scanIncomplete = (@($allProviders | Where-Object { $_.Required -and (-not $_.Success) }).Count -gt 0)
        }
    }
    catch { $scanIncomplete = $true }

    $rebootPending = [bool]$pending.IsRebootPending
    $hardwareIssueCount = [int]$devices.NonOkCount
    $errorCount = @($updateScanErrors).Count

    $upToDate = (-not $scanIncomplete) -and (-not $rebootPending) -and ($pendingUpdateCount -eq 0) -and ($hardwareIssueCount -eq 0) -and ($errorCount -eq 0)

    $complianceStatus = [ComplianceStatus]::Unknown
    if ($errorCount -gt 0) {
        $complianceStatus = [ComplianceStatus]::Error
    }
    elseif ($rebootPending -or $scanIncomplete) {
        $complianceStatus = [ComplianceStatus]::Pending
    }
    elseif (($pendingUpdateCount -gt 0) -or ($hardwareIssueCount -gt 0)) {
        $complianceStatus = [ComplianceStatus]::NonCompliant
    }
    else {
        $complianceStatus = [ComplianceStatus]::Compliant
    }

    $complianceMessageParts = New-Object System.Collections.Generic.List[string]
    if ($upToDate) {
        $complianceMessageParts.Add('UpToDate') | Out-Null
    }
    else {
        $complianceMessageParts.Add(("UpdatesPending={0}" -f $pendingUpdateCount)) | Out-Null
        $complianceMessageParts.Add(("HardwareIssues={0}" -f $hardwareIssueCount)) | Out-Null
        if ($rebootPending) { $complianceMessageParts.Add('RebootPending=True') | Out-Null }
        if ($scanIncomplete) { $complianceMessageParts.Add('ScanIncomplete=True') | Out-Null }
        if ($errorCount -gt 0) { $complianceMessageParts.Add(("Errors={0}" -f $errorCount)) | Out-Null }
    }
    $complianceMessage = ($complianceMessageParts -join '; ')

    $report = [pscustomobject]@{
        SchemaVersion = '1.0'
        GeneratedAt = $now.ToString('o')
        Lookback = [pscustomobject]@{
            Hours = $LookbackHours
            StartTime = $start.ToString('o')
            EndTime = $now.ToString('o')
        }
        CorrelationId = $script:CorrelationId
        Host = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Domain = $env:USERDOMAIN
            OS = [pscustomobject]@{
                Caption = $os.Caption
                Version = $os.Version
                BuildNumber = $os.BuildNumber
            }
            BIOS = [pscustomobject]@{
                SMBIOSBIOSVersion = $bios.SMBIOSBIOSVersion
                ReleaseDate = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('o') } else { $null }
            }
            Hardware = [pscustomobject]@{
                Manufacturer = $cs.Manufacturer
                Model = $cs.Model
                SystemSKU = $cs.SystemSKUNumber
            }
        }
        OEM = $oemTooling
        PendingReboot = $pending
        Devices = $devices
        Updates = if ($pendingUpdates) {
            [pscustomobject]@{
                PendingUpdates = @($pendingUpdates.PendingUpdates)
                PendingCount = @($pendingUpdates.PendingUpdates).Count
                Providers = $pendingUpdates.Providers
                Errors = @($pendingUpdates.Errors)
            }
        } else {
            [pscustomobject]@{
                PendingUpdates = @()
                PendingCount = 0
                Providers = $null
                Errors = @([pscustomobject]@{ Provider = 'Status'; Stage = 'Scan'; Message = 'Pending update scan failed to execute.'; Details = @{} })
            }
        }
        DriverSignals = [pscustomobject]@{
            KernelPnp = [pscustomobject]@{
                ProblemStarting411 = $kernelPnp411
            }
            DeviceInstall = [pscustomobject]@{
                ChannelsPresent = @($channelsPresent)
            }
            WUDriver = [pscustomobject]@{
                DriverUpdateEvents = @()
            }
        }
        Inventory = $inventory
        Health = $health
        Compliance = [pscustomobject]@{
            Status = $complianceStatus.ToString()
            UpToDate = $upToDate
            ScanIncomplete = $scanIncomplete
            RebootPending = $rebootPending
            UpdatesPending = $pendingUpdateCount
            HardwareIssues = $hardwareIssueCount
            Errors = $errorCount
            Message = $complianceMessage
        }
    }

    return $report
}


