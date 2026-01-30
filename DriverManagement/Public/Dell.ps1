#Requires -Version 5.1

<#
.SYNOPSIS
    Dell driver management functions
.DESCRIPTION
    Comprehensive Dell driver and update management using Dell Command Update.
    Includes catalog-based version detection, offline catalog support, and 
    comprehensive exit code handling inspired by Gary Blok's Dell-EMPS.ps1.
.NOTES
    Reference: https://github.com/gwblok/garytown/blob/master/hardware/Dell/CommandUpdate/EMPS/Dell-EMPS.ps1
    DCU Reference Guide: https://dl.dell.com/content/manual13608255-dell-command-update-version-5-x-reference-guide.pdf
#>

#region DCU Exit Codes

# Comprehensive DCU exit codes per Dell documentation
$script:DCUExitCodes = @{
    0    = @{ Description = "Command execution successful"; Resolution = "None required" }
    1    = @{ Description = "Reboot required"; Resolution = "Reboot the system to complete updates" }
    2    = @{ Description = "Unknown application error"; Resolution = "Check DCU logs for details" }
    3    = @{ Description = "Incomplete command line"; Resolution = "Verify command syntax" }
    # NOTE: Dell documentation for DCU 5.x indicates "not launched with administrative privileges" is exit code 4.
    4    = @{ Description = "CLI was not launched with administrative privileges"; Resolution = "Run PowerShell/CLI as Administrator. If already elevated, check Dell services and ProgramData\\Dell permissions." }
    # Exit code 5 meaning varies by DCU version/environment; we keep it actionable and add diagnostics elsewhere.
    5    = @{ Description = "Privilege / qualification error"; Resolution = "If elevated, check Dell Client Management Service and ProgramData\\Dell folder permissions; review DCU logs." }
    6    = @{ Description = "No update information found (check update filter settings)"; Resolution = "Verify -updateType/-updateSeverity filters, run /scan first, and confirm DCU can write to ProgramData\\Dell." }
    7    = @{ Description = "Duplicate command line option"; Resolution = "Remove duplicate options" }
    8    = @{ Description = "Cannot create the scheduled task"; Resolution = "Check Task Scheduler permissions" }
    9    = @{ Description = "Cannot remove the scheduled task"; Resolution = "Check Task Scheduler permissions" }
    10   = @{ Description = "Download failed, no update(s) to apply"; Resolution = "Check network connectivity" }
    11   = @{ Description = "Suspend Bitlocker failed"; Resolution = "Manually suspend BitLocker" }
    12   = @{ Description = "Another instance of DCU running"; Resolution = "Wait for other instance to complete" }
    13   = @{ Description = "Invalid catalog file"; Resolution = "Re-download or regenerate catalog" }
    14   = @{ Description = "Unable to schedule updates"; Resolution = "Check scheduled task configuration" }
    15   = @{ Description = "Invalid export file format"; Resolution = "Check export file path/format" }
    16   = @{ Description = "Invalid password"; Resolution = "Verify BIOS password" }
    17   = @{ Description = "System is not supported"; Resolution = "Verify Dell system compatibility" }
    18   = @{ Description = "No updates available"; Resolution = "System is up to date" }
    19   = @{ Description = "Network error"; Resolution = "Check network connectivity to Dell servers" }
    20   = @{ Description = "Catalog sync failed"; Resolution = "Check internet connectivity" }
    21   = @{ Description = "Running in OS pre-boot"; Resolution = "Run after Windows boot completes" }
    500  = @{ Description = "No updates available"; Resolution = "System is up to date" }
    501  = @{ Description = "Soft dependency error"; Resolution = "Check for prerequisite updates" }
    502  = @{ Description = "Hard dependency error"; Resolution = "Install prerequisite updates first" }
    503  = @{ Description = "Already running"; Resolution = "Wait for other DCU instance" }
    504  = @{ Description = "System reboot pending"; Resolution = "Reboot system first" }
    505  = @{ Description = "Rollback"; Resolution = "Update failed and was rolled back" }
    506  = @{ Description = "Update failed"; Resolution = "Check DCU logs for failure details" }
    507  = @{ Description = "Download progress"; Resolution = "Update is still downloading" }
    508  = @{ Description = "Install progress"; Resolution = "Update is still installing" }
    3006 = @{ Description = "System in Windows OOBE state"; Resolution = "Complete Windows setup first, then try again" }
}

function Get-DCUExitInfo {
    <#
    .SYNOPSIS
        Gets information about Dell Command Update exit codes
    .DESCRIPTION
        Returns description and resolution for DCU exit codes.
        Can return all exit codes or a specific one.
    .PARAMETER ExitCode
        Specific exit code to get information for
    .EXAMPLE
        Get-DCUExitInfo -ExitCode 1
    .EXAMPLE
        Get-DCUExitInfo  # Returns all exit codes
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$ExitCode
    )
    
    if ($PSBoundParameters.ContainsKey('ExitCode')) {
        if ($script:DCUExitCodes.ContainsKey($ExitCode)) {
            $info = $script:DCUExitCodes[$ExitCode]
            return [PSCustomObject]@{
                ExitCode    = $ExitCode
                Description = $info.Description
                Resolution  = $info.Resolution
            }
        }
        else {
            return [PSCustomObject]@{
                ExitCode    = $ExitCode
                Description = "Unknown exit code"
                Resolution  = "Check Dell Command Update logs"
            }
        }
    }
    
    # Return all exit codes
    $script:DCUExitCodes.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            ExitCode    = $_.Key
            Description = $_.Value.Description
            Resolution  = $_.Value.Resolution
        }
    } | Sort-Object ExitCode
}

#endregion

#region DCU Installation and Version Detection

function Get-DellCommandUpdatePath {
    <#
    .SYNOPSIS
        Finds the Dell Command Update CLI executable
    .OUTPUTS
        Path to dcu-cli.exe or $null if not found
    #>
    [CmdletBinding()]
    param()
    
    $paths = @(
        "${env:ProgramFiles}\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    )
    return $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Get-DellClientManagementServiceInternal {
    [CmdletBinding()]
    param()

    # Known service names vary slightly by DCU generation; try the most common first.
    $candidates = @(
        'DellClientManagementService',
        'DellCommandUpdateService',
        'DellCommandUpdate',
        'Dell Update Service'
    )

    foreach ($name in $candidates) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { return $svc }
    }

    # Fallback: search by display name
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like '*Dell Client Management*' -or
        $_.DisplayName -like '*Dell Command*Update*' -or
        $_.DisplayName -like '*Dell Update Service*'
    } | Select-Object -First 1

    return $svc
}

function Ensure-DellClientManagementServiceInternal {
    [CmdletBinding()]
    param()

    $svc = Get-DellClientManagementServiceInternal
    if (-not $svc) {
        return @{
            Found = $false
            Name = $null
            DisplayName = $null
            Status = $null
            Started = $false
            Message = "Dell Client Management / DCU service not found"
        }
    }

    $started = $false
    $message = "Service present"
    try {
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $svc.Name -ErrorAction Stop
            $svc = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            $started = $svc -and $svc.Status -eq 'Running'
            $message = if ($started) { "Service started" } else { "Service start attempted but status is $($svc.Status)" }
        }
    }
    catch {
        $message = "Failed to start service: $($_.Exception.Message)"
    }

    return @{
        Found = $true
        Name = $svc.Name
        DisplayName = $svc.DisplayName
        Status = $svc.Status.ToString()
        Started = $started
        Message = $message
    }
}

function Test-WriteAccessInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
        $probe = Join-Path $Path ("dm_write_probe_{0}.tmp" -f ([guid]::NewGuid().ToString('n')))
        'probe' | Set-Content -Path $probe -Encoding ASCII -Force
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Get-DCUInstallDetails {
    <#
    .SYNOPSIS
        Gets Dell Command Update installation details from registry
    .DESCRIPTION
        Queries the registry to determine installed DCU version and type
        (Universal Windows Platform vs Classic).
    .EXAMPLE
        Get-DCUInstallDetails
    .OUTPUTS
        PSCustomObject with Version, AppType, Path properties
    #>
    [CmdletBinding()]
    param()
    
    $result = [PSCustomObject]@{
        IsInstalled = $false
        Version     = $null
        AppType     = $null  # 'Universal' or 'Classic'
        Path        = $null
        InstallDate = $null
    }
    
    # Check Universal Windows Platform (UWP) version
    $uwpReg = "HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate"
    if (Test-Path $uwpReg) {
        try {
            $regData = Get-ItemProperty -Path $uwpReg -ErrorAction Stop
            $result.IsInstalled = $true
            $result.Version = if ($regData.Version) { $regData.Version } else { $regData.ProductVersion }
            $result.AppType = 'Universal'
        }
        catch { }
    }
    
    # Check Classic version
    $classicReg = "HKLM:\SOFTWARE\DELL\CommandUpdate"
    if (-not $result.IsInstalled -and (Test-Path $classicReg)) {
        try {
            $regData = Get-ItemProperty -Path $classicReg -ErrorAction Stop
            $result.IsInstalled = $true
            $result.Version = if ($regData.Version) { $regData.Version } else { $regData.ProductVersion }
            $result.AppType = 'Classic'
        }
        catch { }
    }
    
    # Also check Programs and Features via Uninstall registry
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($path in $uninstallPaths) {
        $dcu = Get-ItemProperty $path -ErrorAction SilentlyContinue | 
            Where-Object { $_.DisplayName -like "*Dell Command*Update*" } |
            Select-Object -First 1
        
        if ($dcu) {
            $result.IsInstalled = $true
            $result.Version = if ($result.Version) { $result.Version } else { $dcu.DisplayVersion }
            $result.InstallDate = $dcu.InstallDate
            break
        }
    }
    
    # Get executable path
    $result.Path = Get-DellCommandUpdatePath
    
    return $result
}

#region Dell SupportAssist Handling

function Get-DellSupportAssistInstallDetails {
    <#
    .SYNOPSIS
        Detects Dell SupportAssist installations.
    .DESCRIPTION
        Searches Uninstall registry keys for SupportAssist-related products.
        Returns entries with uninstall strings when available.
    #>
    [CmdletBinding()]
    param()
    
    $results = @()
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($path in $uninstallPaths) {
        $items = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -and (
                $_.DisplayName -match 'SupportAssist' -or
                $_.DisplayName -match 'Dell SupportAssist'
            )
        }
        
        foreach ($i in $items) {
            $results += [PSCustomObject]@{
                DisplayName          = $i.DisplayName
                DisplayVersion       = $i.DisplayVersion
                Publisher            = $i.Publisher
                UninstallString      = $i.UninstallString
                QuietUninstallString = $i.QuietUninstallString
                ProductCodeOrKey     = $i.PSChildName
            }
        }
    }
    
    # De-dupe by name/version
    return $results | Sort-Object DisplayName, DisplayVersion -Unique
}

function Uninstall-DellSupportAssist {
    <#
    .SYNOPSIS
        Uninstalls Dell SupportAssist if installed.
    .DESCRIPTION
        Best-effort silent uninstall using:
        - QuietUninstallString if available
        - MSI uninstall for GUID-based products
        - WinGet uninstall fallback when possible
    .PARAMETER Force
        Attempt removal even if the Publisher does not look like Dell.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    Assert-Elevation -Operation "Uninstalling Dell SupportAssist"
    
    $installs = Get-DellSupportAssistInstallDetails
    if (-not $installs -or $installs.Count -eq 0) {
        Write-DriverLog -Message "Dell SupportAssist not detected" -Severity Info
        return $true
    }
    
    Write-DriverLog -Message "Dell SupportAssist detected ($($installs.Count) entries) - attempting uninstall" -Severity Warning `
        -Context @{ Products = ($installs | Select-Object DisplayName, DisplayVersion, Publisher) }
    
    $allOk = $true
    
    foreach ($app in $installs) {
        # Avoid removing unrelated “SupportAssist” unless forced or looks Dell-authored
        if (-not $Force) {
            if ($app.Publisher -and ($app.Publisher -notmatch 'Dell')) {
                Write-DriverLog -Message "Skipping uninstall for $($app.DisplayName) (publisher: $($app.Publisher)) - use -Force to override" -Severity Warning
                continue
            }
        }
        
        if (-not $PSCmdlet.ShouldProcess($app.DisplayName, "Uninstall")) { continue }
        
        try {
            # 1) QuietUninstallString
            if ($app.QuietUninstallString) {
                Write-DriverLog -Message "Uninstalling via QuietUninstallString: $($app.DisplayName)" -Severity Info
                $p = Start-Process -FilePath "cmd.exe" -ArgumentList @('/c', $app.QuietUninstallString) -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { throw "Quiet uninstall exit code $($p.ExitCode)" }
                continue
            }
            
            # 2) MSI GUID based uninstall
            $guid = $null
            if ($app.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
                $guid = $Matches[0]
            }
            elseif ($app.ProductCodeOrKey -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $guid = $app.ProductCodeOrKey
            }
            
            if ($guid) {
                Write-DriverLog -Message "Uninstalling via msiexec: $($app.DisplayName) ($guid)" -Severity Info
                $args = @('/x', $guid, '/qn', '/norestart')
                $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { throw "msiexec exit code $($p.ExitCode)" }
                continue
            }
            
            # 3) UninstallString fallback (best effort)
            if ($app.UninstallString) {
                Write-DriverLog -Message "Uninstalling via UninstallString (best effort): $($app.DisplayName)" -Severity Info
                $p = Start-Process -FilePath "cmd.exe" -ArgumentList @('/c', $app.UninstallString) -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -ne 0) { throw "UninstallString exit code $($p.ExitCode)" }
                continue
            }
            
            throw "No uninstall command available"
        }
        catch {
            Write-DriverLog -Message "Registry uninstall failed for $($app.DisplayName): $($_.Exception.Message). Trying WinGet uninstall..." -Severity Warning
            
            try {
                if (-not (Ensure-WinGetInternal -AutoInstall)) {
                    throw "WinGet not available"
                }
                
                $winget = Get-Command winget.exe -ErrorAction Stop
                
                # Try common IDs first; if not, attempt by name match
                $candidateIds = @(
                    'Dell.SupportAssist',
                    'Dell.SupportAssistforBusinessPCs'
                )
                
                $uninstalled = $false
                foreach ($id in $candidateIds) {
                    $p = Start-Process -FilePath $winget.Source -ArgumentList @('uninstall','-e','--id',$id,'--silent') -Wait -PassThru -NoNewWindow
                    if ($p.ExitCode -eq 0) { $uninstalled = $true; break }
                }
                
                if (-not $uninstalled) {
                    # Name-based fallback (no exact match, but usually works)
                    $p = Start-Process -FilePath $winget.Source -ArgumentList @('uninstall','--name','SupportAssist','--silent') -Wait -PassThru -NoNewWindow
                    if ($p.ExitCode -eq 0) { $uninstalled = $true }
                }
                
                if (-not $uninstalled) {
                    throw "WinGet uninstall did not succeed"
                }
                
                Write-DriverLog -Message "Dell SupportAssist removed via WinGet fallback: $($app.DisplayName)" -Severity Info
            }
            catch {
                $allOk = $false
                Write-DriverLog -Message "Failed to uninstall $($app.DisplayName): $($_.Exception.Message)" -Severity Error
            }
        }
    }
    
    return $allOk
}

#endregion

function Get-DellCatalog {
    <#
    .SYNOPSIS
        Downloads and parses the Dell CatalogIndexPC.cab
    .DESCRIPTION
        Retrieves the Dell update catalog which contains information about
        supported models, available updates, and download URLs.
        Based on Gary Blok's Get-DellSupportedModels function.
    .PARAMETER Force
        Force re-download even if cached
    .EXAMPLE
        Get-DellCatalog
    .OUTPUTS
        Array of supported Dell models with SystemID, Model, URL, Date
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    $cabPath = "$env:ProgramData\PSDriverManagement\DellCatalog\CatalogIndexPC.cab"
    $extractPath = "$env:ProgramData\PSDriverManagement\DellCatalog\Extract"
    $xmlPath = "$extractPath\CatalogIndexPC.xml"
    
    # Check cache (valid for 24 hours)
    $cacheValid = $false
    if (-not $Force -and (Test-Path $xmlPath)) {
        $cacheAge = (Get-Date) - (Get-Item $xmlPath).LastWriteTime
        if ($cacheAge.TotalHours -lt 24) {
            $cacheValid = $true
            Write-DriverLog -Message "Using cached Dell catalog (age: $([math]::Round($cacheAge.TotalHours, 1)) hours)" -Severity Info
        }
    }
    
    if (-not $cacheValid) {
        # Ensure directories exist
        $cabDir = Split-Path $cabPath -Parent
        if (-not (Test-Path $cabDir)) {
            New-Item -Path $cabDir -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path $extractPath)) {
            New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        }
        
        Write-DriverLog -Message "Downloading Dell catalog from downloads.dell.com" -Severity Info
        
        try {
            Invoke-WebRequest -Uri "https://downloads.dell.com/catalog/CatalogIndexPC.cab" -OutFile $cabPath -UseBasicParsing -ErrorAction Stop
            
            # Extract CAB
            if (Test-Path "$extractPath\CatalogIndexPC.xml") {
                Remove-Item "$extractPath\CatalogIndexPC.xml" -Force
            }
            
            $expandResult = & expand.exe $cabPath -F:CatalogIndexPC.xml $extractPath 2>&1
            
            if (-not (Test-Path $xmlPath)) {
                throw "Failed to extract catalog XML"
            }
            
            Write-DriverLog -Message "Dell catalog downloaded and extracted" -Severity Info
        }
        catch {
            Write-DriverLog -Message "Failed to download Dell catalog: $($_.Exception.Message)" -Severity Error
            throw
        }
    }
    
    # Parse XML
    Write-DriverLog -Message "Parsing Dell catalog XML" -Severity Info
    [xml]$catalogXml = Get-Content $xmlPath
    
    $models = $catalogXml.ManifestIndex.GroupManifest | ForEach-Object {
        [PSCustomObject]@{
            SystemID = $_.SupportedSystems.Brand.Model.systemID
            Model    = $_.SupportedSystems.Brand.Model.Display.'#cdata-section'
            URL      = $_.ManifestInformation.path
            Date     = $_.ManifestInformation.version
        }
    }
    
    return $models
}

function Get-LatestDCUVersion {
    <#
    .SYNOPSIS
        Gets the latest available Dell Command Update version
    .DESCRIPTION
        Queries Dell's catalog to find the latest DCU version available
        for download. Optionally checks against the currently installed version.
    .PARAMETER CheckUpdate
        Compare with installed version and return if update is available
    .EXAMPLE
        Get-LatestDCUVersion
    .EXAMPLE
        Get-LatestDCUVersion -CheckUpdate
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$CheckUpdate
    )
    
    # Dell Command Update package info URL
    $dcuInfoUrl = "https://downloads.dell.com/catalog/CatalogIndexPC.cab"
    
    # Try to get version from Dell's driver catalog
    try {
        $cabPath = "$env:ProgramData\PSDriverManagement\DellCatalog\DCUVersion.cab"
        $extractPath = "$env:ProgramData\PSDriverManagement\DellCatalog\DCUExtract"
        
        $cabDir = Split-Path $cabPath -Parent
        if (-not (Test-Path $cabDir)) {
            New-Item -Path $cabDir -ItemType Directory -Force | Out-Null
        }
        
        # Download CatalogPC.cab which contains DCU info
        $catalogUrl = "https://downloads.dell.com/catalog/CatalogPC.cab"
        Invoke-WebRequest -Uri $catalogUrl -OutFile $cabPath -UseBasicParsing -ErrorAction Stop
        
        if (-not (Test-Path $extractPath)) {
            New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        }
        
        # Extract
        & expand.exe $cabPath -F:* $extractPath 2>&1 | Out-Null
        
        # Find DCU in catalog
        $catalogXmlPath = Get-ChildItem $extractPath -Filter "*.xml" | Select-Object -First 1
        if ($catalogXmlPath) {
            [xml]$catalog = Get-Content $catalogXmlPath.FullName
            
            $dcuPackage = $catalog.Manifest.SoftwareComponent | 
                Where-Object { $_.Name.Display.'#cdata-section' -like "*Dell Command*Update*" } |
                Sort-Object { [version]$_.vendorVersion } -Descending |
                Select-Object -First 1
            
            if ($dcuPackage) {
                $latestInfo = [PSCustomObject]@{
                    Version     = $dcuPackage.vendorVersion
                    ReleaseDate = $dcuPackage.releaseDate
                    DownloadUrl = "https://downloads.dell.com/$($dcuPackage.path)"
                    FileName    = Split-Path $dcuPackage.path -Leaf
                    Size        = $dcuPackage.size
                }
                
                if ($CheckUpdate) {
                    $installed = Get-DCUInstallDetails
                    
                    $latestInfo | Add-Member -NotePropertyName 'InstalledVersion' -NotePropertyValue $installed.Version
                    $latestInfo | Add-Member -NotePropertyName 'UpdateAvailable' -NotePropertyValue $false
                    
                    if ($installed.IsInstalled -and $installed.Version) {
                        try {
                            $latestInfo.UpdateAvailable = ([version]$latestInfo.Version) -gt ([version]$installed.Version)
                        }
                        catch {
                            # Version comparison failed
                            $latestInfo.UpdateAvailable = $latestInfo.Version -ne $installed.Version
                        }
                    }
                    else {
                        $latestInfo.UpdateAvailable = $true  # Not installed
                    }
                }
                
                return $latestInfo
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to get latest DCU version from catalog: $($_.Exception.Message)" -Severity Warning
    }
    
    # Fallback: Return known latest version
    return [PSCustomObject]@{
        Version     = "5.4.0"
        ReleaseDate = "2024-01-01"
        DownloadUrl = "https://dl.dell.com/FOLDER11914155M/1/Dell-Command-Update-Windows-Universal-Application_601KT_WIN_5.4.0_A00.EXE"
        FileName    = "Dell-Command-Update-Windows-Universal-Application_601KT_WIN_5.4.0_A00.EXE"
        Size        = $null
    }
}

function Install-DellCommandUpdate {
    <#
    .SYNOPSIS
        Installs Dell Command Update via WinGet
    .DESCRIPTION
        Installs Dell Command Update using WinGet (winget install Dell.CommandUpdate).
        WinGet is auto-installed if missing. SupportAssist is removed first to prevent conflicts.
    .PARAMETER Force
        Install even if current version is up to date
    .EXAMPLE
        Install-DellCommandUpdate
    .EXAMPLE
        Install-DellCommandUpdate -Force
    .NOTES
        Dell Command Update Universal Windows Platform application
        https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    Assert-Elevation -Operation "Installing Dell Command Update"

    # If SupportAssist is installed, remove it proactively (commonly causes conflicts / stale Dell tooling)
    try {
        Uninstall-DellSupportAssist | Out-Null
    }
    catch {
        Write-DriverLog -Message "SupportAssist removal encountered an error but will not block DCU install: $($_.Exception.Message)" -Severity Warning
    }
    
    # Check if update is needed
    if (-not $Force) {
        $installed = Get-DCUInstallDetails
        
        if ($installed.IsInstalled) {
            $latestInfo = Get-LatestDCUVersion -CheckUpdate
            
            if (-not $latestInfo.UpdateAvailable) {
                Write-DriverLog -Message "Dell Command Update is already up to date (v$($installed.Version))" -Severity Info
                return [PSCustomObject]@{
                    Success = $true
                    ExitCode = 0
                    Message = "Already up to date (v$($installed.Version))"
                    RebootRequired = $false
                }
            }
            
            Write-DriverLog -Message "Update available: $($installed.Version) -> $($latestInfo.Version)" -Severity Info
        }
    }
    
    # Install via WinGet (primary and only method - Dell direct downloads often blocked by Akamai/403)
    Write-DriverLog -Message "Installing Dell Command Update via WinGet (Dell.CommandUpdate)..." -Severity Info
    
    try {
        if (-not (Ensure-WinGetInternal -AutoInstall)) {
            throw "WinGet is not available and could not be installed automatically"
        }
        
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw "winget.exe not found after auto-install attempt"
        }
        
        # Use exact ID match for Dell Command Update
        $wingetArgs = @('install', '-e', '--id', 'Dell.CommandUpdate', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        
        Write-DriverLog -Message "Running: winget $($wingetArgs -join ' ')" -Severity Info
        
        $p = Start-Process -FilePath $winget.Source -ArgumentList $wingetArgs -Wait -PassThru -NoNewWindow
        
        switch ($p.ExitCode) {
            0 {
                Write-DriverLog -Message "Dell Command Update installed successfully via WinGet" -Severity Info
                return [PSCustomObject]@{
                    Success = $true
                    ExitCode = 0
                    Message = "Installed via WinGet"
                    RebootRequired = $false
                }
            }
            { $_ -eq -1978335189 -or $_ -eq 0x8A150011 } {
                # APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED (same version already installed)
                Write-DriverLog -Message "Dell Command Update is already installed (same version)" -Severity Info
                return [PSCustomObject]@{
                    Success = $true
                    ExitCode = 0
                    Message = "Already installed"
                    RebootRequired = $false
                }
            }
            default {
                throw "WinGet install failed with exit code $($p.ExitCode)"
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to install Dell Command Update via WinGet: $($_.Exception.Message)" -Severity Error
        throw
    }
}

#endregion

#region DCU Settings

function Get-DCUSettings {
    <#
    .SYNOPSIS
        Gets current Dell Command Update settings
    .DESCRIPTION
        Reads DCU configuration from registry.
    .EXAMPLE
        Get-DCUSettings
    #>
    [CmdletBinding()]
    param()
    
    $settings = [PSCustomObject]@{
        UserConsent = $null
        AutoSuspendBitLocker = $null
        ScheduleAction = $null
        ScheduleAuto = $null
        InstallationDeferral = $null
        SystemRestartDeferral = $null
        AdvancedDriverRestore = $null
        LockSettings = $null
        CatalogLocation = $null
    }
    
    $regPath = "HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate\Preferences\Settings"
    
    if (Test-Path $regPath) {
        try {
            $regData = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            
            $settings.UserConsent = $regData.UserConsent
            $settings.AutoSuspendBitLocker = $regData.AutoSuspendBitLocker
            $settings.ScheduleAction = $regData.ScheduleAction
            $settings.ScheduleAuto = $regData.ScheduleAuto
            $settings.InstallationDeferral = $regData.InstallationDeferral
            $settings.SystemRestartDeferral = $regData.SystemRestartDeferral
            $settings.AdvancedDriverRestore = $regData.AdvancedDriverRestore
            $settings.LockSettings = $regData.LockSettings
            $settings.CatalogLocation = $regData.CatalogLocation
        }
        catch {
            Write-DriverLog -Message "Failed to read DCU settings: $($_.Exception.Message)" -Severity Warning
        }
    }
    
    return $settings
}

function Set-DCUSettings {
    <#
    .SYNOPSIS
        Configures Dell Command Update settings
    .DESCRIPTION
        Uses dcu-cli.exe to configure DCU settings.
    .PARAMETER UserConsent
        Enable or disable user consent prompts
    .PARAMETER AutoSuspendBitLocker
        Enable automatic BitLocker suspension for BIOS updates
    .PARAMETER AdvancedDriverRestore
        Enable driver restore points
    .PARAMETER ScheduleAction
        Schedule action: DownloadOnly, DownloadAndNotify, DownloadInstallAndNotify
    .PARAMETER InstallationDeferral
        Number of days to defer installation
    .PARAMETER SystemRestartDeferral
        Number of days to defer restart
    .EXAMPLE
        Set-DCUSettings -AutoSuspendBitLocker enable -AdvancedDriverRestore enable
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [ValidateSet('enable', 'disable')]
        [string]$UserConsent,
        
        [Parameter()]
        [ValidateSet('enable', 'disable')]
        [string]$AutoSuspendBitLocker,
        
        [Parameter()]
        [ValidateSet('enable', 'disable')]
        [string]$AdvancedDriverRestore,
        
        [Parameter()]
        [ValidateSet('DownloadOnly', 'DownloadAndNotify', 'DownloadInstallAndNotify')]
        [string]$ScheduleAction,
        
        [Parameter()]
        [ValidateRange(0, 365)]
        [int]$InstallationDeferral,
        
        [Parameter()]
        [ValidateRange(0, 365)]
        [int]$SystemRestartDeferral
    )
    
    $dcuPath = Get-DellCommandUpdatePath
    if (-not $dcuPath) {
        throw "Dell Command Update is not installed"
    }
    
    $configArgs = @('/configure', '-silent')
    $changes = @()
    
    if ($UserConsent) {
        $configArgs += "-userConsent=$UserConsent"
        $changes += "UserConsent=$UserConsent"
    }
    
    if ($AutoSuspendBitLocker) {
        $configArgs += "-autoSuspendBitLocker=$AutoSuspendBitLocker"
        $changes += "AutoSuspendBitLocker=$AutoSuspendBitLocker"
    }
    
    if ($AdvancedDriverRestore) {
        $configArgs += "-advancedDriverRestore=$AdvancedDriverRestore"
        $changes += "AdvancedDriverRestore=$AdvancedDriverRestore"
    }
    
    if ($ScheduleAction) {
        $configArgs += "-scheduleAction=$ScheduleAction"
        $changes += "ScheduleAction=$ScheduleAction"
    }
    
    if ($PSBoundParameters.ContainsKey('InstallationDeferral')) {
        if ($ScheduleAction -eq 'DownloadInstallAndNotify' -or -not $ScheduleAction) {
            $configArgs += "-installationDeferral=$InstallationDeferral"
            $changes += "InstallationDeferral=$InstallationDeferral"
        }
        else {
            Write-DriverLog -Message "InstallationDeferral only applies to DownloadInstallAndNotify schedule action" -Severity Warning
        }
    }
    
    if ($PSBoundParameters.ContainsKey('SystemRestartDeferral')) {
        if ($ScheduleAction -eq 'DownloadInstallAndNotify' -or -not $ScheduleAction) {
            $configArgs += "-systemRestartDeferral=$SystemRestartDeferral"
            $changes += "SystemRestartDeferral=$SystemRestartDeferral"
        }
        else {
            Write-DriverLog -Message "SystemRestartDeferral only applies to DownloadInstallAndNotify schedule action" -Severity Warning
        }
    }
    
    if ($changes.Count -eq 0) {
        Write-DriverLog -Message "No settings specified to change" -Severity Warning
        return
    }
    
    if ($PSCmdlet.ShouldProcess("DCU Settings: $($changes -join ', ')", "Configure")) {
        Write-DriverLog -Message "Configuring DCU: $($changes -join ', ')" -Severity Info
        
        & $dcuPath @configArgs 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
        
        $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
        
        if ($exitCode -eq 0) {
            Write-DriverLog -Message "DCU settings configured successfully" -Severity Info
        }
        else {
            Write-DriverLog -Message "DCU configuration returned: $($exitInfo.Description)" -Severity Warning
        }
        
        return Get-DCUSettings
    }
}

#endregion

#region Offline Catalog Support

function Get-DCUCatalogPath {
    <#
    .SYNOPSIS
        Gets the configured DCU catalog path
    .DESCRIPTION
        Returns the custom catalog path if configured, or the default Dell catalog location.
    .EXAMPLE
        Get-DCUCatalogPath
    #>
    [CmdletBinding()]
    param()
    
    # Check environment variable first
    if ($env:PSDM_DCU_CATALOG) {
        return $env:PSDM_DCU_CATALOG
    }
    
    # Check DCU settings
    $settings = Get-DCUSettings
    if ($settings.CatalogLocation) {
        return $settings.CatalogLocation
    }
    
    # Return default
    return $null  # DCU uses Dell's online catalog by default
}

function Set-DCUCatalogPath {
    <#
    .SYNOPSIS
        Sets a custom catalog path for Dell Command Update
    .DESCRIPTION
        Configures DCU to use a local or network catalog file instead of Dell's online catalog.
        Useful for offline environments or controlled update deployments.
    .PARAMETER CatalogPath
        Path to the local catalog XML file or network share
    .PARAMETER Reset
        Reset to use Dell's online catalog
    .EXAMPLE
        Set-DCUCatalogPath -CatalogPath 'C:\DCUCatalog\Catalog.xml'
    .EXAMPLE
        Set-DCUCatalogPath -CatalogPath '\\server\share\DCUCatalog\Catalog.xml'
    .EXAMPLE
        Set-DCUCatalogPath -Reset
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ParameterSetName = 'SetPath')]
        [string]$CatalogPath,
        
        [Parameter(Mandatory, ParameterSetName = 'Reset')]
        [switch]$Reset
    )
    
    $dcuPath = Get-DellCommandUpdatePath
    if (-not $dcuPath) {
        throw "Dell Command Update is not installed"
    }
    
    if ($Reset) {
        if ($PSCmdlet.ShouldProcess("DCU catalog", "Reset to online")) {
            Write-DriverLog -Message "Resetting DCU to use online catalog" -Severity Info
            
            & $dcuPath /configure -catalogLocation= -silent 2>&1 | Out-Null
            
            Write-DriverLog -Message "DCU catalog reset to online" -Severity Info
        }
    }
    else {
        if (-not (Test-Path $CatalogPath)) {
            throw "Catalog path not found: $CatalogPath"
        }
        
        if ($PSCmdlet.ShouldProcess($CatalogPath, "Set as DCU catalog")) {
            Write-DriverLog -Message "Setting DCU catalog path: $CatalogPath" -Severity Info
            
            & $dcuPath /configure "-catalogLocation=$CatalogPath" -silent 2>&1 | Out-Null
            $exitCode = $LASTEXITCODE
            
            if ($exitCode -eq 0) {
                Write-DriverLog -Message "DCU catalog path configured" -Severity Info
            }
            else {
                $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
                Write-DriverLog -Message "DCU catalog configuration: $($exitInfo.Description)" -Severity Warning
            }
        }
    }
}

function New-DCUOfflineCatalog {
    <#
    .SYNOPSIS
        Creates an offline Dell Command Update catalog
    .DESCRIPTION
        Downloads the Dell catalog and optionally driver packages for offline use.
        Rewrites the catalog base location for local paths.
    .PARAMETER OutputPath
        Directory to store the offline catalog and drivers
    .PARAMETER SystemID
        Specific system ID to create catalog for (default: current system)
    .PARAMETER IncludeDrivers
        Download driver packages along with catalog
    .PARAMETER DriverTypes
        Types of drivers to include: Driver, BIOS, Firmware, Application
    .EXAMPLE
        New-DCUOfflineCatalog -OutputPath 'C:\DCUOffline' -IncludeDrivers
    .EXAMPLE
        New-DCUOfflineCatalog -OutputPath '\\server\share\DCU' -SystemID '0A5C'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter()]
        [string]$SystemID,
        
        [Parameter()]
        [switch]$IncludeDrivers,
        
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'Application', 'All')]
        [string[]]$DriverTypes = @('Driver', 'BIOS', 'Firmware')
    )
    
    # Get system ID if not provided
    if (-not $SystemID) {
        $systemInfo = Get-CimInstance -ClassName Win32_ComputerSystem
        $SystemID = $systemInfo.SystemSKUNumber
        
        if (-not $SystemID) {
            throw "Could not determine system ID. Please provide -SystemID parameter."
        }
    }
    
    Write-DriverLog -Message "Creating offline catalog for SystemID: $SystemID" -Severity Info
    
    # Create output directory
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    
    $catalogDir = Join-Path $OutputPath "Catalog"
    $driversDir = Join-Path $OutputPath "Drivers"
    
    if (-not (Test-Path $catalogDir)) {
        New-Item -Path $catalogDir -ItemType Directory -Force | Out-Null
    }
    
    # Download main catalog
    $cabPath = Join-Path $catalogDir "CatalogPC.cab"
    $extractPath = Join-Path $catalogDir "Extract"
    
    Write-DriverLog -Message "Downloading Dell catalog" -Severity Info
    
    Invoke-WebRequest -Uri "https://downloads.dell.com/catalog/CatalogPC.cab" -OutFile $cabPath -UseBasicParsing
    
    if (-not (Test-Path $extractPath)) {
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
    }
    
    & expand.exe $cabPath -F:* $extractPath 2>&1 | Out-Null
    
    # Parse catalog
    $catalogXmlPath = Get-ChildItem $extractPath -Filter "*.xml" | Select-Object -First 1
    [xml]$catalog = Get-Content $catalogXmlPath.FullName
    
    # Filter for system
    $systemComponents = $catalog.Manifest.SoftwareComponent | Where-Object {
        $_.SupportedSystems.Brand.Model.systemID -eq $SystemID -or
        $_.SupportedSystems.Brand.Model.systemID -contains $SystemID
    }
    
    Write-DriverLog -Message "Found $($systemComponents.Count) components for system" -Severity Info
    
    # Download drivers if requested
    $downloadedFiles = @()
    
    if ($IncludeDrivers -and $systemComponents) {
        if (-not (Test-Path $driversDir)) {
            New-Item -Path $driversDir -ItemType Directory -Force | Out-Null
        }
        
        $filteredComponents = $systemComponents | Where-Object {
            $type = $_.ComponentType.Display.'#cdata-section'
            'All' -in $DriverTypes -or 
            ($type -like '*Driver*' -and 'Driver' -in $DriverTypes) -or
            ($type -like '*BIOS*' -and 'BIOS' -in $DriverTypes) -or
            ($type -like '*Firmware*' -and 'Firmware' -in $DriverTypes) -or
            ($type -like '*Application*' -and 'Application' -in $DriverTypes)
        }
        
        Write-DriverLog -Message "Downloading $($filteredComponents.Count) driver packages" -Severity Info
        
        $count = 0
        foreach ($component in $filteredComponents) {
            $count++
            $downloadUrl = "https://downloads.dell.com/$($component.path)"
            $fileName = Split-Path $component.path -Leaf
            $localPath = Join-Path $driversDir $fileName
            
            Write-Progress -Activity "Downloading drivers" -Status "$count of $($filteredComponents.Count): $fileName" -PercentComplete (($count / $filteredComponents.Count) * 100)
            
            try {
                if (-not (Test-Path $localPath)) {
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
                }
                $downloadedFiles += $fileName
            }
            catch {
                Write-DriverLog -Message "Failed to download $fileName`: $($_.Exception.Message)" -Severity Warning
            }
        }
        
        Write-Progress -Activity "Downloading drivers" -Completed
    }
    
    # Create modified catalog with local paths
    $offlineCatalogPath = Join-Path $catalogDir "OfflineCatalog_$SystemID.xml"
    
    # Modify base location in catalog
    $catalogContent = Get-Content $catalogXmlPath.FullName -Raw
    $catalogContent = $catalogContent -replace 'downloads\.dell\.com', $OutputPath.Replace('\', '/')
    $catalogContent | Set-Content -Path $offlineCatalogPath -Encoding UTF8
    
    $result = [PSCustomObject]@{
        SystemID = $SystemID
        CatalogPath = $offlineCatalogPath
        DriversPath = $driversDir
        ComponentCount = $systemComponents.Count
        DownloadedFiles = $downloadedFiles.Count
        OutputPath = $OutputPath
    }
    
    Write-DriverLog -Message "Offline catalog created: $offlineCatalogPath" -Severity Info `
        -Context @{ SystemID = $SystemID; Components = $systemComponents.Count }
    
    return $result
}

#endregion

#region OOBE Detection and Direct Driver Installation

function Test-DellOOBEBlocked {
    <#
    .SYNOPSIS
        Checks if Dell Command Update is blocked due to OOBE state
    .OUTPUTS
        $true if OOBE blocking is active, $false otherwise
    #>
    [CmdletBinding()]
    param()
    
    $regPath = "HKLM:\SOFTWARE\Dell\UpdateService\Service\UpdateScheduler"
    $regName = "IsFirstScanAfterOOBEPending"
    
    try {
        $value = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
        return ($value -eq 1)
    }
    catch {
        return $false
    }
}

function Get-DellDriverPackUrl {
    <#
    .SYNOPSIS
        Gets the Dell driver pack download URL for the current system
    .DESCRIPTION
        Queries Dell's Driver Pack Catalog to find the driver pack CAB/EXE for the 
        current system model. This is used for direct driver installation during OOBE.
        Reference: https://www.dell.com/support/kbdoc/en-us/000122176/driver-pack-catalog
    .OUTPUTS
        PSCustomObject with Url, FileName, SystemID, Model, and OS info
    #>
    [CmdletBinding()]
    param()
    
    # Get system info
    $systemInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    
    # Get SystemSKU (Dell SystemID) and Model Name
    $systemId = $systemInfo.SystemSKUNumber
    $modelName = $systemInfo.Model
    
    # Get OS version info (Windows 10 = 10.0, Windows 11 = 10.0 with build >= 22000)
    $osMajor = [System.Environment]::OSVersion.Version.Major
    $osMinor = [System.Environment]::OSVersion.Version.Minor
    $osBuild = [System.Environment]::OSVersion.Version.Build
    $osArch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    
    Write-DriverLog -Message "Looking up driver pack for Model: $modelName, SystemID: $systemId, OS: $osMajor.$osMinor (Build $osBuild) $osArch" -Severity Info
    
    # Download the Dell Driver Pack Catalog (different from CatalogIndexPC.cab!)
    $cabPath = "$env:TEMP\DriverPackCatalog_$(Get-Date -Format 'yyyyMMdd').cab"
    $xmlPath = "$env:TEMP\DriverPackCatalog_$(Get-Date -Format 'yyyyMMdd').xml"
    
    try {
        if (-not (Test-Path $cabPath)) {
            Write-DriverLog -Message "Downloading Dell Driver Pack Catalog" -Severity Info
            Invoke-WebRequest -Uri "https://downloads.dell.com/catalog/DriverPackCatalog.cab" -OutFile $cabPath -UseBasicParsing -ErrorAction Stop
        }
        
        # Extract catalog XML
        if (-not (Test-Path $xmlPath)) {
            & expand.exe $cabPath $xmlPath 2>&1 | Out-Null
        }
        
        if (-not (Test-Path $xmlPath)) {
            throw "Failed to extract DriverPackCatalog.xml"
        }
        
        [xml]$catalogXml = Get-Content $xmlPath
        $baseLocation = $catalogXml.DriverPackManifest.baseLocation
        
        # Find driver pack by SystemID or Model Name, matching OS version and architecture
        $matchingPacks = $catalogXml.DriverPackManifest.DriverPackage | Where-Object {
            # Match by SystemID or Model Name
            $sysMatch = ($_.SupportedSystems.Brand.Model.systemID -eq $systemId) -or
                        ($_.SupportedSystems.Brand.Model.name -eq $modelName)
            
            # Match OS (not WinPE)
            $osMatch = ($_.type -ne "WinPE") -and
                       ($_.SupportedOperatingSystems.OperatingSystem.majorVersion -eq $osMajor) -and
                       ($_.SupportedOperatingSystems.OperatingSystem.osArch -eq $osArch)
            
            $sysMatch -and $osMatch
        }
        
        if (-not $matchingPacks) {
            # Try matching just by model name without strict OS match
            $matchingPacks = $catalogXml.DriverPackManifest.DriverPackage | Where-Object {
                (($_.SupportedSystems.Brand.Model.systemID -eq $systemId) -or
                 ($_.SupportedSystems.Brand.Model.name -eq $modelName)) -and
                ($_.type -ne "WinPE")
            }
        }
        
        if (-not $matchingPacks) {
            Write-DriverLog -Message "No driver pack found for Model: $modelName (SystemID: $systemId)" -Severity Warning
            return $null
        }
        
        # Get the first/best match
        $bestPack = $matchingPacks | Select-Object -First 1
        
        $packUrl = "https://$baseLocation/$($bestPack.path)"
        $fileName = Split-Path $bestPack.path -Leaf
        
        Write-DriverLog -Message "Found driver pack: $fileName (Release: $($bestPack.releaseID))" -Severity Info
        
        return [PSCustomObject]@{
            Url = $packUrl
            FileName = $fileName
            SystemID = $systemId
            Model = $modelName
            ReleaseID = $bestPack.releaseID
            DellVersion = $bestPack.dellVersion
            Size = $bestPack.size
            HashMD5 = $bestPack.hashMD5
        }
    }
    catch {
        Write-DriverLog -Message "Failed to get driver pack URL: $($_.Exception.Message)" -Severity Error
        return $null
    }
}

function Install-DellDriverPackDirect {
    <#
    .SYNOPSIS
        Downloads and installs Dell drivers directly from the driver pack
    .DESCRIPTION
        For use during OOBE when DCU is blocked. Downloads the Dell Driver Pack EXE,
        extracts it to get CAB with drivers, then installs using pnputil.exe.
        Reference: https://www.dell.com/support/kbdoc/en-us/000122176/driver-pack-catalog
    .PARAMETER NoReboot
        Suppress automatic reboot
    .OUTPUTS
        DriverUpdateResult object
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [switch]$NoReboot
    )
    
    Assert-Elevation -Operation "Installing Dell drivers directly"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    Write-DriverLog -Message "DCU blocked by OOBE - using direct driver pack installation" -Severity Info
    
    try {
        # Get driver pack URL from Dell's Driver Pack Catalog
        $packInfo = Get-DellDriverPackUrl
        if (-not $packInfo) {
            $result.Success = $false
            $result.Message = "Could not find driver pack for this system in Dell's Driver Pack Catalog"
            $result.ExitCode = 1
            return $result
        }
        
        # Setup paths
        $downloadPath = "$env:ProgramData\PSDriverManagement\DellDriverPack"
        $packPath = Join-Path $downloadPath $packInfo.FileName
        $extractPath = Join-Path $downloadPath "Extracted_$($packInfo.ReleaseID)"
        
        if (-not (Test-Path $downloadPath)) {
            New-Item -Path $downloadPath -ItemType Directory -Force | Out-Null
        }
        
        # Download driver pack if not cached
        if (-not (Test-Path $packPath)) {
            Write-DriverLog -Message "Downloading driver pack: $($packInfo.FileName) ($([math]::Round([long]$packInfo.Size / 1MB, 0)) MB)" -Severity Info
            Write-DriverLog -Message "URL: $($packInfo.Url)" -Severity Info
            
            # Try BITS first for reliable large file download
            try {
                Start-BitsTransfer -Source $packInfo.Url -Destination $packPath -ErrorAction Stop
            }
            catch {
                Write-DriverLog -Message "BITS failed, using WebRequest" -Severity Warning
                Invoke-WebRequest -Uri $packInfo.Url -OutFile $packPath -UseBasicParsing -ErrorAction Stop
            }
        }
        
        if (-not (Test-Path $packPath)) {
            throw "Driver pack download failed"
        }
        
        $packSize = (Get-Item $packPath).Length / 1MB
        Write-DriverLog -Message "Driver pack ready: $('{0:N0}' -f $packSize) MB" -Severity Info
        
        # Verify hash if available
        if ($packInfo.HashMD5) {
            $actualHash = (Get-FileHash -Path $packPath -Algorithm MD5).Hash
            if ($actualHash -ne $packInfo.HashMD5) {
                Write-DriverLog -Message "Hash mismatch! Expected: $($packInfo.HashMD5), Got: $actualHash" -Severity Warning
                # Continue anyway - hash might be outdated in catalog
            }
        }
        
        # Extract the driver pack EXE (Dell driver packs are self-extracting)
        if (-not (Test-Path $extractPath)) {
            New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
            
            Write-DriverLog -Message "Extracting driver pack to: $extractPath" -Severity Info
            
            # Dell driver pack EXE supports /s (silent) and /e=<path> (extract to path)
            $extractProcess = Start-Process -FilePath $packPath -ArgumentList "/s /e=`"$extractPath`"" -Wait -PassThru -NoNewWindow
            
            if ($extractProcess.ExitCode -ne 0) {
                Write-DriverLog -Message "Extraction via EXE failed (exit: $($extractProcess.ExitCode)), trying expand.exe" -Severity Warning
                # Fallback: try expand.exe in case it's a CAB
                & expand.exe $packPath -F:* $extractPath 2>&1 | Out-Null
            }
        }
        
        # Find all INF files in the extracted folder
        $infFiles = Get-ChildItem -Path $extractPath -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue
        
        if (-not $infFiles -or $infFiles.Count -eq 0) {
            throw "No driver INF files found in extracted pack"
        }
        
        Write-DriverLog -Message "Found $($infFiles.Count) driver INF files" -Severity Info
        
        $driversInstalled = 0
        $driversFailed = 0
        $driversSkipped = 0
        
        # Install each driver using pnputil
        foreach ($inf in $infFiles) {
            if ($PSCmdlet.ShouldProcess($inf.Name, "Install driver")) {
                try {
                    # Use pnputil to add and install the driver
                    $pnpOutput = & pnputil.exe /add-driver $inf.FullName /install 2>&1
                    $pnpExit = $LASTEXITCODE
                    
                    if ($pnpExit -eq 0) {
                        $driversInstalled++
                    }
                    elseif ($pnpExit -eq 259) {
                        # 259 = No more data available (driver already installed or not applicable)
                        $driversSkipped++
                    }
                    else {
                        $driversFailed++
                        Write-DriverLog -Message "Failed to install $($inf.Name): exit code $pnpExit" -Severity Warning
                    }
                }
                catch {
                    $driversFailed++
                    Write-DriverLog -Message "Exception installing $($inf.Name): $($_.Exception.Message)" -Severity Warning
                }
            }
        }
        
        $result.Success = ($driversInstalled -gt 0) -or ($driversSkipped -eq $infFiles.Count)
        $result.UpdatesApplied = $driversInstalled
        $result.UpdatesFailed = $driversFailed
        $result.Message = "Direct driver pack install: $driversInstalled installed, $driversSkipped skipped (not applicable), $driversFailed failed"
        $result.ExitCode = if ($result.Success) { 0 } else { 1 }
        $result.RebootRequired = $driversInstalled -gt 0
        $result.Details['DriverPack'] = $packInfo.FileName
        $result.Details['DirectInstall'] = $true
        
        Write-DriverLog -Message $result.Message -Severity Info
    }
    catch {
        $result.Success = $false
        $result.Message = "Direct driver installation failed: $($_.Exception.Message)"
        $result.ExitCode = 1
        Write-DriverLog -Message $result.Message -Severity Error
    }
    
    return $result
}

function Clear-DellOOBEFlag {
    <#
    .SYNOPSIS
        Clears the Dell OOBE flag to allow DCU to run during Windows setup
    .DESCRIPTION
        Dell Command Update blocks operations when it detects the system is in OOBE
        (Out of Box Experience) state. This function clears the registry flag that
        indicates OOBE is pending, allowing DCU to run during provisioning scenarios.
    .PARAMETER Force
        Suppress confirmation prompts
    .EXAMPLE
        Clear-DellOOBEFlag
    .NOTES
        Requires elevation. This is a workaround for running DCU during Windows provisioning.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    Assert-Elevation -Operation "Clearing Dell OOBE flag"
    
    $regPath = "HKLM:\SOFTWARE\Dell\UpdateService\Service\UpdateScheduler"
    $regName = "IsFirstScanAfterOOBEPending"
    
    if (-not (Test-Path $regPath)) {
        Write-DriverLog -Message "Dell UpdateService registry path not found" -Severity Warning
        return $false
    }
    
    try {
        $currentValue = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
        
        if ($currentValue -eq 0) {
            Write-DriverLog -Message "OOBE flag already cleared" -Severity Info
            return $true
        }
        
        if ($Force -or $PSCmdlet.ShouldProcess("Dell OOBE Flag", "Clear to allow DCU during provisioning")) {
            Set-ItemProperty -Path $regPath -Name $regName -Value 0 -Type DWord -Force
            
            # Also restart the Dell Client Management Service to pick up the change
            $service = Get-Service -Name "DellClientManagementService" -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Write-DriverLog -Message "Restarting Dell Client Management Service" -Severity Info
                Restart-Service -Name "DellClientManagementService" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            
            Write-DriverLog -Message "Dell OOBE flag cleared - DCU should now work during provisioning" -Severity Info
            return $true
        }
        
        return $false
    }
    catch {
        Write-DriverLog -Message "Failed to clear OOBE flag: $($_.Exception.Message)" -Severity Error
        return $false
    }
}

#endregion

#region Core Functions

function Initialize-DellModule {
    <#
    .SYNOPSIS
        Ensures Dell Command Update is available
    .DESCRIPTION
        Checks if Dell Command Update is installed. If not, automatically
        downloads and installs it from Dell's website.
    .OUTPUTS
        Path to dcu-cli.exe
    .EXAMPLE
        $dcuPath = Initialize-DellModule
    #>
    [CmdletBinding()]
    param()
    
    $dcuPath = Get-DellCommandUpdatePath
    
    if (-not $dcuPath) {
        Write-DriverLog -Message "Dell Command Update not found, installing..." -Severity Info
        
        try {
            Install-DellCommandUpdate
            
            # Wait a moment for installation to complete
            Start-Sleep -Seconds 2
            
            # Re-check for DCU
            $dcuPath = Get-DellCommandUpdatePath
            
            if (-not $dcuPath) {
                throw "Dell Command Update installation completed but dcu-cli.exe not found"
            }
            
            Write-DriverLog -Message "Dell Command Update ready at: $dcuPath" -Severity Info
        }
        catch {
            Write-DriverLog -Message "Failed to initialize Dell Command Update: $($_.Exception.Message)" -Severity Error
            throw "Dell Command Update could not be installed: $($_.Exception.Message)"
        }
    }
    
    return $dcuPath
}

function Get-DellDriverUpdates {
    <#
    .SYNOPSIS
        Scans for available Dell driver updates
    .DESCRIPTION
        Uses Dell Command Update to scan for applicable updates
    .PARAMETER UpdateTypes
        Types of updates to scan for: Driver, BIOS, Firmware, All
    .PARAMETER Severity
        Severity levels: Critical, Recommended, Optional
    .EXAMPLE
        Get-DellDriverUpdates -UpdateTypes Driver -Severity Critical, Recommended
    .OUTPUTS
        Array of available update objects
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'All')]
        [string[]]$UpdateTypes = @('Driver'),
        
        [Parameter()]
        [ValidateSet('Critical', 'Recommended', 'Optional')]
        [string[]]$Severity = @('Critical', 'Recommended')
    )
    
    try {
        $dcuCli = Initialize-DellModule
    }
    catch {
        Write-DriverLog -Message "Dell Command Update not available: $($_.Exception.Message)" -Severity Warning
        return @()
    }
    
    $reportPath = "$env:ProgramData\Dell\UpdateScan"
    if (-not (Test-Path $reportPath)) {
        New-Item -Path $reportPath -ItemType Directory -Force | Out-Null
    }
    
    Write-DriverLog -Message "Scanning for Dell updates" -Severity Info
    
    # Run scan
    $scanArgs = @('/scan', '-silent', "-report=$reportPath")
    $scanResult = & $dcuCli @scanArgs 2>&1
    $scanExitCode = $LASTEXITCODE
    
    # Log exit code info
    $exitInfo = Get-DCUExitInfo -ExitCode $scanExitCode
    Write-DriverLog -Message "DCU scan completed: $($exitInfo.Description)" -Severity Info
    
    # Parse results
    $xmlPath = Join-Path $reportPath "DCUApplicableUpdates.xml"
    if (-not (Test-Path $xmlPath)) {
        Write-DriverLog -Message "No updates report generated" -Severity Info
        return @()
    }
    
    [xml]$updatesXml = Get-Content $xmlPath
    
    $updates = $updatesXml.updates.update | Where-Object {
        $typeMatch = switch ($_.type) {
            'Driver' { 'Driver' -in $UpdateTypes -or 'All' -in $UpdateTypes }
            'BIOS' { 'BIOS' -in $UpdateTypes -or 'All' -in $UpdateTypes }
            'Firmware' { 'Firmware' -in $UpdateTypes -or 'All' -in $UpdateTypes }
            default { 'All' -in $UpdateTypes }
        }
        $typeMatch
    } | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.name
            Version = $_.version
            Type = $_.type
            Category = $_.category
            Urgency = $_.urgency
            ReleaseDate = $_.date
            Size = $_.size
            Description = $_.description
        }
    }
    
    Write-DriverLog -Message "Found $($updates.Count) Dell updates" -Severity Info `
        -Context @{ Updates = ($updates | Select-Object Name, Version, Type) }
    
    return $updates
}

function Install-DellDriverUpdates {
    <#
    .SYNOPSIS
        Installs Dell driver updates
    .DESCRIPTION
        Uses Dell Command Update to install applicable updates
    .PARAMETER UpdateTypes
        Types of updates to install
    .PARAMETER Severity
        Severity levels to include
    .PARAMETER NoReboot
        Suppress automatic reboot
    .EXAMPLE
        Install-DellDriverUpdates -UpdateTypes Driver -NoReboot
    .OUTPUTS
        DriverUpdateResult object
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'All')]
        [string[]]$UpdateTypes = @('Driver'),
        
        [Parameter()]
        [ValidateSet('Critical', 'Recommended', 'Optional')]
        [string[]]$Severity = @('Critical', 'Recommended'),
        
        [Parameter()]
        [switch]$NoReboot
    )
    
    Assert-Elevation -Operation "Installing Dell drivers"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    try {
        $dcuCli = Initialize-DellModule
    }
    catch {
        $result.Success = $false
        $result.Message = "Dell Command Update not available: $($_.Exception.Message)"
        $result.ExitCode = 1
        Write-DriverLog -Message $result.Message -Severity Error
        return $result
    }
    
    # Configure DCU for silent operation
    $configArgs = @('/configure', '-userConsent=disable', '-autoSuspendBitLocker=enable', '-silent')
    & $dcuCli @configArgs 2>&1 | Out-Null
    
    # Map update types
    $typeParam = ($UpdateTypes | ForEach-Object { $_.ToLower() }) -join ','
    if ('All' -in $UpdateTypes) { $typeParam = 'driver,bios,firmware,application' }

    # Map severity to Dell DCU-supported values.
    # Dell docs for DCU 5.x list updateSeverity values like: security,recommended,optional.
    $dellSeverity = @()
    foreach ($s in @($Severity)) {
        switch ($s) {
            'Critical' { $dellSeverity += 'security' }
            'Recommended' { $dellSeverity += 'recommended' }
            'Optional' { $dellSeverity += 'optional' }
        }
    }
    $dellSeverity = @($dellSeverity | Where-Object { $_ } | Select-Object -Unique)
    if ($dellSeverity.Count -eq 0) { $dellSeverity = @('security', 'recommended') }
    $severityParam = ($dellSeverity -join ',')

    # Prepare report/log locations for scan -> apply flow
    $reportPath = Join-Path $env:ProgramData 'Dell\\UpdateScan'
    if (-not (Test-Path $reportPath)) { New-Item -Path $reportPath -ItemType Directory -Force | Out-Null }
    $applicableXml = Join-Path $reportPath 'DCUApplicableUpdates.xml'
    
    # Build apply command
    $applyArgs = @(
        '/applyUpdates'
        "-updateType=$typeParam"
        "-updateSeverity=$severityParam"
        '-autoSuspendBitLocker=enable'
        '-silent'
        "-outputLog=$env:ProgramData\Dell\Logs\DCU_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    )
    
    if ($NoReboot) {
        $applyArgs += '-reboot=disable'
    }
    
    if ($PSCmdlet.ShouldProcess("Dell drivers", "Install updates")) {
        Write-DriverLog -Message "Scanning for Dell updates: Type=$typeParam Severity=$severityParam" -Severity Info

        # Pre-flight diagnostics that help explain "privilege" failures even when elevated.
        $svcDiag = Ensure-DellClientManagementServiceInternal
        $programDataDell = Join-Path $env:ProgramData 'Dell'
        $programDataDellLogs = Join-Path $programDataDell 'Logs'
        $pdDellWritable = Test-WriteAccessInternal -Path $programDataDell
        $pdDellLogsWritable = Test-WriteAccessInternal -Path $programDataDellLogs
        $isElevated = Test-IsElevated

        # Always run /scan first (more reliable than /applyUpdates directly; also generates the applicable updates report)
        # IMPORTANT: Delete stale applicable updates XML before scanning. This prevents trusting cached results
        # from previous scans with different filters (e.g., a previous scan found a BIOS update but current scan
        # is for drivers only). Without this, the code may see ApplicableUpdatesCount > 0 from stale XML
        # even when the current scan returns exit code 6 (no updates found).
        if (Test-Path $applicableXml) {
            try { Remove-Item -Path $applicableXml -Force -ErrorAction SilentlyContinue } catch { }
        }

        $scanLog = Join-Path $programDataDellLogs ("DCU_Scan_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $scanArgs = @(
            '/scan'
            "-updateType=$typeParam"
            "-updateSeverity=$severityParam"
            '-silent'
            "-report=$reportPath"
            "-outputLog=$scanLog"
        )

        $scanResult = & $dcuCli @scanArgs 2>&1
        $scanExitCode = $LASTEXITCODE

        # Retry once if DCU reports it's already running
        if ($scanExitCode -eq 12) {
            Write-DriverLog -Message "DCU scan reported another instance running. Waiting 10s and retrying once..." -Severity Warning
            Start-Sleep -Seconds 10
            $scanResult = & $dcuCli @scanArgs 2>&1
            $scanExitCode = $LASTEXITCODE
        }

        $scanExitInfo = Get-DCUExitInfo -ExitCode $scanExitCode
        Write-DriverLog -Message "DCU scan completed: $($scanExitInfo.Description) (Exit: $scanExitCode)" -Severity Info

        # If scan produced a report, use it to decide whether to run apply.
        # IMPORTANT: If scan returned exit code 6 (no update info), do NOT trust the XML - it could be stale.
        $applicableCount = 0
        try {
            if ($scanExitCode -notin @(6, 18, 500) -and (Test-Path $applicableXml)) {
                [xml]$updatesXml = Get-Content $applicableXml -ErrorAction Stop
                $nodes = @($updatesXml.updates.update)
                $applicableCount = $nodes.Count
            }
        }
        catch {
            Write-DriverLog -Message "Failed to parse DCU applicable updates report: $($_.Exception.Message)" -Severity Warning
        }

        # If scan indicates no updates (or no report / no update info), exit cleanly.
        $scanOutputStr = $scanResult | Out-String
        if ($scanExitCode -in @(6, 18, 500) -or ($applicableCount -eq 0 -and $scanOutputStr -match 'No update information found|No update filters found')) {
            $result.Success = $true
            $result.Message = "No applicable updates"
            $result.RebootRequired = $false
            $result.UpdatesApplied = 0
            $result.ExitCode = 0
            $result.Details = @{
                DCUScanExitCode = $scanExitCode
                DCUScanExitInfo = $scanExitInfo
                ApplicableUpdatesCount = $applicableCount
                Elevated = $isElevated
                Service = $svcDiag
                ProgramDataDellWritable = $pdDellWritable
                ProgramDataDellLogsWritable = $pdDellLogsWritable
            }
            Write-DriverLog -Message "Dell update complete: $($result.Message)" -Severity Info -Context $result.ToHashtable()
            return $result
        }

        Write-DriverLog -Message "Applying Dell updates: Type=$typeParam Severity=$severityParam (Applicable: $applicableCount)" -Severity Info

        $applyResult = & $dcuCli @applyArgs 2>&1
        $exitCode = $LASTEXITCODE

        # Retry once if DCU reports it's already running
        if ($exitCode -eq 12) {
            Write-DriverLog -Message "DCU apply reported another instance running. Waiting 10s and retrying once..." -Severity Warning
            Start-Sleep -Seconds 10
            $applyResult = & $dcuCli @applyArgs 2>&1
            $exitCode = $LASTEXITCODE
        }

        # Retry once on privilege-related exit codes after ensuring service/write access.
        if ($exitCode -in @(4, 5)) {
            Write-DriverLog -Message "DCU returned exit code $exitCode. Elevated=$isElevated. Retrying once after service/permission checks..." -Severity Warning `
                -Context @{ DCUExitCode = $exitCode; Elevated = $isElevated; Service = $svcDiag; ProgramDataDellWritable = $pdDellWritable; ProgramDataDellLogsWritable = $pdDellLogsWritable }

            $svcDiag = Ensure-DellClientManagementServiceInternal
            $pdDellWritable = Test-WriteAccessInternal -Path $programDataDell
            $pdDellLogsWritable = Test-WriteAccessInternal -Path $programDataDellLogs

            $applyResult = & $dcuCli @applyArgs 2>&1
            $exitCode = $LASTEXITCODE
        }

        # Get detailed exit info
        $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
        
        # Interpret exit codes
        # Note: DCU sometimes returns exit code 5 (admin privilege) when the real issue
        # is a pending reboot. We parse the output to detect this and report accurately.
        $dcuOutputStr = $applyResult | Out-String
        
        switch ($exitCode) {
            0 {
                $result.Success = $true
                $result.Message = "Updates applied successfully"
                $result.RebootRequired = $false
                $result.UpdatesApplied = 1
            }
            1 {
                $result.Success = $true
                $result.Message = "Updates applied - reboot required"
                $result.RebootRequired = $true
                $result.UpdatesApplied = 1
            }
            { $_ -in @(500, 18) } {
                $result.Success = $true
                $result.Message = "No applicable updates"
                $result.RebootRequired = $false
                $result.UpdatesApplied = 0
            }
            6 {
                # DCU exit code 6 is documented as "No update information found".
                # In practice DCU does not always emit that string to STDOUT/STDERR, so regex-only detection
                # can incorrectly classify "no updates" as a hard failure and spam Write-Error.
                #
                # If the scan report indicates applicable updates, treat this as a real failure.
                # Otherwise treat it as a benign "no applicable updates" outcome.
                if ($applicableCount -gt 0) {
                    $result.Success = $false
                    $result.Message = "DCU scan reported $applicableCount applicable update(s) but /applyUpdates returned exit code 6 ($($exitInfo.Description)). $($exitInfo.Resolution)"
                    $result.RebootRequired = $false
                    $result.UpdatesFailed = 1
                }
                else {
                    $result.Success = $true
                    $result.Message = "No applicable updates"
                    $result.RebootRequired = $false
                    $result.UpdatesApplied = 0
                }
            }
            5 {
                # Exit code 5 can mean admin privilege OR pending reboot (DCU bug)
                # Check actual output to determine the real issue
                if ($dcuOutputStr -match 'reboot|restart') {
                    $result.Success = $false
                    $result.Message = "System reboot pending - please restart the computer and try again"
                    $result.RebootRequired = $true
                }
                else {
                    $result.Success = $false
                    $result.Message = "$($exitInfo.Description) - $($exitInfo.Resolution)"
                    $result.RebootRequired = $false
                }
            }
            3006 {
                # System is in Windows OOBE (Out of Box Experience) - DCU is blocked
                # Fall back to direct driver pack installation
                Write-DriverLog -Message "DCU blocked by OOBE state - falling back to direct driver pack installation" -Severity Warning
                
                $directResult = Install-DellDriverPackDirect -NoReboot:$NoReboot
                
                $result.Success = $directResult.Success
                $result.Message = $directResult.Message
                $result.UpdatesApplied = $directResult.UpdatesApplied
                $result.UpdatesFailed = $directResult.UpdatesFailed
                $result.RebootRequired = $directResult.RebootRequired
                $result.Details['DirectInstall'] = $true
            }
            default {
                $result.Success = $false
                # Include the actual exit code in the message for better debugging
                $result.Message = "$($exitInfo.Description) (DCU exit code: $exitCode) - $($exitInfo.Resolution)"
                $result.RebootRequired = $false
                $result.UpdatesFailed = 1
            }
        }
        
        $result.ExitCode = if ($result.RebootRequired) { 3010 } elseif ($result.Success) { 0 } else { 1 }
        $result.Details = @{
            DCUScanExitCode = $scanExitCode
            DCUScanExitInfo = $scanExitInfo
            ApplicableUpdatesCount = $applicableCount
            DCUExitCode = $exitCode
            DCUExitInfo = $exitInfo
            Elevated = $isElevated
            Service = $svcDiag
            ProgramDataDellWritable = $pdDellWritable
            ProgramDataDellLogsWritable = $pdDellLogsWritable
        }
        
        $sev = if ($result.Success) { 'Info' } else { 'Error' }
        Write-DriverLog -Message "Dell update complete: $($result.Message)" -Severity $sev `
            -Context $result.ToHashtable()
    }
    
    return $result
}

function Install-DellFullDriverPack {
    <#
    .SYNOPSIS
        Installs the complete Dell driver pack
    .DESCRIPTION
        Performs a full driver reinstallation using Dell Command Update
    .PARAMETER NoReboot
        Suppress automatic reboot
    .EXAMPLE
        Install-DellFullDriverPack -NoReboot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [switch]$NoReboot
    )
    
    Assert-Elevation -Operation "Installing Dell full driver pack"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    try {
        $dcuCli = Initialize-DellModule
    }
    catch {
        $result.Success = $false
        $result.Message = "Dell Command Update not available: $($_.Exception.Message)"
        $result.ExitCode = 1
        Write-DriverLog -Message $result.Message -Severity Error
        return $result
    }
    
    if ($PSCmdlet.ShouldProcess("Dell full driver pack", "Install")) {
        Write-DriverLog -Message "Starting Dell full driver pack install" -Severity Info
        
        $installArgs = @(
            '/driverInstall'
            '-autoSuspendBitLocker=enable'
            '-silent'
        )
        
        if ($NoReboot) {
            $installArgs += '-reboot=disable'
        }
        
        & $dcuCli @installArgs 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
        
        $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
        
        $result.Success = $exitCode -in @(0, 1, 500, 18)
        $result.Message = "$($exitInfo.Description)"
        $result.RebootRequired = $exitCode -eq 1
        $result.ExitCode = if ($exitCode -eq 1) { 3010 } elseif ($exitCode -in @(0, 500, 18)) { 0 } else { 1 }
        $result.Details = @{ DCUExitCode = $exitCode; DCUExitInfo = $exitInfo }
        
        Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    }
    
    return $result
}

#endregion
