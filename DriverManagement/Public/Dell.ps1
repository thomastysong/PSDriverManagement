#Requires -Version 5.1

<#
.SYNOPSIS
    Dell driver management functions
#>

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
    
    $dcuCli = Get-DellCommandUpdatePath
    if (-not $dcuCli) {
        Write-DriverLog -Message "Dell Command Update not installed" -Severity Warning
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
    
    $dcuCli = Get-DellCommandUpdatePath
    if (-not $dcuCli) {
        $result.Success = $false
        $result.Message = "Dell Command Update not installed"
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
            500 {
                $result.Success = $true
                $result.Message = "No applicable updates"
                $result.RebootRequired = $false
            }
            default {
                $result.Success = $false
                $result.Message = "DCU error code: $exitCode"
                $result.RebootRequired = $false
            }
        }
        
        $result.ExitCode = if ($result.RebootRequired) { 3010 } elseif ($result.Success) { 0 } else { 1 }
        
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
    
    $dcuCli = Get-DellCommandUpdatePath
    if (-not $dcuCli) {
        $result.Success = $false
        $result.Message = "Dell Command Update not installed"
        $result.ExitCode = 1
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
        
        $result.Success = $exitCode -in @(0, 1, 500)
        $result.Message = "Full pack install completed with exit code: $exitCode"
        $result.RebootRequired = $exitCode -eq 1
        $result.ExitCode = if ($exitCode -eq 1) { 3010 } elseif ($exitCode -in @(0, 500)) { 0 } else { 1 }
        
        Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    }
    
    return $result
}
