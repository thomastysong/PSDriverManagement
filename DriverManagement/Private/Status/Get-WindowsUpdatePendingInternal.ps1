#Requires -Version 5.1

function Get-WindowsUpdatePendingInternal {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$DriversOnly = $true,

        [Parameter()]
        [ValidateRange(1, 2000)]
        [int]$MaxUpdates = 200
    )

    $out = [pscustomobject]@{
        Attempted = $true
        Success = $false
        Error = $null
        Count = 0
        Updates = @()
    }

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()

        $criteria = "IsInstalled=0 and IsHidden=0"
        if ($DriversOnly) {
            $criteria += " and Type='Driver'"
        }

        $sr = $searcher.Search($criteria)
        $updates = @()

        $total = 0
        try { $total = [int]$sr.Updates.Count } catch { $total = 0 }

        $limit = [Math]::Min($total, $MaxUpdates)
        for ($i = 0; $i -lt $limit; $i++) {
            $u = $sr.Updates.Item($i)

            $id = $null
            $rev = $null
            try {
                $id = $u.Identity.UpdateID
                $rev = $u.Identity.RevisionNumber
            }
            catch { }

            $kb = @()
            try { $kb = @($u.KBArticleIDs) } catch { $kb = @() }

            $driverManufacturer = $null
            $driverModel = $null
            $driverClass = $null
            $driverVerDate = $null
            $driverVerVersion = $null
            try { $driverManufacturer = $u.DriverManufacturer } catch { }
            try { $driverModel = $u.DriverModel } catch { }
            try { $driverClass = $u.DriverClass } catch { }
            try { $driverVerDate = $u.DriverVerDate } catch { }
            try { $driverVerVersion = $u.DriverVerVersion } catch { }

            $rebootRequired = $null
            try { $rebootRequired = [bool]$u.RebootRequired } catch { $rebootRequired = $null }

            $updates += [pscustomobject]@{
                Title = $u.Title
                Identifier = $id
                RevisionNumber = $rev
                Type = (try { [string]$u.Type } catch { $null })
                KBArticleIDs = $kb
                RebootRequired = $rebootRequired
                DriverManufacturer = $driverManufacturer
                DriverModel = $driverModel
                DriverClass = $driverClass
                AvailableVersion = $driverVerVersion
                DriverVerDate = if ($driverVerDate) { ([datetime]$driverVerDate).ToString('o') } else { $null }
            }
        }

        $out = [pscustomobject]@{
            Attempted = $true
            Success = $true
            Error = $null
            Count = @($updates).Count
            Updates = @($updates)
        }
    }
    catch {
        $out = [pscustomobject]@{
            Attempted = $true
            Success = $false
            Error = $_.Exception.Message
            Count = 0
            Updates = @()
        }
    }

    return $out
}



