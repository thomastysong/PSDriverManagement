#Requires -Version 5.1

function Get-DriverStoreInventoryInternal {
    [CmdletBinding()]
    param()

    $p = Get-Command pnputil.exe -ErrorAction SilentlyContinue
    if (-not $p) {
        return [pscustomobject]@{
            Available = $false
            Message = 'pnputil.exe not found'
            Drivers = @()
        }
    }

    $raw = & $p.Source /enum-drivers 2>$null
    $lines = @($raw)
    if (-not $lines -or $lines.Count -lt 5) {
        return [pscustomobject]@{
            Available = $true
            Message = 'No output or insufficient output from pnputil /enum-drivers'
            Drivers = @()
        }
    }

    $drivers = [System.Collections.Generic.List[object]]::new()
    $current = [ordered]@{}

    function Flush-Current {
        param([hashtable]$h)
        if ($h.Count -eq 0) { return }
        $drivers.Add([pscustomobject]@{
                PublishedName = $h.PublishedName
                OriginalName = $h.OriginalName
                ProviderName = $h.ProviderName
                ClassName = $h.ClassName
                ClassGuid = $h.ClassGuid
                DriverVersion = $h.DriverVersion
                DriverDate = $h.DriverDate
                SignerName = $h.SignerName
            }) | Out-Null
        $h.Clear()
    }

    foreach ($line in $lines) {
        if (-not $line -or $line.Trim().Length -eq 0) {
            Flush-Current -h $current
            continue
        }

        if ($line -match '^\s*Published Name\s*:\s*(.+)$') { $current.PublishedName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Original Name\s*:\s*(.+)$') { $current.OriginalName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Provider Name\s*:\s*(.+)$') { $current.ProviderName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Class Name\s*:\s*(.+)$') { $current.ClassName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Class GUID\s*:\s*(.+)$') { $current.ClassGuid = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Signer Name\s*:\s*(.+)$') { $current.SignerName = $Matches[1].Trim(); continue }

        if ($line -match '^\s*Driver Version\s*:\s*(.+)$') {
            $v = $Matches[1].Trim()
            $parts = $v -split '\s+'
            if ($parts.Count -ge 2) {
                $current.DriverDate = $parts[0]
                $current.DriverVersion = $parts[-1]
            }
            else {
                $current.DriverVersion = $v
            }
            continue
        }
    }
    Flush-Current -h $current

    return [pscustomobject]@{
        Available = $true
        Message = 'OK'
        Drivers = @($drivers)
    }
}


