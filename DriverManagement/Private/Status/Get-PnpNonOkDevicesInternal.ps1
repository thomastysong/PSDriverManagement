#Requires -Version 5.1

function Get-PnpNonOkDevicesInternal {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$MaxDevices = 200
    )

    $nonOk = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })

    # Pull all signed drivers once (faster than repeated WMI filters with complex escaping)
    $signed = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
    $signedById = @{}
    foreach ($sd in $signed) {
        if (-not $sd.DeviceID) { continue }
        if (-not $signedById.ContainsKey($sd.DeviceID)) {
            $signedById[$sd.DeviceID] = $sd
        }
    }

    $rows = foreach ($d in ($nonOk | Select-Object -First $MaxDevices)) {
        $sd = $null
        if ($d.InstanceId -and $signedById.ContainsKey($d.InstanceId)) {
            $sd = $signedById[$d.InstanceId]
        }

        [pscustomobject]@{
            Status = $d.Status
            Class = $d.Class
            FriendlyName = $d.FriendlyName
            InstanceId = $d.InstanceId
            Problem = $d.Problem
            ConfigManagerErrorCode = $d.ConfigManagerErrorCode
            DriverProviderName = if ($sd) { $sd.DriverProviderName } else { $null }
            DriverVersion = if ($sd) { $sd.DriverVersion } else { $null }
            DriverDate = if ($sd) { $sd.DriverDate } else { $null }
            InfName = if ($sd) { $sd.InfName } else { $null }
            Manufacturer = if ($sd) { $sd.Manufacturer } else { $null }
        }
    }

    return [pscustomobject]@{
        NonOkCount = $nonOk.Count
        NonOkDevices = @($rows)
    }
}


