#Requires -Version 5.1

<#
.SYNOPSIS
    Version comparison functions for DriverManagement module
#>

function Compare-DriverVersion {
    <#
    .SYNOPSIS
        Compares two driver version strings
    .DESCRIPTION
        Normalizes and compares version strings, handling various formats
    .PARAMETER InstalledVersion
        Currently installed version
    .PARAMETER CatalogVersion
        Available version from catalog
    .RETURNS
        -1 if installed is older, 0 if same, 1 if installed is newer
    .EXAMPLE
        Compare-DriverVersion -InstalledVersion "1.0.0.0" -CatalogVersion "1.0.1.0"
        # Returns -1 (installed is older)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InstalledVersion,
        
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CatalogVersion
    )
    
    # Handle empty versions
    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
        return -1  # Treat missing as older
    }
    if ([string]::IsNullOrWhiteSpace($CatalogVersion)) {
        return 1   # Treat missing catalog as installed being newer
    }
    
    # Normalize versions - strip non-numeric/non-dot characters
    $v1Clean = $InstalledVersion -replace '[^0-9.]', ''
    $v2Clean = $CatalogVersion -replace '[^0-9.]', ''
    
    # Handle more than 4 parts (take first 4 for [Version] compatibility)
    $v1Parts = ($v1Clean.Split('.') | Select-Object -First 4) -join '.'
    $v2Parts = ($v2Clean.Split('.') | Select-Object -First 4) -join '.'
    
    # Ensure minimum Major.Minor format
    if ($v1Parts -notmatch '\.') { $v1Parts = "$v1Parts.0" }
    if ($v2Parts -notmatch '\.') { $v2Parts = "$v2Parts.0" }
    
    # Pad to ensure both have same number of parts
    $v1Segments = $v1Parts.Split('.')
    $v2Segments = $v2Parts.Split('.')
    $maxSegments = [Math]::Max($v1Segments.Count, $v2Segments.Count)
    
    while ($v1Segments.Count -lt $maxSegments) { $v1Segments += '0' }
    while ($v2Segments.Count -lt $maxSegments) { $v2Segments += '0' }
    
    $v1Parts = $v1Segments -join '.'
    $v2Parts = $v2Segments -join '.'
    
    try {
        $ver1 = [version]$v1Parts
        $ver2 = [version]$v2Parts
        
        if ($ver1 -lt $ver2) { return -1 }      # Installed is older
        elseif ($ver1 -gt $ver2) { return 1 }   # Installed is newer
        else { return 0 }                        # Same version
    }
    catch {
        # Fallback to string comparison
        return [string]::Compare($v1Parts, $v2Parts)
    }
}

function Compare-DriverDate {
    <#
    .SYNOPSIS
        Compares driver dates
    .DESCRIPTION
        For drivers that use date-based versioning
    .PARAMETER InstalledDate
        Date of installed driver
    .PARAMETER CatalogDate
        Date of catalog driver
    .RETURNS
        -1 if installed is older, 0 if same, 1 if installed is newer
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InstalledDate,
        
        [Parameter(Mandatory)]
        [AllowNull()]
        $CatalogDate
    )
    
    # Convert to DateTime if needed
    try {
        $date1 = if ($InstalledDate -is [datetime]) { $InstalledDate } 
                 elseif ($InstalledDate) { [datetime]$InstalledDate }
                 else { [datetime]::MinValue }
        
        $date2 = if ($CatalogDate -is [datetime]) { $CatalogDate }
                 elseif ($CatalogDate) { [datetime]$CatalogDate }
                 else { [datetime]::MaxValue }
        
        if ($date1 -lt $date2) { return -1 }
        elseif ($date1 -gt $date2) { return 1 }
        else { return 0 }
    }
    catch {
        return 0  # Treat as equal if comparison fails
    }
}

function Test-DriverNeedsUpdate {
    <#
    .SYNOPSIS
        Determines if a driver needs updating
    .DESCRIPTION
        Compares installed driver against catalog entry
    .PARAMETER InstalledDriver
        Object with DriverVersion and optionally DriverDate
    .PARAMETER CatalogDriver
        Object with Version and optionally ReleaseDate
    .RETURNS
        Hashtable with NeedsUpdate boolean and reason
    .EXAMPLE
        $result = Test-DriverNeedsUpdate -InstalledDriver $installed -CatalogDriver $catalog
        if ($result.NeedsUpdate) { Write-Host "Update available: $($result.Reason)" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InstalledDriver,
        
        [Parameter(Mandatory)]
        [object]$CatalogDriver
    )
    
    # Get version strings
    $installedVersion = if ($InstalledDriver.DriverVersion) { $InstalledDriver.DriverVersion }
                        elseif ($InstalledDriver.Version) { $InstalledDriver.Version }
                        else { "" }
    
    $catalogVersion = if ($CatalogDriver.Version) { $CatalogDriver.Version }
                      elseif ($CatalogDriver.DriverVersion) { $CatalogDriver.DriverVersion }
                      else { "" }
    
    # Compare versions
    $versionComparison = Compare-DriverVersion -InstalledVersion $installedVersion -CatalogVersion $catalogVersion
    
    if ($versionComparison -lt 0) {
        return @{
            NeedsUpdate = $true
            Reason = "Version outdated"
            InstalledVersion = $installedVersion
            CatalogVersion = $catalogVersion
            Comparison = "Installed ($installedVersion) < Catalog ($catalogVersion)"
        }
    }
    elseif ($versionComparison -gt 0) {
        return @{
            NeedsUpdate = $false
            Reason = "Installed is newer than catalog"
            InstalledVersion = $installedVersion
            CatalogVersion = $catalogVersion
            Comparison = "Installed ($installedVersion) > Catalog ($catalogVersion)"
        }
    }
    else {
        # Versions equal - check dates as tiebreaker
        $installedDate = $InstalledDriver.DriverDate
        $catalogDate = $CatalogDriver.ReleaseDate
        
        if ($installedDate -and $catalogDate) {
            $dateComparison = Compare-DriverDate -InstalledDate $installedDate -CatalogDate $catalogDate
            
            if ($dateComparison -lt 0) {
                return @{
                    NeedsUpdate = $true
                    Reason = "Same version but catalog has newer build date"
                    InstalledVersion = $installedVersion
                    CatalogVersion = $catalogVersion
                }
            }
        }
        
        return @{
            NeedsUpdate = $false
            Reason = "Up to date"
            InstalledVersion = $installedVersion
            CatalogVersion = $catalogVersion
        }
    }
}

function Get-VersionFromInf {
    <#
    .SYNOPSIS
        Extracts version information from INF file
    .PARAMETER InfPath
        Path to the INF file
    .RETURNS
        Hashtable with Version and Date
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InfPath
    )
    
    if (-not (Test-Path $InfPath)) {
        return @{ Version = $null; Date = $null }
    }
    
    $content = Get-Content $InfPath -Raw
    
    # Look for DriverVer directive
    # Format: DriverVer = mm/dd/yyyy,x.x.x.x
    $driverVerMatch = [regex]::Match($content, 'DriverVer\s*=\s*(\d{1,2}/\d{1,2}/\d{4})\s*,\s*([\d.]+)')
    
    if ($driverVerMatch.Success) {
        $dateStr = $driverVerMatch.Groups[1].Value
        $version = $driverVerMatch.Groups[2].Value
        
        try {
            $date = [datetime]::ParseExact($dateStr, 'M/d/yyyy', $null)
        }
        catch {
            $date = $null
        }
        
        return @{
            Version = $version
            Date = $date
            Raw = $driverVerMatch.Value
        }
    }
    
    return @{ Version = $null; Date = $null }
}
