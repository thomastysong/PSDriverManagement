#Requires -Version 5.1

function Get-KernelPnp411Internal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartTime,

        [Parameter()]
        [ValidateRange(50, 5000)]
        [int]$MaxEvents = 500
    )

    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'
            Id = 411
            StartTime = $StartTime
        } -ErrorAction SilentlyContinue)

    $events = @($events | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEvents)

    $rows = foreach ($e in $events) {
        $m = $e.Message

        $dev = if ($m -match '^Device\s+(.+?)\s+had a problem starting\.') { $Matches[1] } else { $null }
        $drv = if ($m -match '(?im)Driver Name:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $clsGuid = if ($m -match '(?im)Class GUID:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $svc = if ($m -match '(?im)Service:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $prob = if ($m -match '(?im)Problem:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $pstat = if ($m -match '(?im)Problem Status:\s*(.+)$') { $Matches[1].Trim() } else { $null }

        [pscustomobject]@{
            TimeCreated = $e.TimeCreated.ToString('o')
            DeviceId = $dev
            DriverName = $drv
            ClassGuid = $clsGuid
            Service = $svc
            Problem = $prob
            ProblemStatus = $pstat
        }
    }

    $topDevices = @($rows | Group-Object DeviceId | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
            [pscustomobject]@{ DeviceId = $_.Name; Count = $_.Count }
        })

    $topDrivers = @($rows | Group-Object DriverName | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
            [pscustomobject]@{ DriverName = $_.Name; Count = $_.Count }
        })

    return [pscustomobject]@{
        Count = @($rows).Count
        TopDrivers = $topDrivers
        TopDevices = $topDevices
        Events = @($rows)
    }
}


