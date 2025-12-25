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

        $errDesc = $null
        $remediation = $null
        $cm = $null
        try { $cm = [int]$d.ConfigManagerErrorCode } catch { $cm = $null }

        switch ($cm) {
            0 { $errDesc = 'OK'; $remediation = $null }
            1 { $errDesc = 'Device is not configured correctly'; $remediation = 'Reinstall the device driver or run Windows Update / OEM updates' }
            10 { $errDesc = 'This device cannot start'; $remediation = 'Reinstall/update the driver; check firmware/BIOS; power-cycle the device' }
            18 { $errDesc = 'Reinstall the drivers for this device'; $remediation = 'Reinstall the device driver' }
            19 { $errDesc = 'Windows cannot start this hardware device because its configuration information is incomplete or damaged'; $remediation = 'Reinstall the driver; remove the device and rescan' }
            22 { $errDesc = 'This device is disabled'; $remediation = 'Enable the device in Device Manager' }
            24 { $errDesc = 'This device is not present, not working properly, or does not have all its drivers installed'; $remediation = 'Reconnect the device or install the driver' }
            28 { $errDesc = 'The drivers for this device are not installed'; $remediation = 'Install the correct driver for this device' }
            31 { $errDesc = 'This device is not working properly because Windows cannot load the drivers required for this device'; $remediation = 'Reinstall/update the driver' }
            32 { $errDesc = 'A driver (service) for this device has been disabled'; $remediation = 'Enable the driver service or reinstall the driver' }
            37 { $errDesc = 'Windows cannot initialize the device driver for this hardware'; $remediation = 'Reinstall/update the driver' }
            43 { $errDesc = 'Windows has stopped this device because it has reported problems'; $remediation = 'Update/reinstall the driver; unplug/replug; check hardware' }
            default {
                if ($null -ne $cm) {
                    $errDesc = "Device Manager error code $cm"
                    $remediation = 'Review Device Manager details; reinstall/update the driver; check hardware connections'
                }
            }
        }

        [pscustomobject]@{
            Status = $d.Status
            Class = $d.Class
            FriendlyName = $d.FriendlyName
            InstanceId = $d.InstanceId
            Problem = $d.Problem
            ConfigManagerErrorCode = $d.ConfigManagerErrorCode
            ErrorDescription = $errDesc
            Remediation = $remediation
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


