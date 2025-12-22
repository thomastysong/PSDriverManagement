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
    }

    return $report
}


