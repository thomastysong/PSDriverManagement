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
    0   = @{ Description = "Command execution successful"; Resolution = "None required" }
    1   = @{ Description = "Reboot required"; Resolution = "Reboot the system to complete updates" }
    2   = @{ Description = "Unknown application error"; Resolution = "Check DCU logs for details" }
    3   = @{ Description = "Incomplete command line"; Resolution = "Verify command syntax" }
    4   = @{ Description = "Invalid command line option"; Resolution = "Check available options" }
    5   = @{ Description = "Unable to get admin privilege"; Resolution = "Run as administrator" }
    6   = @{ Description = "No update filters found"; Resolution = "Check update type/severity filters" }
    7   = @{ Description = "Duplicate command line option"; Resolution = "Remove duplicate options" }
    8   = @{ Description = "Cannot create the scheduled task"; Resolution = "Check Task Scheduler permissions" }
    9   = @{ Description = "Cannot remove the scheduled task"; Resolution = "Check Task Scheduler permissions" }
    10  = @{ Description = "Download failed, no update(s) to apply"; Resolution = "Check network connectivity" }
    11  = @{ Description = "Suspend Bitlocker failed"; Resolution = "Manually suspend BitLocker" }
    12  = @{ Description = "Another instance of DCU running"; Resolution = "Wait for other instance to complete" }
    13  = @{ Description = "Invalid catalog file"; Resolution = "Re-download or regenerate catalog" }
    14  = @{ Description = "Unable to schedule updates"; Resolution = "Check scheduled task configuration" }
    15  = @{ Description = "Invalid export file format"; Resolution = "Check export file path/format" }
    16  = @{ Description = "Invalid password"; Resolution = "Verify BIOS password" }
    17  = @{ Description = "System is not supported"; Resolution = "Verify Dell system compatibility" }
    18  = @{ Description = "No updates available"; Resolution = "System is up to date" }
    19  = @{ Description = "Network error"; Resolution = "Check network connectivity to Dell servers" }
    20  = @{ Description = "Catalog sync failed"; Resolution = "Check internet connectivity" }
    21  = @{ Description = "Running in OS pre-boot"; Resolution = "Run after Windows boot completes" }
    500 = @{ Description = "No updates available"; Resolution = "System is up to date" }
    501 = @{ Description = "Soft dependency error"; Resolution = "Check for prerequisite updates" }
    502 = @{ Description = "Hard dependency error"; Resolution = "Install prerequisite updates first" }
    503 = @{ Description = "Already running"; Resolution = "Wait for other DCU instance" }
    504 = @{ Description = "System reboot pending"; Resolution = "Reboot system first" }
    505 = @{ Description = "Rollback"; Resolution = "Update failed and was rolled back" }
    506 = @{ Description = "Update failed"; Resolution = "Check DCU logs for failure details" }
    507 = @{ Description = "Download progress"; Resolution = "Update is still downloading" }
    508 = @{ Description = "Install progress"; Resolution = "Update is still installing" }
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
        Downloads and installs Dell Command Update
    .DESCRIPTION
        Automatically downloads the latest Dell Command Update from Dell's website
        and performs a silent installation. Checks if update is needed first.
    .PARAMETER Force
        Install even if current version is up to date
    .PARAMETER Version
        Specific version to install (default: latest)
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
    
    $config = $script:ModuleConfig
    
    # Check if update is needed
    if (-not $Force) {
        $installed = Get-DCUInstallDetails
        
        if ($installed.IsInstalled) {
            $latestInfo = Get-LatestDCUVersion -CheckUpdate
            
            if (-not $latestInfo.UpdateAvailable) {
                Write-DriverLog -Message "Dell Command Update is already up to date (v$($installed.Version))" -Severity Info
                return
            }
            
            Write-DriverLog -Message "Update available: $($installed.Version) -> $($latestInfo.Version)" -Severity Info
        }
    }
    
    # Determine download URL
    # Priority: 1) Environment variable, 2) Module config, 3) Catalog lookup, 4) Default
    $dcuUrl = if ($env:PSDM_DCU_URL) {
        Write-DriverLog -Message "Using DCU URL from environment variable" -Severity Info
        $env:PSDM_DCU_URL
    } elseif ($config.DellCommandUpdateUrl) {
        $config.DellCommandUpdateUrl
    } else {
        # Try to get from catalog
        $latestInfo = Get-LatestDCUVersion
        if ($latestInfo.DownloadUrl) {
            $latestInfo.DownloadUrl
        } else {
            "https://dl.dell.com/FOLDER11914155M/1/Dell-Command-Update-Windows-Universal-Application_601KT_WIN_5.4.0_A00.EXE"
        }
    }
    
    $installerPath = Join-Path $env:TEMP "DellCommandUpdate_$(Get-Date -Format 'yyyyMMddHHmmss').exe"
    
    Write-DriverLog -Message "Downloading Dell Command Update from $dcuUrl" -Severity Info
    
    try {
        # Download with retry logic
        Invoke-WithRetry -ScriptBlock {
            # Use BITS for reliable download, fallback to WebRequest
            try {
                Start-BitsTransfer -Source $dcuUrl -Destination $installerPath -ErrorAction Stop
            }
            catch {
                Invoke-WebRequest -Uri $dcuUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
            }
        } -MaxAttempts 3 -ExponentialBackoff
        
        if (-not (Test-Path $installerPath)) {
            throw "Download failed - installer not found"
        }
        
        $fileSize = (Get-Item $installerPath).Length / 1MB
        Write-DriverLog -Message "Downloaded DCU installer ($([math]::Round($fileSize, 1)) MB)" -Severity Info
        
        # Silent install
        Write-DriverLog -Message "Installing Dell Command Update silently..." -Severity Info
        
        $installProcess = Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait -PassThru -NoNewWindow
        $exitCode = $installProcess.ExitCode
        
        # Interpret exit code
        $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
        
        if ($exitCode -eq 0) {
            Write-DriverLog -Message "Dell Command Update installed successfully" -Severity Info
        }
        elseif ($exitCode -eq 1) {
            Write-DriverLog -Message "Dell Command Update installed - reboot required" -Severity Warning
        }
        else {
            throw "Installation failed: $($exitInfo.Description) (Exit: $exitCode)"
        }
        
        return [PSCustomObject]@{
            Success = $exitCode -in @(0, 1)
            ExitCode = $exitCode
            Message = $exitInfo.Description
            RebootRequired = ($exitCode -eq 1)
        }
    }
    catch {
        Write-DriverLog -Message "Failed to install Dell Command Update: $($_.Exception.Message)" -Severity Error
        throw
    }
    finally {
        # Cleanup installer
        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
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
    
    # Build apply command
    $applyArgs = @(
        '/applyUpdates'
        "-updateType=$typeParam"
        '-updateSeverity=security,critical,recommended'
        '-autoSuspendBitLocker=enable'
        '-silent'
        "-outputLog=$env:ProgramData\Dell\Logs\DCU_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    )
    
    if ($NoReboot) {
        $applyArgs += '-reboot=disable'
    }
    
    if ($PSCmdlet.ShouldProcess("Dell drivers", "Install updates")) {
        Write-DriverLog -Message "Installing Dell updates: $typeParam" -Severity Info
        
        $applyResult = & $dcuCli @applyArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        # Get detailed exit info
        $exitInfo = Get-DCUExitInfo -ExitCode $exitCode
        
        # Interpret exit codes
        switch ($exitCode) {
            0 {
                $result.Success = $true
                $result.Message = "Updates applied successfully"
                $result.RebootRequired = $false
            }
            1 {
                $result.Success = $true
                $result.Message = "Updates applied - reboot required"
                $result.RebootRequired = $true
            }
            { $_ -in @(500, 18) } {
                $result.Success = $true
                $result.Message = "No applicable updates"
                $result.RebootRequired = $false
            }
            default {
                $result.Success = $false
                $result.Message = "$($exitInfo.Description) - $($exitInfo.Resolution)"
                $result.RebootRequired = $false
            }
        }
        
        $result.ExitCode = if ($result.RebootRequired) { 3010 } elseif ($result.Success) { 0 } else { 1 }
        $result.Details = @{ DCUExitCode = $exitCode; DCUExitInfo = $exitInfo }
        
        Write-DriverLog -Message "Dell update complete: $($result.Message)" -Severity Info `
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
