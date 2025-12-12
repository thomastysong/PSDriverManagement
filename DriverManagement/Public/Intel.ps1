#Requires -Version 5.1

<#
.SYNOPSIS
    Intel driver management functions
.DESCRIPTION
    Provides detection, installation, and management of Intel drivers.
    Uses catalog-based approach since Intel DSA has no CLI/API support.
.NOTES
    Intel vendor ID: VEN_8086
    Device IDs follow pattern: PCI\VEN_8086&DEV_XXXX
#>

#region Intel Device Detection

function Get-IntelDevices {
    <#
    .SYNOPSIS
        Detects Intel devices on the system
    .DESCRIPTION
        Queries Win32_PnPSignedDriver for devices manufactured by Intel.
        Groups devices by device class (Display, Network, Audio, etc.)
    .PARAMETER DeviceClass
        Filter by device class (e.g., 'Display', 'Net', 'Media')
    .EXAMPLE
        Get-IntelDevices
    .EXAMPLE
        Get-IntelDevices -DeviceClass 'Display'
    .OUTPUTS
        Array of Intel device objects with DeviceID, DeviceName, DeviceClass, DriverVersion
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DeviceClass
    )
    
    try {
        # Query PnP signed drivers for Intel devices
        # Intel vendor ID is 8086, or Manufacturer contains "Intel"
        $devices = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            if (-not $_.DeviceID) { return $false }
            
            # Check for Intel vendor ID (VEN_8086) or Manufacturer contains Intel
            $isIntel = ($_.DeviceID -match 'VEN_8086') -or 
                      ($_.Manufacturer -like '*Intel*') -or
                      ($_.DriverProviderName -like '*Intel*')
            
            # Filter by device class if specified
            if ($DeviceClass -and $isIntel) {
                return $_.DeviceClass -like "*$DeviceClass*"
            }
            
            return $isIntel
        }
        
        $intelDevices = $devices | ForEach-Object {
            [PSCustomObject]@{
                DeviceID       = $_.DeviceID
                DeviceName     = $_.DeviceName
                DeviceClass    = $_.DeviceClass
                Manufacturer   = $_.Manufacturer
                DriverVersion  = $_.DriverVersion
                DriverDate     = $_.DriverDate
                InfName        = $_.InfName
                DriverProviderName = $_.DriverProviderName
                IsSigned       = $_.IsSigned
                HardwareID     = $_.HardwareID
            }
        }
        
        Write-DriverLog -Message "Detected $($intelDevices.Count) Intel devices" -Severity Info `
            -Context @{ DeviceCount = $intelDevices.Count; DeviceClasses = ($intelDevices.DeviceClass | Sort-Object -Unique) }
        
        return $intelDevices
    }
    catch {
        Write-DriverLog -Message "Failed to detect Intel devices: $($_.Exception.Message)" -Severity Error
        return @()
    }
}

#endregion

#region Intel Driver Catalog

function Get-IntelDriverCatalog {
    <#
    .SYNOPSIS
        Loads the Intel driver catalog from JSON
    .DESCRIPTION
        Loads the catalog file from Config/intel_drivers.json
    .OUTPUTS
        Hashtable with drivers array
    #>
    [CmdletBinding()]
    param()
    
    $catalogPath = Join-Path $script:ModuleRoot "Config\intel_drivers.json"
    
    if (-not (Test-Path $catalogPath)) {
        Write-DriverLog -Message "Intel driver catalog not found: $catalogPath" -Severity Warning
        return @{ drivers = @() }
    }
    
    try {
        $catalog = Get-Content -Path $catalogPath -Raw | ConvertFrom-Json
        return @{
            drivers = $catalog.drivers
            lastUpdated = if ($catalog.lastUpdated) { $catalog.lastUpdated } else { $null }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to load Intel driver catalog: $($_.Exception.Message)" -Severity Error
        return @{ drivers = @() }
    }
}

function Match-IntelDeviceToCatalog {
    <#
    .SYNOPSIS
        Matches an Intel device to catalog entries
    .DESCRIPTION
        Matches device by DeviceID, HardwareID, or device class
    .PARAMETER Device
        Intel device object from Get-IntelDevices
    .PARAMETER Catalog
        Catalog object from Get-IntelDriverCatalog
    .OUTPUTS
        Matching catalog entries
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Device,
        
        [Parameter(Mandatory)]
        [hashtable]$Catalog
    )
    
    $catalogMatches = @()
    
    foreach ($driver in $Catalog.drivers) {
        $isMatch = $false
        
        # Match by device IDs
        if ($driver.deviceIds) {
            foreach ($deviceId in $driver.deviceIds) {
                # Support wildcard matching (e.g., PCI\VEN_8086&DEV_*)
                # Escape special regex characters first, then replace wildcards
                $escaped = [regex]::Escape($deviceId)
                $pattern = $escaped -replace '\\\*', '.*' -replace '\\\?', '.'
                try {
                    if ($Device.DeviceID -match $pattern -or $Device.HardwareID -match $pattern) {
                        $isMatch = $true
                        break
                    }
                }
                catch {
                    # Invalid regex pattern - skip this device ID
                    Write-DriverLog -Message "Invalid device ID pattern: $deviceId - $($_.Exception.Message)" -Severity Warning
                }
            }
        }
        
        # Match by device class
        if (-not $isMatch -and $driver.deviceClass -and $Device.DeviceClass) {
            if ($Device.DeviceClass -like "*$($driver.deviceClass)*") {
                $isMatch = $true
            }
        }
        
        if ($isMatch) {
            $catalogMatches += $driver
        }
    }
    
    return $catalogMatches
}

#endregion

#region Intel Driver Update Detection

function Get-IntelDriverUpdates {
    <#
    .SYNOPSIS
        Scans for available Intel driver updates
    .DESCRIPTION
        Compares installed Intel drivers with catalog entries to find updates.
        Uses catalog-based approach since Intel DSA has no CLI support.
    .PARAMETER DeviceClass
        Filter by device class
    .EXAMPLE
        Get-IntelDriverUpdates
    .EXAMPLE
        Get-IntelDriverUpdates -DeviceClass 'Display'
    .OUTPUTS
        Array of available update objects
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DeviceClass
    )
    
    Write-DriverLog -Message "Scanning for Intel driver updates" -Severity Info
    
    # Get installed Intel devices
    $devices = Get-IntelDevices -DeviceClass $DeviceClass
    
    if ($devices.Count -eq 0) {
        Write-DriverLog -Message "No Intel devices detected" -Severity Info
        return @()
    }
    
    # Load catalog
    $catalog = Get-IntelDriverCatalog
    
    if ($catalog.drivers.Count -eq 0) {
        Write-DriverLog -Message "Intel driver catalog is empty" -Severity Warning
        return @()
    }
    
    $updates = @()
    
    foreach ($device in $devices) {
        # Find matching catalog entries
        $catalogEntries = Match-IntelDeviceToCatalog -Device $device -Catalog $catalog
        
        foreach ($entry in $catalogEntries) {
            # Compare versions
            $installedVersion = $device.DriverVersion
            $availableVersion = $entry.driverVersion
            
            if (-not $installedVersion -or -not $availableVersion) {
                continue
            }
            
            # Try version comparison
            $needsUpdate = $false
            try {
                $installed = [version]$installedVersion
                $available = [version]$availableVersion
                $needsUpdate = $available -gt $installed
            }
            catch {
                # Fallback to string comparison
                $needsUpdate = $availableVersion -ne $installedVersion
            }
            
            if ($needsUpdate) {
                $updates += [PSCustomObject]@{
                    DeviceID         = $device.DeviceID
                    DeviceName       = $device.DeviceName
                    DeviceClass      = $device.DeviceClass
                    InstalledVersion = $installedVersion
                    AvailableVersion = $availableVersion
                    DownloadUrl      = $entry.downloadUrl
                    ReleaseDate      = $entry.releaseDate
                    Severity         = if ($entry.severity) { $entry.severity } else { 'Recommended' }
                    Description      = if ($entry.description) { $entry.description } else { "Intel $($device.DeviceClass) Driver Update" }
                    CatalogEntry     = $entry
                }
            }
        }
    }
    
    Write-DriverLog -Message "Found $($updates.Count) Intel driver updates" -Severity Info `
        -Context @{ Updates = ($updates | Select-Object DeviceName, InstalledVersion, AvailableVersion) }
    
    return $updates
}

#endregion

#region Intel Driver Installation

function Install-IntelDriverUpdates {
    <#
    .SYNOPSIS
        Installs Intel driver updates
    .DESCRIPTION
        Downloads and installs Intel driver updates from catalog URLs.
        Creates driver snapshot before installation for rollback capability.
    .PARAMETER DeviceClass
        Filter by device class (only install updates for specific class)
    .PARAMETER NoReboot
        Suppress automatic reboot
    .PARAMETER Force
        Force installation even if version check fails
    .EXAMPLE
        Install-IntelDriverUpdates
    .EXAMPLE
        Install-IntelDriverUpdates -DeviceClass 'Display' -NoReboot
    .OUTPUTS
        DriverUpdateResult object
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [string]$DeviceClass,
        
        [Parameter()]
        [switch]$NoReboot,
        
        [Parameter()]
        [switch]$Force
    )
    
    Assert-Elevation -Operation "Installing Intel drivers"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    # Get available updates
    $updates = Get-IntelDriverUpdates -DeviceClass $DeviceClass
    
    if ($updates.Count -eq 0) {
        $result.Success = $true
        $result.Message = "No Intel driver updates available"
        $result.ExitCode = 0
        Write-DriverLog -Message $result.Message -Severity Info
        return $result
    }
    
    # Create driver snapshot before installation
    try {
        $snapshotName = "Pre-Intel-Update-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Write-DriverLog -Message "Creating driver snapshot: $snapshotName" -Severity Info
        $snapshot = New-DriverSnapshot -Name $snapshotName -IncludeInfFiles
        $result.Details['PreUpdateSnapshot'] = $snapshot.ID
    }
    catch {
        Write-DriverLog -Message "Failed to create snapshot: $($_.Exception.Message)" -Severity Warning
        if (-not $Force) {
            $result.Success = $false
            $result.Message = "Failed to create driver snapshot - aborting (use -Force to override)"
            $result.ExitCode = 1
            return $result
        }
    }
    
    if ($PSCmdlet.ShouldProcess("$($updates.Count) Intel driver updates", "Install")) {
        $installed = 0
        $failed = 0
        $rebootRequired = $false
        
        foreach ($update in $updates) {
            Write-DriverLog -Message "Installing: $($update.DeviceName) ($($update.InstalledVersion) -> $($update.AvailableVersion))" -Severity Info
            
            try {
                # Download driver
                $tempPath = Join-Path $env:TEMP "IntelDriver_$(Get-Random)"
                New-Item -Path $tempPath -ItemType Directory -Force | Out-Null
                
                $driverFile = Join-Path $tempPath (Split-Path $update.DownloadUrl -Leaf)
                
                Write-DriverLog -Message "Downloading from: $($update.DownloadUrl)" -Severity Info
                
                try {
                    Invoke-WebRequest -Uri $update.DownloadUrl -OutFile $driverFile -UseBasicParsing -ErrorAction Stop
                }
                catch {
                    # Try with certificate validation bypass for some Intel URLs
                    $originalCertPolicy = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                    try {
                        Invoke-WebRequest -Uri $update.DownloadUrl -OutFile $driverFile -UseBasicParsing -ErrorAction Stop
                    }
                    finally {
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCertPolicy
                    }
                }
                
                # Extract if it's a ZIP
                if ($driverFile -match '\.zip$') {
                    $extractPath = Join-Path $tempPath "extracted"
                    Expand-Archive -Path $driverFile -DestinationPath $extractPath -Force
                    
                    # Find INF file or installer
                    $infFiles = Get-ChildItem -Path $extractPath -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue
                    $installerExe = Get-ChildItem -Path $extractPath -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | 
                        Where-Object { $_.Name -match 'setup|install|driver' } | Select-Object -First 1
                    
                    if ($infFiles) {
                        # Install via pnputil
                        foreach ($infFile in $infFiles) {
                            $pnputilResult = & pnputil /add-driver "$($infFile.FullName)" /install 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $installed++
                                Write-DriverLog -Message "Installed via pnputil: $($infFile.Name)" -Severity Info
                            }
                            else {
                                $failed++
                                Write-DriverLog -Message "pnputil failed for $($infFile.Name): exit $LASTEXITCODE" -Severity Warning
                            }
                        }
                    }
                    elseif ($installerExe) {
                        # Run installer silently
                        $installArgs = @('/S', '/SILENT', '/VERYSILENT', '/quiet', '/qn')
                        $installResult = Start-Process -FilePath $installerExe.FullName -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
                        
                        if ($installResult.ExitCode -eq 0 -or $installResult.ExitCode -eq 3010) {
                            $installed++
                            if ($installResult.ExitCode -eq 3010) {
                                $rebootRequired = $true
                            }
                            Write-DriverLog -Message "Installer completed: exit $($installResult.ExitCode)" -Severity Info
                        }
                        else {
                            $failed++
                            Write-DriverLog -Message "Installer failed: exit $($installResult.ExitCode)" -Severity Warning
                        }
                    }
                    else {
                        Write-DriverLog -Message "No INF or installer found in driver package" -Severity Warning
                        $failed++
                    }
                }
                elseif ($driverFile -match '\.exe$') {
                    # Direct installer
                    $installArgs = @('/S', '/SILENT', '/VERYSILENT', '/quiet', '/qn')
                    $installResult = Start-Process -FilePath $driverFile -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
                    
                    if ($installResult.ExitCode -eq 0 -or $installResult.ExitCode -eq 3010) {
                        $installed++
                        if ($installResult.ExitCode -eq 3010) {
                            $rebootRequired = $true
                        }
                    }
                    else {
                        $failed++
                    }
                }
                else {
                    Write-DriverLog -Message "Unsupported driver file format: $driverFile" -Severity Warning
                    $failed++
                }
                
                # Cleanup
                Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                $failed++
                Write-DriverLog -Message "Failed to install $($update.DeviceName): $($_.Exception.Message)" -Severity Error
            }
        }
        
        $result.Success = ($failed -eq 0)
        $result.Message = "Installed $installed Intel driver updates"
        if ($failed -gt 0) {
            $result.Message += ", $failed failed"
        }
        $result.UpdatesApplied = $installed
        $result.UpdatesFailed = $failed
        $result.RebootRequired = $rebootRequired -and (-not $NoReboot)
        $result.ExitCode = if ($result.RebootRequired) { 3010 } elseif ($result.Success) { 0 } else { 1 }
        
        Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    }
    
    return $result
}

#endregion

#region Intel Module Initialization

function Initialize-IntelModule {
    <#
    .SYNOPSIS
        Initializes Intel driver management
    .DESCRIPTION
        Checks for Intel devices, loads catalog, and validates configuration.
    .OUTPUTS
        PSCustomObject with initialization status
    #>
    [CmdletBinding()]
    param()
    
    $status = [PSCustomObject]@{
        Initialized     = $false
        DevicesDetected = 0
        CatalogLoaded   = $false
        CatalogPath     = $null
        Message         = ""
    }
    
    # Detect Intel devices
    $devices = Get-IntelDevices
    $status.DevicesDetected = $devices.Count
    
    # Load catalog
    $catalogPath = Join-Path $script:ModuleRoot "Config\intel_drivers.json"
    $status.CatalogPath = $catalogPath
    
    if (Test-Path $catalogPath) {
        $catalog = Get-IntelDriverCatalog
        $status.CatalogLoaded = ($catalog.drivers.Count -gt 0)
        
        if ($status.CatalogLoaded) {
            $status.Message = "Intel module initialized: $($status.DevicesDetected) devices, $($catalog.drivers.Count) catalog entries"
        }
        else {
            $status.Message = "Intel module initialized: $($status.DevicesDetected) devices, but catalog is empty"
        }
    }
    else {
        $status.Message = "Intel module initialized: $($status.DevicesDetected) devices, but catalog not found at $catalogPath"
    }
    
    $status.Initialized = $true
    
    Write-DriverLog -Message $status.Message -Severity Info -Context $status
    
    return $status
}

#endregion

