#Requires -Version 5.1

<#
.SYNOPSIS
    Lenovo driver management functions
#>

function Initialize-LenovoModule {
    <#
    .SYNOPSIS
        Ensures LSUClient module is available
    #>
    [CmdletBinding()]
    param()
    
    if (-not (Get-Module -ListAvailable -Name LSUClient)) {
        Write-DriverLog -Message "Installing LSUClient module" -Severity Info
        
        # Try to install from PSGallery
        try {
            Install-Module -Name LSUClient -Force -Scope AllUsers -ErrorAction Stop
        }
        catch {
            Write-DriverLog -Message "Failed to install LSUClient: $($_.Exception.Message)" -Severity Warning
            throw
        }
    }
    
    Import-Module LSUClient -Force -ErrorAction Stop
}

function Get-LenovoDriverUpdates {
    <#
    .SYNOPSIS
        Scans for available Lenovo driver updates
    .DESCRIPTION
        Uses LSUClient module to scan for applicable updates
    .PARAMETER UpdateTypes
        Types of updates to scan for
    .PARAMETER UnattendedOnly
        Only return updates that support unattended installation
    .EXAMPLE
        Get-LenovoDriverUpdates -UpdateTypes Driver
    .OUTPUTS
        Array of available update objects
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'All')]
        [string[]]$UpdateTypes = @('Driver'),
        
        [Parameter()]
        [switch]$UnattendedOnly = $true
    )
    
    try {
        Initialize-LenovoModule
    }
    catch {
        Write-DriverLog -Message "LSUClient not available" -Severity Warning
        return @()
    }
    
    $oemInfo = Get-OEMInfo
    Write-DriverLog -Message "Scanning for Lenovo updates - MTM: $($oemInfo.MTM)" -Severity Info
    
    # Get all updates
    $allUpdates = Get-LSUpdate
    
    # Filter for unattended
    if ($UnattendedOnly) {
        $allUpdates = $allUpdates | Where-Object { $_.Installer.Unattended }
    }
    
    # Filter by type
    $typeMap = @{
        'Driver' = 'Driver'
        'BIOS' = 'BIOS'
        'Firmware' = 'Firmware'
    }
    
    $filteredUpdates = $allUpdates | Where-Object {
        if ('All' -in $UpdateTypes) { return $true }
        $_.Type -in ($UpdateTypes | ForEach-Object { $typeMap[$_] })
    }
    
    $updates = $filteredUpdates | ForEach-Object {
        [PSCustomObject]@{
            ID = $_.ID
            Title = $_.Title
            Version = $_.Version
            Type = $_.Type
            Severity = $_.Severity
            RebootType = $_.Reboot.Type
            Size = $_.Size
            Unattended = $_.Installer.Unattended
        }
    }
    
    Write-DriverLog -Message "Found $($updates.Count) Lenovo updates" -Severity Info `
        -Context @{ Updates = ($updates | Select-Object Title, Version, Type) }
    
    return $updates
}

function Install-LenovoDriverUpdates {
    <#
    .SYNOPSIS
        Installs Lenovo driver updates
    .DESCRIPTION
        Uses LSUClient to install applicable updates
    .PARAMETER UpdateTypes
        Types of updates to install
    .PARAMETER Severity
        Severity levels to include
    .PARAMETER NoReboot
        Suppress automatic reboot
    .EXAMPLE
        Install-LenovoDriverUpdates -UpdateTypes Driver -NoReboot
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
    
    Assert-Elevation -Operation "Installing Lenovo drivers"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    try {
        Initialize-LenovoModule
    }
    catch {
        # Fallback to Thin Installer
        Write-DriverLog -Message "LSUClient unavailable, using Thin Installer fallback" -Severity Warning
        return Install-LenovoThinInstallerFallback -UpdateTypes $UpdateTypes -NoReboot:$NoReboot
    }
    
    # Get applicable updates
    $updates = Get-LSUpdate | Where-Object { 
        $_.Installer.Unattended -and
        (('All' -in $UpdateTypes) -or ($_.Type -in $UpdateTypes)) -and
        ($_.Severity -in $Severity)
    }
    
    if (-not $updates) {
        $result.Success = $true
        $result.Message = "No applicable updates"
        $result.ExitCode = 0
        Write-DriverLog -Message $result.Message -Severity Info
        return $result
    }
    
    Write-DriverLog -Message "Installing $($updates.Count) Lenovo updates" -Severity Info
    
    $rebootRequired = $false
    $successCount = 0
    $failCount = 0
    $details = @()
    
    if ($PSCmdlet.ShouldProcess("$($updates.Count) Lenovo updates", "Install")) {
        foreach ($update in $updates) {
            Write-DriverLog -Message "Installing: $($update.Title) v$($update.Version)" -Severity Info
            
            try {
                $installResult = Invoke-WithRetry -ScriptBlock {
                    Install-LSUpdate -Package $update -Verbose
                } -MaxAttempts 3 -ExponentialBackoff
                
                $successCount++
                $details += @{
                    Title = $update.Title
                    Version = $update.Version
                    Success = $true
                }
                
                if ($update.Reboot.Required -or $installResult.ExitCode -in @(1, 3, 3010)) {
                    $rebootRequired = $true
                }
            }
            catch {
                $failCount++
                $details += @{
                    Title = $update.Title
                    Version = $update.Version
                    Success = $false
                    Error = $_.Exception.Message
                }
                Write-DriverLog -Message "Failed to install $($update.Title): $($_.Exception.Message)" -Severity Warning
            }
        }
    }
    
    $result.Success = $successCount -gt 0
    $result.Message = "Installed $successCount of $($updates.Count) updates"
    $result.UpdatesApplied = $successCount
    $result.UpdatesFailed = $failCount
    $result.RebootRequired = $rebootRequired
    $result.ExitCode = if ($rebootRequired) { 3010 } elseif ($result.Success) { 0 } else { 1 }
    $result.Details = @{ Updates = $details }
    
    Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    
    return $result
}

function Install-LenovoThinInstallerFallback {
    <#
    .SYNOPSIS
        Fallback to Thin Installer when LSUClient unavailable
    #>
    [CmdletBinding()]
    param(
        [string[]]$UpdateTypes,
        [switch]$NoReboot
    )
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    $thinInstaller = "${env:ProgramFiles(x86)}\Lenovo\ThinInstaller\ThinInstaller.exe"
    if (-not (Test-Path $thinInstaller)) {
        $result.Success = $false
        $result.Message = "No Lenovo tools available"
        $result.ExitCode = 1
        return $result
    }
    
    # Map update types (1=App, 2=Driver, 3=BIOS, 4=Firmware)
    $packageTypes = @()
    if ('Driver' -in $UpdateTypes -or 'All' -in $UpdateTypes) { $packageTypes += '2' }
    if ('BIOS' -in $UpdateTypes -or 'All' -in $UpdateTypes) { $packageTypes += '3' }
    if ('Firmware' -in $UpdateTypes -or 'All' -in $UpdateTypes) { $packageTypes += '4' }
    
    $args = @(
        '/CM'
        '-search', 'R'
        '-action', 'INSTALL'
        '-packagetypes', ($packageTypes -join ',')
        '-includerebootpackages', '0,3'
        '-noicon'
        '-nolicense'
        '-exporttowmi'
    )
    
    if ($NoReboot) {
        $args += '-noreboot'
    }
    
    Write-DriverLog -Message "Running Thin Installer fallback" -Severity Info
    
    $process = Start-Process -FilePath $thinInstaller -ArgumentList $args -Wait -PassThru -NoNewWindow
    
    $result.Success = $process.ExitCode -in @(0, 1, 3)
    $result.Message = "Thin Installer exit code: $($process.ExitCode)"
    $result.RebootRequired = $process.ExitCode -in @(1, 3)
    $result.ExitCode = if ($process.ExitCode -in @(1, 3)) { 3010 } elseif ($process.ExitCode -eq 0) { 0 } else { 1 }
    
    Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    
    return $result
}

function Install-LenovoFullDriverPack {
    <#
    .SYNOPSIS
        Installs the complete Lenovo driver pack
    .DESCRIPTION
        Downloads and installs all applicable drivers
    .PARAMETER NoReboot
        Suppress automatic reboot
    .EXAMPLE
        Install-LenovoFullDriverPack -NoReboot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [switch]$NoReboot
    )
    
    Assert-Elevation -Operation "Installing Lenovo full driver pack"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    try {
        Initialize-LenovoModule
        
        $oemInfo = Get-OEMInfo
        Write-DriverLog -Message "Installing Lenovo full driver pack - MTM: $($oemInfo.MTM)" -Severity Info
        
        # Get ALL updates
        $allUpdates = Get-LSUpdate -All | Where-Object { $_.Installer.Unattended }
        
        if ($PSCmdlet.ShouldProcess("$($allUpdates.Count) Lenovo packages", "Install full driver pack")) {
            Write-DriverLog -Message "Installing $($allUpdates.Count) packages" -Severity Info
            
            # Download all
            $downloadPath = "$env:TEMP\LenovoDriverPack"
            $allUpdates | Save-LSUpdate -Path $downloadPath -ShowProgress
            
            # Install all
            $installResults = $allUpdates | Install-LSUpdate -Verbose
            
            $result.Success = $true
            $result.Message = "Full pack install complete"
            $result.UpdatesApplied = $allUpdates.Count
            $result.RebootRequired = $true  # Always recommend reboot for full pack
            $result.ExitCode = 3010
        }
    }
    catch {
        Write-DriverLog -Message "Full pack install failed: $($_.Exception.Message)" -Severity Error
        return Install-LenovoThinInstallerFallback -UpdateTypes @('All') -NoReboot:$NoReboot
    }
    
    Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    
    return $result
}
