#Requires -Version 5.1

<#
.SYNOPSIS
    Windows Update functions for DriverManagement module
#>

function Install-WindowsUpdates {
    <#
    .SYNOPSIS
        Installs Windows cumulative updates
    .DESCRIPTION
        Uses PSWindowsUpdate to install Windows updates, excluding drivers by default
    .PARAMETER IncludeDrivers
        Include drivers from Windows Update (not recommended with OEM drivers)
    .PARAMETER Categories
        Update categories to include
    .PARAMETER NoReboot
        Suppress automatic reboot
    .EXAMPLE
        Install-WindowsUpdates -NoReboot
    .OUTPUTS
        DriverUpdateResult object
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DriverUpdateResult')]
    param(
        [Parameter()]
        [switch]$IncludeDrivers,
        
        [Parameter()]
        [string[]]$Categories = @('Security Updates', 'Critical Updates', 'Updates'),
        
        [Parameter()]
        [switch]$NoReboot
    )
    
    Assert-Elevation -Operation "Installing Windows Updates"
    
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    # Ensure PSWindowsUpdate is available
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        try {
            Write-DriverLog -Message "Installing PSWindowsUpdate module" -Severity Info
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
        }
        catch {
            $result.Success = $false
            $result.Message = "Failed to install PSWindowsUpdate: $($_.Exception.Message)"
            $result.ExitCode = 1
            return $result
        }
    }
    
    # Remove module if already loaded to avoid alias conflicts
    if (Get-Module -Name PSWindowsUpdate) {
        Remove-Module -Name PSWindowsUpdate -Force -ErrorAction SilentlyContinue
    }
    
    # Import module, suppressing alias warnings (they're harmless if module was already loaded)
    # Redirect error output to suppress alias creation warnings
    $ErrorActionPreference = 'SilentlyContinue'
    $null = Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue 2>&1 | Where-Object {
        # Filter out alias errors, but keep other errors
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            if ($_.Exception.Message -match 'alias.*already exists') {
                return $false  # Suppress alias errors
            }
        }
        return $true  # Keep other errors
    }
    $ErrorActionPreference = 'Continue'
    
    # Verify module loaded successfully
    if (-not (Get-Module -Name PSWindowsUpdate)) {
        $result.Success = $false
        $result.Message = "Failed to import PSWindowsUpdate module"
        $result.ExitCode = 1
        return $result
    }
    
    Write-DriverLog -Message "Scanning for Windows Updates" -Severity Info
    
    $getParams = @{
        MicrosoftUpdate = $true
        Category = $Categories
        Verbose = $true
    }
    
    if (-not $IncludeDrivers) {
        $getParams.NotCategory = 'Drivers'
    }
    
    $updates = Get-WindowsUpdate @getParams
    
    if (-not $updates) {
        $result.Success = $true
        $result.Message = "No Windows Updates available"
        $result.ExitCode = 0
        Write-DriverLog -Message $result.Message -Severity Info
        return $result
    }
    
    Write-DriverLog -Message "Found $($updates.Count) Windows Updates" -Severity Info `
        -Context @{ Updates = ($updates | Select-Object KB, Title) }
    
    if ($PSCmdlet.ShouldProcess("$($updates.Count) Windows Updates", "Install")) {
        $installParams = @{
            MicrosoftUpdate = $true
            AcceptAll = $true
            IgnoreReboot = $true
            Verbose = $true
        }
        
        if (-not $IncludeDrivers) {
            $installParams.NotCategory = 'Drivers'
        }
        
        $installResults = Install-WindowsUpdate @installParams
        
        $rebootStatus = Get-WURebootStatus
        
        $result.Success = $true
        $result.Message = "Installed $($installResults.Count) Windows Updates"
        $result.UpdatesApplied = $installResults.Count
        $result.RebootRequired = $rebootStatus.RebootRequired
        $result.ExitCode = if ($result.RebootRequired) { 3010 } else { 0 }
        $result.Details = @{ Updates = ($installResults | Select-Object KB, Title, Result) }
    }
    
    Write-DriverLog -Message $result.Message -Severity Info -Context $result.ToHashtable()
    
    return $result
}

function Get-DriverComplianceStatus {
    <#
    .SYNOPSIS
        Gets the current driver compliance status
    .DESCRIPTION
        Reads the compliance status file
    .EXAMPLE
        Get-DriverComplianceStatus
    .OUTPUTS
        DriverComplianceStatus object
    #>
    [CmdletBinding()]
    [OutputType('DriverComplianceStatus')]
    param()
    
    $config = $script:ModuleConfig
    $compliancePath = $config.CompliancePath
    
    if (-not (Test-Path $compliancePath)) {
        $status = [DriverComplianceStatus]::new()
        $status.Status = [ComplianceStatus]::Unknown
        $status.Message = "No compliance check performed yet"
        return $status
    }
    
    try {
        $json = Get-Content $compliancePath -Raw
        return [DriverComplianceStatus]::FromJson($json)
    }
    catch {
        Write-DriverLog -Message "Failed to read compliance status: $($_.Exception.Message)" -Severity Warning
        $status = [DriverComplianceStatus]::new()
        $status.Status = [ComplianceStatus]::Error
        $status.Message = $_.Exception.Message
        return $status
    }
}

function Update-DriverComplianceStatus {
    <#
    .SYNOPSIS
        Updates the driver compliance status file
    .DESCRIPTION
        Writes current compliance state for detection scripts
    .PARAMETER Status
        Compliance status
    .PARAMETER UpdatesApplied
        Number of updates applied
    .PARAMETER UpdatesPending
        Number of updates pending
    .PARAMETER Message
        Status message
    .EXAMPLE
        Update-DriverComplianceStatus -Status Compliant -UpdatesApplied 5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ComplianceStatus]$Status,
        
        [Parameter()]
        [int]$UpdatesApplied = 0,
        
        [Parameter()]
        [int]$UpdatesPending = 0,
        
        [Parameter()]
        [string]$Message = ''
    )
    
    $config = $script:ModuleConfig
    
    # Ensure directory exists
    $complianceDir = Split-Path $config.CompliancePath -Parent
    if (-not (Test-Path $complianceDir)) {
        New-Item -Path $complianceDir -ItemType Directory -Force | Out-Null
    }
    
    $oemInfo = Get-OEMInfo
    
    $compliance = [DriverComplianceStatus]::new()
    $compliance.Version = $config.ModuleVersion
    $compliance.Status = $Status
    $compliance.OEM = $oemInfo.OEM
    $compliance.Model = $oemInfo.Model
    $compliance.UpdatesApplied = $UpdatesApplied
    $compliance.UpdatesPending = $UpdatesPending
    $compliance.Message = $Message
    $compliance.CorrelationId = $script:CorrelationId
    
    $compliance.ToHashtable() | ConvertTo-Json -Depth 3 | Set-Content -Path $config.CompliancePath -Encoding UTF8
    
    Write-DriverLog -Message "Updated compliance status: $Status" -Severity Info -Context $compliance.ToHashtable()
}
