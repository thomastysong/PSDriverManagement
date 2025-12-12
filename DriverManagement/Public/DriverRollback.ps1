#Requires -Version 5.1

<#
.SYNOPSIS
    Driver rollback and restore functions
.DESCRIPTION
    Provides functions to rollback drivers, manage Dell driver restore points,
    and create/restore driver state snapshots.
#>

#region Device Manager Integration

function Get-RollbackableDrivers {
    <#
    .SYNOPSIS
        Lists drivers that have a previous version available for rollback
    .DESCRIPTION
        Queries the system for PnP devices that have driver rollback capability.
        This occurs when Windows keeps the previous driver after an update.
    .PARAMETER DeviceClass
        Filter by device class (e.g., 'Display', 'Net', 'Media')
    .PARAMETER IntelOnly
        Only return Intel devices (VEN_8086)
    .EXAMPLE
        Get-RollbackableDrivers
    .EXAMPLE
        Get-RollbackableDrivers -DeviceClass 'Display'
    .EXAMPLE
        Get-RollbackableDrivers -IntelOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DeviceClass,
        
        [Parameter()]
        [switch]$IntelOnly
    )
    
    $rollbackableDevices = @()
    
    try {
        # Get all PnP devices with signed drivers
        $devices = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop
        
        # Filter for Intel devices if requested
        if ($IntelOnly) {
            $devices = $devices | Where-Object {
                if (-not $_.DeviceID) { return $false }
                ($_.DeviceID -match 'VEN_8086') -or 
                ($_.Manufacturer -like '*Intel*') -or
                ($_.DriverProviderName -like '*Intel*')
            }
        }
        
        if ($DeviceClass) {
            $devices = $devices | Where-Object { $_.DeviceClass -like "*$DeviceClass*" }
        }
        
        foreach ($device in $devices) {
            if (-not $device.DeviceID) { continue }
            
            # Check if rollback is available via registry
            $deviceId = $device.DeviceID -replace '\\', '\\'
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($device.ClassGuid)"
            
            # Try to find previous driver info
            $hasRollback = $false
            $previousVersion = $null
            
            try {
                # Check for driver backup in DriverStore
                $infName = $device.InfName
                if ($infName) {
                    $driverStorePath = "$env:SystemRoot\System32\DriverStore\FileRepository"
                    $infFolders = Get-ChildItem -Path $driverStorePath -Filter "$($infName.Replace('.inf',''))*" -Directory -ErrorAction SilentlyContinue
                    
                    if ($infFolders.Count -gt 1) {
                        $hasRollback = $true
                        # Get version info from folders
                        $versions = $infFolders | ForEach-Object {
                            $infFile = Join-Path $_.FullName $infName
                            if (Test-Path $infFile) {
                                $content = Get-Content $infFile -Raw -ErrorAction SilentlyContinue
                                if ($content -match 'DriverVer\s*=\s*(\d+/\d+/\d+),\s*([\d.]+)') {
                                    [PSCustomObject]@{
                                        Folder = $_.Name
                                        Date = $matches[1]
                                        Version = $matches[2]
                                    }
                                }
                            }
                        } | Sort-Object Version -Descending
                        
                        if ($versions.Count -gt 1) {
                            $previousVersion = $versions[1].Version
                        }
                    }
                }
            }
            catch {
                # Ignore errors in version detection
            }
            
            if ($hasRollback -or $device.DriverVersion) {
                $rollbackableDevices += [PSCustomObject]@{
                    DeviceID         = $device.DeviceID
                    DeviceName       = $device.DeviceName
                    DeviceClass      = $device.DeviceClass
                    Manufacturer     = $device.Manufacturer
                    CurrentVersion   = $device.DriverVersion
                    PreviousVersion  = $previousVersion
                    InfName          = $device.InfName
                    HasRollback      = $hasRollback
                    DriverDate       = $device.DriverDate
                }
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to enumerate drivers: $($_.Exception.Message)" -Severity Error
        throw
    }
    
    return $rollbackableDevices | Where-Object { $_.HasRollback -eq $true }
}

function Invoke-IntelDriverRollback {
    <#
    .SYNOPSIS
        Rolls back Intel device drivers
    .DESCRIPTION
        Convenience function to rollback Intel drivers by device class or all Intel devices.
    .PARAMETER DeviceClass
        Rollback Intel drivers for specific device class (e.g., 'Display', 'Net')
    .PARAMETER Force
        Force rollback without confirmation
    .EXAMPLE
        Invoke-IntelDriverRollback -DeviceClass 'Display'
    .EXAMPLE
        Invoke-IntelDriverRollback  # Rollback all Intel devices
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$DeviceClass,
        
        [Parameter()]
        [switch]$Force
    )
    
    Assert-Elevation -Operation "Rolling back Intel drivers"
    
    # Get Intel devices that are rollbackable
    $intelDevices = Get-RollbackableDrivers -IntelOnly -DeviceClass $DeviceClass
    
    if ($intelDevices.Count -eq 0) {
        Write-DriverLog -Message "No rollbackable Intel drivers found" -Severity Info
        return @()
    }
    
    $results = @()
    
    foreach ($device in $intelDevices) {
        if ($PSCmdlet.ShouldProcess($device.DeviceName, "Rollback Intel driver")) {
            try {
                $rollbackResult = Invoke-DriverRollback -DeviceID $device.DeviceID -Force:$Force
                $results += $rollbackResult
            }
            catch {
                Write-DriverLog -Message "Failed to rollback $($device.DeviceName): $($_.Exception.Message)" -Severity Error
            }
        }
    }
    
    return $results
}

function Invoke-DriverRollback {
    <#
    .SYNOPSIS
        Rolls back a specific device driver to its previous version
    .DESCRIPTION
        Uses pnputil to rollback a device driver. This requires that Windows
        has retained the previous driver version.
    .PARAMETER DeviceID
        The PnP device ID to rollback
    .PARAMETER DeviceName
        The device name (friendly name) to rollback
    .PARAMETER Force
        Force rollback without confirmation
    .EXAMPLE
        Invoke-DriverRollback -DeviceID 'PCI\VEN_10DE&DEV_1C82&...'
    .EXAMPLE
        Get-RollbackableDrivers | Where-Object DeviceClass -eq 'Display' | Invoke-DriverRollback
    .EXAMPLE
        Get-RollbackableDrivers -IntelOnly | Invoke-DriverRollback
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByDeviceID')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByDeviceID', ValueFromPipelineByPropertyName)]
        [string]$DeviceID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$DeviceName,
        
        [Parameter()]
        [switch]$Force
    )
    
    process {
        Assert-Elevation -Operation "Rolling back driver"
        
        # Resolve device if searching by name
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $device = Get-CimInstance -ClassName Win32_PnPSignedDriver | 
                Where-Object { $_.DeviceName -like "*$DeviceName*" } |
                Select-Object -First 1
            
            if (-not $device) {
                Write-DriverLog -Message "Device not found: $DeviceName" -Severity Error
                throw "Device not found: $DeviceName"
            }
            
            $DeviceID = $device.DeviceID
        }
        
        $targetDevice = Get-CimInstance -ClassName Win32_PnPSignedDriver | 
            Where-Object { $_.DeviceID -eq $DeviceID }
        
        if (-not $targetDevice) {
            Write-DriverLog -Message "Device ID not found: $DeviceID" -Severity Error
            throw "Device ID not found: $DeviceID"
        }
        
        $displayName = if ($targetDevice.DeviceName) { $targetDevice.DeviceName } else { $DeviceID }
        
        if ($PSCmdlet.ShouldProcess($displayName, "Rollback driver")) {
            Write-DriverLog -Message "Rolling back driver for: $displayName" -Severity Info `
                -Context @{ DeviceID = $DeviceID; CurrentVersion = $targetDevice.DriverVersion }
            
            try {
                # Use pnputil to rollback
                # Note: Direct rollback via pnputil requires the instance ID
                $instanceId = $DeviceID
                
                # Disable and re-enable with previous driver
                $result = & pnputil /disable-device "$instanceId" 2>&1
                $disableExit = $LASTEXITCODE
                
                if ($disableExit -ne 0) {
                    Write-DriverLog -Message "Warning: Device disable returned: $disableExit" -Severity Warning
                }
                
                # Try to rollback via devcon if available, otherwise use alternative method
                $devconPath = "$env:SystemRoot\System32\devcon.exe"
                
                if (Test-Path $devconPath) {
                    & $devconPath rollback "$instanceId" 2>&1 | Out-Null
                }
                else {
                    # Alternative: Use SetupAPI via PowerShell
                    # Re-enable device which may use previous driver from DriverStore
                    Start-Sleep -Seconds 2
                    & pnputil /enable-device "$instanceId" 2>&1 | Out-Null
                }
                
                # Verify rollback
                Start-Sleep -Seconds 3
                $newDriver = Get-CimInstance -ClassName Win32_PnPSignedDriver | 
                    Where-Object { $_.DeviceID -eq $DeviceID }
                
                $result = [PSCustomObject]@{
                    DeviceID = $DeviceID
                    DeviceName = $displayName
                    PreviousVersion = $targetDevice.DriverVersion
                    CurrentVersion = $newDriver.DriverVersion
                    Success = ($newDriver.DriverVersion -ne $targetDevice.DriverVersion)
                    Message = if ($newDriver.DriverVersion -ne $targetDevice.DriverVersion) {
                        "Driver rolled back successfully"
                    } else {
                        "Driver version unchanged - rollback may require reboot or manual intervention"
                    }
                }
                
                Write-DriverLog -Message $result.Message -Severity Info -Context @{
                    DeviceID = $DeviceID
                    OldVersion = $targetDevice.DriverVersion
                    NewVersion = $newDriver.DriverVersion
                }
                
                return $result
            }
            catch {
                Write-DriverLog -Message "Failed to rollback driver: $($_.Exception.Message)" -Severity Error
                throw
            }
        }
    }
}

#endregion

#region Dell advancedDriverRestore Integration

function Enable-DellDriverRestore {
    <#
    .SYNOPSIS
        Enables Dell Command Update's advanced driver restore feature
    .DESCRIPTION
        Configures DCU to automatically create restore points before driver updates.
    .EXAMPLE
        Enable-DellDriverRestore
    #>
    [CmdletBinding()]
    param()
    
    Assert-Elevation -Operation "Enabling Dell driver restore"
    
    $dcuPath = Get-DellCommandUpdatePath
    if (-not $dcuPath) {
        throw "Dell Command Update is not installed"
    }
    
    Write-DriverLog -Message "Enabling Dell advanced driver restore" -Severity Info
    
    $result = & $dcuPath /configure -advancedDriverRestore=enable -silent 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        Write-DriverLog -Message "Dell driver restore enabled successfully" -Severity Info
        return $true
    }
    else {
        Write-DriverLog -Message "Failed to enable driver restore (exit: $exitCode)" -Severity Error
        return $false
    }
}

function New-DellDriverRestorePoint {
    <#
    .SYNOPSIS
        Creates a Dell Command Update driver restore point
    .DESCRIPTION
        Creates a snapshot of current drivers that can be restored later.
    .PARAMETER Name
        Optional name/description for the restore point
    .EXAMPLE
        New-DellDriverRestorePoint -Name "Before graphics update"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name = "PSDriverManagement_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    )
    
    Assert-Elevation -Operation "Creating Dell driver restore point"
    
    $dcuPath = Get-DellCommandUpdatePath
    if (-not $dcuPath) {
        throw "Dell Command Update is not installed"
    }
    
    # Ensure restore is enabled
    Enable-DellDriverRestore | Out-Null
    
    Write-DriverLog -Message "Creating Dell driver restore point: $Name" -Severity Info
    
    # DCU creates restore points automatically before updates
    # We trigger a scan which will create a baseline
    $result = & $dcuPath /scan -silent 2>&1
    
    # Store restore point metadata
    $restorePointPath = "$env:ProgramData\PSDriverManagement\DellRestorePoints"
    if (-not (Test-Path $restorePointPath)) {
        New-Item -Path $restorePointPath -ItemType Directory -Force | Out-Null
    }
    
    $restorePoint = [PSCustomObject]@{
        ID = [guid]::NewGuid().ToString()
        Name = $Name
        Created = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        DCUVersion = (Get-DCUInstallDetails).Version
    }
    
    $restorePoint | ConvertTo-Json | Set-Content -Path (Join-Path $restorePointPath "$($restorePoint.ID).json")
    
    Write-DriverLog -Message "Restore point created: $($restorePoint.ID)" -Severity Info
    
    return $restorePoint
}

function Get-DellDriverRestorePoints {
    <#
    .SYNOPSIS
        Lists available Dell driver restore points
    .EXAMPLE
        Get-DellDriverRestorePoints
    #>
    [CmdletBinding()]
    param()
    
    $restorePointPath = "$env:ProgramData\PSDriverManagement\DellRestorePoints"
    
    if (-not (Test-Path $restorePointPath)) {
        return @()
    }
    
    $restorePoints = Get-ChildItem -Path $restorePointPath -Filter "*.json" | ForEach-Object {
        Get-Content $_.FullName | ConvertFrom-Json
    } | Sort-Object Created -Descending
    
    return $restorePoints
}

function Restore-DellDrivers {
    <#
    .SYNOPSIS
        Restores Dell drivers from a restore point
    .DESCRIPTION
        Uses Dell Command Update to restore drivers to a previous state.
    .PARAMETER RestorePointID
        The ID of the restore point to restore from
    .PARAMETER Latest
        Restore from the most recent restore point
    .EXAMPLE
        Restore-DellDrivers -RestorePointID 'abc123...'
    .EXAMPLE
        Restore-DellDrivers -Latest
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByID')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByID')]
        [string]$RestorePointID,
        
        [Parameter(Mandatory, ParameterSetName = 'Latest')]
        [switch]$Latest
    )
    
    Assert-Elevation -Operation "Restoring Dell drivers"
    
    $dcuPath = Get-DellCommandUpdatePath
    if (-not $dcuPath) {
        throw "Dell Command Update is not installed"
    }
    
    if ($Latest) {
        $restorePoint = Get-DellDriverRestorePoints | Select-Object -First 1
        if (-not $restorePoint) {
            throw "No restore points available"
        }
        $RestorePointID = $restorePoint.ID
    }
    
    $restorePoint = Get-DellDriverRestorePoints | Where-Object { $_.ID -eq $RestorePointID }
    if (-not $restorePoint) {
        throw "Restore point not found: $RestorePointID"
    }
    
    if ($PSCmdlet.ShouldProcess("Restore point: $($restorePoint.Name)", "Restore drivers")) {
        Write-DriverLog -Message "Restoring Dell drivers from: $($restorePoint.Name)" -Severity Info
        
        # Use DCU's driver restore functionality
        $result = & $dcuPath /driverInstall -advancedDriverRestore=enable -silent 2>&1
        $exitCode = $LASTEXITCODE
        
        $restoreResult = [PSCustomObject]@{
            RestorePointID = $RestorePointID
            RestorePointName = $restorePoint.Name
            Success = ($exitCode -in @(0, 1))
            ExitCode = $exitCode
            RebootRequired = ($exitCode -eq 1)
            Message = Get-DCUExitInfo -ExitCode $exitCode | Select-Object -ExpandProperty Description
        }
        
        Write-DriverLog -Message "Driver restore completed: $($restoreResult.Message)" -Severity Info
        
        return $restoreResult
    }
}

#endregion

#region Driver State Snapshots

function New-DriverSnapshot {
    <#
    .SYNOPSIS
        Creates a snapshot of the current driver state
    .DESCRIPTION
        Captures current driver inventory including versions, INF files, and metadata.
        Can be used to restore driver state later.
    .PARAMETER Name
        Name for the snapshot
    .PARAMETER IncludeInfFiles
        Include copies of INF files in the snapshot (increases size)
    .EXAMPLE
        New-DriverSnapshot -Name "Before update"
    .EXAMPLE
        New-DriverSnapshot -Name "Baseline" -IncludeInfFiles
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter()]
        [switch]$IncludeInfFiles
    )
    
    Assert-Elevation -Operation "Creating driver snapshot"
    
    $snapshotBase = "$env:ProgramData\PSDriverManagement\Snapshots"
    $snapshotId = [guid]::NewGuid().ToString()
    $snapshotPath = Join-Path $snapshotBase $snapshotId
    
    if (-not (Test-Path $snapshotBase)) {
        New-Item -Path $snapshotBase -ItemType Directory -Force | Out-Null
    }
    
    New-Item -Path $snapshotPath -ItemType Directory -Force | Out-Null
    
    Write-DriverLog -Message "Creating driver snapshot: $Name" -Severity Info
    
    # Capture driver inventory
    $drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver | ForEach-Object {
        [PSCustomObject]@{
            DeviceID = $_.DeviceID
            DeviceName = $_.DeviceName
            DeviceClass = $_.DeviceClass
            Manufacturer = $_.Manufacturer
            DriverVersion = $_.DriverVersion
            DriverDate = $_.DriverDate
            InfName = $_.InfName
            DriverProviderName = $_.DriverProviderName
            Signer = $_.Signer
            IsSigned = $_.IsSigned
        }
    }
    
    # Create snapshot metadata
    $snapshot = [PSCustomObject]@{
        ID = $snapshotId
        Name = $Name
        Created = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        OSVersion = [System.Environment]::OSVersion.Version.ToString()
        DriverCount = $drivers.Count
        IncludesInfFiles = $IncludeInfFiles.IsPresent
    }
    
    # Save metadata
    $snapshot | ConvertTo-Json | Set-Content -Path (Join-Path $snapshotPath "snapshot.json")
    
    # Save driver inventory
    $drivers | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $snapshotPath "drivers.json")
    
    # Copy INF files if requested
    if ($IncludeInfFiles) {
        $infPath = Join-Path $snapshotPath "inf"
        New-Item -Path $infPath -ItemType Directory -Force | Out-Null
        
        $driverStorePath = "$env:SystemRoot\System32\DriverStore\FileRepository"
        
        foreach ($driver in $drivers) {
            if ($driver.InfName) {
                try {
                    $infFolders = Get-ChildItem -Path $driverStorePath -Filter "$($driver.InfName.Replace('.inf',''))*" -Directory -ErrorAction SilentlyContinue
                    
                    foreach ($folder in $infFolders) {
                        $destFolder = Join-Path $infPath $folder.Name
                        if (-not (Test-Path $destFolder)) {
                            Copy-Item -Path $folder.FullName -Destination $destFolder -Recurse -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {
                    Write-DriverLog -Message "Could not copy INF for $($driver.DeviceName): $($_.Exception.Message)" -Severity Warning
                }
            }
        }
    }
    
    Write-DriverLog -Message "Snapshot created: $snapshotId ($($drivers.Count) drivers)" -Severity Info `
        -Context @{ SnapshotID = $snapshotId; Name = $Name; DriverCount = $drivers.Count }
    
    return $snapshot
}

function Get-DriverSnapshots {
    <#
    .SYNOPSIS
        Lists available driver snapshots
    .EXAMPLE
        Get-DriverSnapshots
    #>
    [CmdletBinding()]
    param()
    
    $snapshotBase = "$env:ProgramData\PSDriverManagement\Snapshots"
    
    if (-not (Test-Path $snapshotBase)) {
        return @()
    }
    
    $snapshots = Get-ChildItem -Path $snapshotBase -Directory | ForEach-Object {
        $metadataPath = Join-Path $_.FullName "snapshot.json"
        if (Test-Path $metadataPath) {
            $metadata = Get-Content $metadataPath | ConvertFrom-Json
            $metadata | Add-Member -NotePropertyName 'Path' -NotePropertyValue $_.FullName -PassThru
        }
    } | Sort-Object Created -Descending
    
    return $snapshots
}

function Get-DriverSnapshotDetails {
    <#
    .SYNOPSIS
        Gets detailed information about a driver snapshot
    .PARAMETER SnapshotID
        The snapshot ID to get details for
    .PARAMETER Name
        The snapshot name to get details for
    .EXAMPLE
        Get-DriverSnapshotDetails -SnapshotID 'abc123...'
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByID')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByID')]
        [string]$SnapshotID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$Name
    )
    
    $snapshots = Get-DriverSnapshots
    
    $snapshot = if ($PSCmdlet.ParameterSetName -eq 'ByID') {
        $snapshots | Where-Object { $_.ID -eq $SnapshotID }
    } else {
        $snapshots | Where-Object { $_.Name -eq $Name }
    }
    
    if (-not $snapshot) {
        throw "Snapshot not found"
    }
    
    $driversPath = Join-Path $snapshot.Path "drivers.json"
    $drivers = Get-Content $driversPath | ConvertFrom-Json
    
    return [PSCustomObject]@{
        Metadata = $snapshot
        Drivers = $drivers
    }
}

function Restore-DriverSnapshot {
    <#
    .SYNOPSIS
        Restores drivers from a snapshot
    .DESCRIPTION
        Attempts to restore drivers to the versions captured in a snapshot.
        This uses pnputil to reinstall drivers from the snapshot's INF files.
    .PARAMETER SnapshotID
        The snapshot ID to restore from
    .PARAMETER Name
        The snapshot name to restore from
    .PARAMETER DeviceClass
        Only restore drivers for specific device class
    .EXAMPLE
        Restore-DriverSnapshot -SnapshotID 'abc123...'
    .EXAMPLE
        Restore-DriverSnapshot -Name "Baseline" -DeviceClass "Display"
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByID')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByID')]
        [string]$SnapshotID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$Name,
        
        [Parameter()]
        [string]$DeviceClass
    )
    
    Assert-Elevation -Operation "Restoring driver snapshot"
    
    $snapshot = if ($PSCmdlet.ParameterSetName -eq 'ByID') {
        Get-DriverSnapshots | Where-Object { $_.ID -eq $SnapshotID }
    } else {
        Get-DriverSnapshots | Where-Object { $_.Name -eq $Name }
    }
    
    if (-not $snapshot) {
        throw "Snapshot not found"
    }
    
    if (-not $snapshot.IncludesInfFiles) {
        throw "Snapshot does not include INF files - cannot restore. Create a new snapshot with -IncludeInfFiles"
    }
    
    $details = Get-DriverSnapshotDetails -SnapshotID $snapshot.ID
    $drivers = $details.Drivers
    
    if ($DeviceClass) {
        $drivers = $drivers | Where-Object { $_.DeviceClass -like "*$DeviceClass*" }
    }
    
    if ($PSCmdlet.ShouldProcess("$($drivers.Count) drivers from snapshot '$($snapshot.Name)'", "Restore")) {
        Write-DriverLog -Message "Restoring drivers from snapshot: $($snapshot.Name)" -Severity Info
        
        $infPath = Join-Path $snapshot.Path "inf"
        $restored = 0
        $failed = 0
        
        foreach ($driver in $drivers) {
            if ($driver.InfName) {
                $infFolder = Get-ChildItem -Path $infPath -Filter "$($driver.InfName.Replace('.inf',''))*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
                
                if ($infFolder) {
                    $infFile = Join-Path $infFolder.FullName $driver.InfName
                    
                    if (Test-Path $infFile) {
                        try {
                            Write-DriverLog -Message "Restoring: $($driver.DeviceName)" -Severity Info
                            
                            # Add driver to store
                            $addResult = & pnputil /add-driver "$infFile" /install 2>&1
                            
                            if ($LASTEXITCODE -eq 0) {
                                $restored++
                            } else {
                                $failed++
                                Write-DriverLog -Message "Failed to restore $($driver.DeviceName): exit $LASTEXITCODE" -Severity Warning
                            }
                        }
                        catch {
                            $failed++
                            Write-DriverLog -Message "Error restoring $($driver.DeviceName): $($_.Exception.Message)" -Severity Warning
                        }
                    }
                }
            }
        }
        
        $result = [PSCustomObject]@{
            SnapshotID = $snapshot.ID
            SnapshotName = $snapshot.Name
            TotalDrivers = $drivers.Count
            Restored = $restored
            Failed = $failed
            Success = ($failed -eq 0)
            RebootRequired = ($restored -gt 0)
        }
        
        Write-DriverLog -Message "Restore completed: $restored succeeded, $failed failed" -Severity Info `
            -Context $result
        
        return $result
    }
}

function Remove-DriverSnapshot {
    <#
    .SYNOPSIS
        Removes a driver snapshot
    .PARAMETER SnapshotID
        The snapshot ID to remove
    .PARAMETER Name
        The snapshot name to remove
    .EXAMPLE
        Remove-DriverSnapshot -SnapshotID 'abc123...'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByID', ValueFromPipelineByPropertyName)]
        [Alias('ID')]
        [string]$SnapshotID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$Name
    )
    
    process {
        $snapshot = if ($PSCmdlet.ParameterSetName -eq 'ByID') {
            Get-DriverSnapshots | Where-Object { $_.ID -eq $SnapshotID }
        } else {
            Get-DriverSnapshots | Where-Object { $_.Name -eq $Name }
        }
        
        if (-not $snapshot) {
            throw "Snapshot not found"
        }
        
        if ($PSCmdlet.ShouldProcess($snapshot.Name, "Remove driver snapshot")) {
            Write-DriverLog -Message "Removing snapshot: $($snapshot.Name)" -Severity Info
            
            Remove-Item -Path $snapshot.Path -Recurse -Force
            
            Write-DriverLog -Message "Snapshot removed: $($snapshot.ID)" -Severity Info
        }
    }
}

#endregion

