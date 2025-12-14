#Requires -Version 5.1

<#
.SYNOPSIS
    Intel driver management functions
.DESCRIPTION
    Provides detection, installation, and management of Intel drivers.
    Uses Intel DSA's public data feed (dsadata.intel.com) to dynamically identify
    applicable Intel driver packages (Graphics/Wireless) and download them from
    downloadmirror.intel.com.
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

#region Intel Download Helpers (internal)

function Get-IntelDownloadFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        
        [Parameter()]
        [string]$DefaultBaseName = 'intel_driver'
    )
    
    $leaf = $null
    try {
        $u = [uri]$Url
        $leaf = [System.IO.Path]::GetFileName($u.AbsolutePath)
    }
    catch {
        $leaf = Split-Path $Url -Leaf
    }
    
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = "$DefaultBaseName.bin"
    }
    
    # Sanitize invalid filename characters (handles URLs with query strings, etc.)
    $leaf = $leaf -replace '[<>:"/\\|?*]', '_'
    return $leaf
}

#endregion

#region Intel DSA Data Feed (dynamic catalog)

function Get-IntelDsaDataFeedUrl {
    [CmdletBinding()]
    param()
    
    # Small ZIP containing software-configurations.json
    return 'https://dsadata.intel.com/data/en'
}

function Get-IntelDsaCachePath {
    [CmdletBinding()]
    param()
    
    try {
        $base = Join-Path $env:LOCALAPPDATA 'PSDriverManagement\Cache\Intel'
        if (-not (Test-Path $base)) {
            New-Item -Path $base -ItemType Directory -Force | Out-Null
        }
        return $base
    }
    catch {
        $base = Join-Path $env:TEMP 'PSDriverManagement_IntelCache'
        if (-not (Test-Path $base)) {
            New-Item -Path $base -ItemType Directory -Force | Out-Null
        }
        return $base
    }
}

function Get-IntelDsaFeedMetadata {
    <#
    .SYNOPSIS
        Retrieves metadata headers for the Intel DSA data feed ZIP.
    .OUTPUTS
        PSCustomObject with Version, HashSha1, LastModified, ContentLength
    #>
    [CmdletBinding()]
    param()
    
    $url = Get-IntelDsaDataFeedUrl
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -MaximumRedirection 5 -ErrorAction Stop
        return [PSCustomObject]@{
            Url           = $url
            Version       = $r.Headers['X-DSA-Version']
            HashSha1      = $r.Headers['X-DSA-Hash']
            LastModified  = $r.Headers['Last-Modified']
            ContentLength = $r.Headers['Content-Length']
        }
    }
    catch {
        Write-DriverLog -Message "Failed to query Intel DSA feed metadata: $($_.Exception.Message)" -Severity Warning
        return $null
    }
}

function Get-IntelDsaSoftwareConfigurations {
    <#
    .SYNOPSIS
        Loads Intel DSA software configurations (dynamic catalog).
    .DESCRIPTION
        Downloads https://dsadata.intel.com/data/en (idsa-en.zip) and extracts
        software-configurations.json. Uses a small local cache keyed by X-DSA-Hash.
    .OUTPUTS
        Array of PSCustomObject entries (Intel DSA software configurations)
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$ForceRefresh
    )
    
    $meta = Get-IntelDsaFeedMetadata
    if (-not $meta -or -not $meta.HashSha1) {
        return @()
    }
    
    $cacheRoot = Get-IntelDsaCachePath
    $cacheKey = ([string]$meta.HashSha1).ToUpperInvariant()
    $zipPath = Join-Path $cacheRoot "idsa-en-$cacheKey.zip"
    $extractPath = Join-Path $cacheRoot "idsa-en-$cacheKey"
    $jsonPath = Join-Path $extractPath 'software-configurations.json'
    
    if (-not $ForceRefresh -and (Test-Path $jsonPath)) {
        try {
            return (Get-Content -Path $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json)
        }
        catch {
            # fall through to re-download
        }
    }
    
    try {
        Write-DriverLog -Message "Downloading Intel DSA feed (version $($meta.Version))" -Severity Info -Context @{ Url = $meta.Url; HashSha1 = $cacheKey }
        
        # Download ZIP (verify SHA1 using header)
        Start-DownloadWithVerification -SourceUrl $meta.Url -DestinationPath $zipPath -ExpectedHash $cacheKey -HashAlgorithm 'SHA1' | Out-Null
        
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        
        if (-not (Test-Path $jsonPath)) {
            throw "software-configurations.json not found after extraction"
        }
        
        return (Get-Content -Path $jsonPath -Raw | ConvertFrom-Json)
    }
    catch {
        Write-DriverLog -Message "Failed to load Intel DSA software configurations: $($_.Exception.Message)" -Severity Error
        return @()
    }
}

function Get-IntelHardwareTokens {
    <#
    .SYNOPSIS
        Builds a token list (VEN_8086&DEV_xxxx, VID_8087&PID_xxxx, with optional SUBSYS) for matching DSA detection values.
    #>
    [CmdletBinding()]
    param()
    
    $tokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    
    $drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue
    foreach ($d in $drivers) {
        $candidates = @()
        if ($d.DeviceID) { $candidates += [string]$d.DeviceID }
        if ($d.HardwareID) { $candidates += @($d.HardwareID | ForEach-Object { [string]$_ }) }
        
        foreach ($s in $candidates) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            
            # PCI VEN/DEV (+ optional SUBSYS)
            $m = [regex]::Matches($s, 'VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}(?:&SUBSYS_[0-9A-F]{8})?', 'IgnoreCase')
            foreach ($x in $m) { [void]$tokens.Add($x.Value.ToUpperInvariant()) }
            
            # USB VID/PID (+ optional REV)
            $m2 = [regex]::Matches($s, 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}(?:&REV_[0-9A-F]{4})?', 'IgnoreCase')
            foreach ($x in $m2) { [void]$tokens.Add($x.Value.ToUpperInvariant()) }
        }
    }
    
    return @($tokens)
}

function Find-IntelDsaApplicablePackages {
    <#
    .SYNOPSIS
        Finds Intel DSA packages applicable to this machine for Graphics/Wireless.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Graphics','Wireless','All')]
        [string]$Category = 'All'
    )
    
    $tokens = Get-IntelHardwareTokens
    if (-not $tokens -or $tokens.Count -eq 0) { return @() }
    
    $configs = Get-IntelDsaSoftwareConfigurations
    if (-not $configs -or $configs.Count -eq 0) { return @() }
    
    $wanted = switch ($Category) {
        'All' { @('Graphics','Wireless') }
        default { @($Category) }
    }
    
    $matches = @()
    foreach ($cfg in $configs) {
        if (-not $cfg.Components) { continue }
        
        $cfgComponents = @($cfg.Components | Where-Object { $_.Category -and ($wanted -contains $_.Category) })
        if ($cfgComponents.Count -eq 0) { continue }
        
        $isApplicable = $false
        foreach ($comp in $cfgComponents) {
            foreach ($dv in @($comp.DetectionValues)) {
                if (-not $dv) { continue }
                $dvNorm = ([string]$dv).ToUpperInvariant()
                if ($tokens | Where-Object { $_ -like "*$dvNorm*" } | Select-Object -First 1) {
                    $isApplicable = $true
                    break
                }
            }
            if ($isApplicable) { break }
        }
        
        if ($isApplicable) {
            $matches += $cfg
        }
    }
    
    return $matches
}

#endregion

#region Intel Driver Update Detection

function Get-IntelDriverUpdates {
    <#
    .SYNOPSIS
        Scans for available Intel driver updates
    .DESCRIPTION
        Uses the Intel DSA public data feed (dsadata.intel.com) to find driver
        packages applicable to detected hardware (Graphics/Wireless) and returns
        the latest available downloadmirror URLs.
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
    
    Write-DriverLog -Message "Scanning for Intel driver updates (DSA feed)" -Severity Info
    
    $wantedCategory = if ($DeviceClass -and $DeviceClass -match 'Display') { 'Graphics' }
                      elseif ($DeviceClass -and $DeviceClass -match 'Net|Wireless') { 'Wireless' }
                      else { 'All' }
    
    $configs = Find-IntelDsaApplicablePackages -Category $wantedCategory
    if ($configs.Count -eq 0) {
        Write-DriverLog -Message "No applicable Intel DSA packages found for this system" -Severity Info
        return @()
    }
    
    $devices = Get-IntelDevices -DeviceClass $DeviceClass
    $tokens = Get-IntelHardwareTokens
    
    $updates = @()
    foreach ($cfg in $configs) {
        # Choose the best matching component category
        $comp = $null
        if ($wantedCategory -ne 'All') {
            $comp = @($cfg.Components | Where-Object { $_.Category -eq $wantedCategory }) | Select-Object -First 1
        }
        if (-not $comp) {
            $comp = @($cfg.Components | Where-Object { $_.Category -in @('Graphics','Wireless') }) | Select-Object -First 1
        }
        if (-not $comp) { continue }
        
        # Find a matching token (VEN/DEV or VID/PID) from the component detection list
        $matchToken = $null
        foreach ($dv in @($comp.DetectionValues)) {
            if (-not $dv) { continue }
            $dvNorm = ([string]$dv).ToUpperInvariant()
            $hit = $tokens | Where-Object { $_ -like "*$dvNorm*" } | Select-Object -First 1
            if ($hit) { $matchToken = $hit; break }
        }
        
        $matchedDevice = $null
        if ($matchToken) {
            $matchedDevice = $devices | Where-Object {
                ($_.DeviceID -and ($_.DeviceID.ToUpperInvariant() -like "*$matchToken*")) -or
                ($_.HardwareID -and (@($_.HardwareID) | Where-Object { $_ -and ($_.ToString().ToUpperInvariant() -like "*$matchToken*") } | Select-Object -First 1))
            } | Select-Object -First 1
        }
        
        # Determine download URL from Files
        $file = @($cfg.Files | Where-Object { $_.Url -match 'downloadmirror\\.intel\\.com/.+\\.(exe|zip)$' }) | Select-Object -First 1
        if (-not $file -or -not $file.Url) { continue }
        
        $installedVersion = if ($matchedDevice) { $matchedDevice.DriverVersion } else { $null }
        $availableVersion = $comp.Version
        
        # Compare versions (best effort)
        $needsUpdate = $true
        if ($installedVersion) {
            try {
                $needsUpdate = (([Version]$availableVersion) -gt ([Version]$installedVersion))
            }
            catch {
                $needsUpdate = $availableVersion -ne $installedVersion
            }
        }
        
        if ($needsUpdate) {
            $updates += [PSCustomObject]@{
                PackageId        = $cfg.Id
                PackageName      = $cfg.Name
                PackageUrl       = $cfg.Url
                Category         = $comp.Category
                DeviceName       = if ($matchedDevice) { $matchedDevice.DeviceName } else { $cfg.Name }
                DeviceClass      = if ($matchedDevice) { $matchedDevice.DeviceClass } else { $DeviceClass }
                InstalledVersion = $installedVersion
                AvailableVersion = $availableVersion
                DownloadUrl      = $file.Url
                DownloadHashSha1 = $file.Hash
                ReleaseDate      = $cfg.DisplayReleaseDate
                InstallOptions   = $cfg.InstallOptions
                Details          = $cfg.Details
            }
        }
    }
    
    Write-DriverLog -Message "Found $($updates.Count) Intel driver updates (DSA feed)" -Severity Info -Context @{
        Count = $updates.Count
        Categories = ($updates.Category | Sort-Object -Unique)
    }
    
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
            Write-DriverLog -Message "Installing: $($update.PackageName) [$($update.Category)] ($($update.InstalledVersion) -> $($update.AvailableVersion))" -Severity Info
            
            try {
                # Download driver
                $tempPath = Join-Path $env:TEMP "IntelDriver_$(Get-Random)"
                New-Item -Path $tempPath -ItemType Directory -Force | Out-Null
                
                $fileName = Get-IntelDownloadFileName -Url $update.DownloadUrl -DefaultBaseName ($update.PackageName -replace '\s+', '_')
                $driverFile = Join-Path $tempPath $fileName
                
                Write-DriverLog -Message "Downloading from: $($update.DownloadUrl)" -Severity Info
                
                # Use the module's resilient downloader (BITS + retry + web fallback) and ensure TLS 1.2
                Invoke-WithRetry -ScriptBlock {
                    if ($update.DownloadHashSha1) {
                        Start-DownloadWithVerification -SourceUrl $update.DownloadUrl -DestinationPath $driverFile -ExpectedHash $update.DownloadHashSha1 -HashAlgorithm 'SHA1' | Out-Null
                    }
                    else {
                        Start-DownloadWithVerification -SourceUrl $update.DownloadUrl -DestinationPath $driverFile | Out-Null
                    }
                    if (-not (Test-Path $driverFile)) {
                        throw "Download failed - file not found after download"
                    }
                } -MaxAttempts 3 -ExponentialBackoff
                
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
                    if ($update.InstallOptions) {
                        $installArgs = @($installArgs + @([string]$update.InstallOptions))
                    }
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
                Write-DriverLog -Message "Failed to install $($update.PackageName): $($_.Exception.Message)" -Severity Error `
                    -Context @{ PackageName = $update.PackageName; Category = $update.Category; DownloadUrl = $update.DownloadUrl; InstalledVersion = $update.InstalledVersion; AvailableVersion = $update.AvailableVersion }
            }
        }
        
        $result.Success = ($failed -eq 0)
        $result.Message = "Intel driver installation: $installed installed, $failed failed"
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
        Checks for Intel devices and validates access to the Intel DSA data feed.
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
    
    # Load DSA feed (dynamic catalog)
    $meta = Get-IntelDsaFeedMetadata
    $status.CatalogPath = if ($meta) { $meta.Url } else { $null }
    
    $configs = Get-IntelDsaSoftwareConfigurations
    $status.CatalogLoaded = ($configs.Count -gt 0)
    
    if ($status.CatalogLoaded) {
        $status.Message = "Intel module initialized: $($status.DevicesDetected) devices, DSA feed version $($meta.Version), $($configs.Count) entries"
    }
    else {
        $status.Message = "Intel module initialized: $($status.DevicesDetected) devices, but failed to load DSA feed"
    }
    
    $status.Initialized = $true
    
    # Write-DriverLog requires a hashtable for -Context
    $logContext = @{
        Initialized     = $status.Initialized
        DevicesDetected = $status.DevicesDetected
        CatalogLoaded   = $status.CatalogLoaded
        CatalogPath     = $status.CatalogPath
    }
    Write-DriverLog -Message $status.Message -Severity Info -Context $logContext
    
    return $status
}

#endregion

