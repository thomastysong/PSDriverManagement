#Requires -Version 5.1

function Get-DriverHealthScoreInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$NonOkDeviceCount,

        [Parameter(Mandatory)]
        [int]$KernelPnp411Count,

        [Parameter(Mandatory)]
        [bool]$IsRebootPending
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $deviceHealth = 100
    $eventHealth = 100
    $rebootHealth = 100

    if ($NonOkDeviceCount -gt 0) {
        $reasons.Add('PNP_NON_OK_PRESENT') | Out-Null
        $deviceHealth = [Math]::Max(0, 100 - (30 + (($NonOkDeviceCount - 1) * 5)))
    }

    if ($KernelPnp411Count -gt 0) {
        $reasons.Add('KERNEL_PNP_411_PRESENT') | Out-Null
        $eventHealth = [Math]::Max(0, 100 - (40 + (($KernelPnp411Count - 1) * 3)))
        if ($KernelPnp411Count -ge 5) {
            $reasons.Add('REPEATED_PROBLEM_STARTING') | Out-Null
        }
    }

    if ($IsRebootPending) {
        $reasons.Add('REBOOT_PENDING_HEURISTIC') | Out-Null
        $rebootHealth = 60
    }

    $overall = [Math]::Min($deviceHealth, [Math]::Min($eventHealth, $rebootHealth))

    $severity = 'Healthy'
    if (($KernelPnp411Count -ge 10) -or ($NonOkDeviceCount -ge 10)) {
        $severity = 'Critical'
    }
    elseif (($KernelPnp411Count -gt 0) -or ($NonOkDeviceCount -gt 0)) {
        $severity = 'Degraded'
    }
    elseif ($IsRebootPending) {
        $severity = 'Warning'
    }

    return [pscustomobject]@{
        HasIssues = ($severity -ne 'Healthy')
        Severity = $severity
        Reasons = @($reasons)
        Scores = [pscustomobject]@{
            DeviceHealth = $deviceHealth
            EventHealth = $eventHealth
            RebootHealth = $rebootHealth
            Overall = $overall
        }
    }
}


