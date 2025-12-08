#Requires -Version 5.1

<#
.SYNOPSIS
    PSDriverManagement PowerShell Module
    
.DESCRIPTION
    Enterprise driver and Windows update management for Dell and Lenovo endpoints.
    Designed for deployment via Intune, FleetDM, Chef, Ansible, SCCM, or any orchestration platform.
    
.NOTES
    Module: DriverManagement
    Author: Thomas Tyson
    Version: 1.0.0
#>

#region Module Variables

# Module-scoped configuration object
$script:ModuleConfig = $null

# Module root path
$script:ModuleRoot = $PSScriptRoot

# Correlation ID for current session
$script:CorrelationId = $null

# Logging initialized flag
$script:LoggingInitialized = $false

#endregion

#region Module Initialization

function Initialize-ModuleConfiguration {
    <#
    .SYNOPSIS
        Initializes module configuration from manifest and environment
    #>
    [CmdletBinding()]
    param()
    
    # Load defaults from manifest PrivateData
    $manifestPath = Join-Path $script:ModuleRoot 'DriverManagement.psd1'
    $manifest = Import-PowerShellDataFile -Path $manifestPath
    
    $defaults = $manifest.PrivateData.ModuleConfig
    
    # Expand environment variables in paths
    $script:ModuleConfig = @{
        LogPath              = $ExecutionContext.InvokeCommand.ExpandString($defaults.LogPath)
        CompliancePath       = $ExecutionContext.InvokeCommand.ExpandString($defaults.CompliancePath)
        EventLogName         = $defaults.EventLogName
        EventLogSource       = $defaults.EventLogSource
        MaxLogAgeDays        = $defaults.MaxLogAgeDays
        MaxLogSizeMB         = $defaults.MaxLogSizeMB
        DefaultMode          = $defaults.DefaultMode
        DefaultUpdateTypes   = $defaults.DefaultUpdateTypes
        DefaultSeverity      = $defaults.DefaultSeverity
        SupportedDellModels  = $defaults.SupportedDellModels
        SupportedLenovoMTMs  = $defaults.SupportedLenovoMTMs
        ModuleVersion        = $manifest.ModuleVersion
    }
    
    # Generate correlation ID for this session
    $script:CorrelationId = [guid]::NewGuid().ToString()
    
    # Override with environment variables if present
    if ($env:PSDM_LOG_PATH) {
        $script:ModuleConfig.LogPath = $env:PSDM_LOG_PATH
    }
    if ($env:PSDM_EVENT_LOG) {
        $script:ModuleConfig.EventLogName = $env:PSDM_EVENT_LOG
    }
}

#endregion

#region Dot-Source Module Components

# Import order matters - Classes first, then Private, then Public

# Classes (type definitions)
$classFiles = @(
    'Classes\DriverManagementConfig.ps1'
)

# Private functions (internal use only)
$privateFiles = @(
    'Private\Logging.ps1'
    'Private\Utilities.ps1'
    'Private\VersionComparison.ps1'
)

# Public functions (exported)
$publicFiles = @(
    'Public\Get-OEMInfo.ps1'
    'Public\Get-DriverComplianceStatus.ps1'
    'Public\Update-DriverComplianceStatus.ps1'
    'Public\Dell.ps1'
    'Public\Lenovo.ps1'
    'Public\WindowsUpdate.ps1'
    'Public\ScheduledTasks.ps1'
    'Public\Invoke-DriverManagement.ps1'
)

# Dot-source all files
foreach ($file in ($classFiles + $privateFiles + $publicFiles)) {
    $filePath = Join-Path $script:ModuleRoot $file
    if (Test-Path $filePath) {
        try {
            . $filePath
        }
        catch {
            Write-Error "Failed to load module component: $file - $($_.Exception.Message)"
            throw
        }
    }
    else {
        Write-Warning "Module component not found: $file"
    }
}

#endregion

#region Aliases

# Create aliases for common commands
New-Alias -Name 'idm' -Value 'Invoke-DriverManagement' -Scope Global -Force
New-Alias -Name 'gdcs' -Value 'Get-DriverComplianceStatus' -Scope Global -Force

#endregion

#region Module Load Actions

# Initialize configuration on module load
Initialize-ModuleConfiguration

# Export module configuration for inspection (read-only)
function Get-DriverManagementConfig {
    <#
    .SYNOPSIS
        Returns the current module configuration
    .DESCRIPTION
        Returns a copy of the module configuration. Use for inspection only.
    #>
    [CmdletBinding()]
    param()
    
    return $script:ModuleConfig.Clone()
}

#endregion

#region Module Unload Actions

$ExecutionContext.SessionState.Module.OnRemove = {
    # Cleanup actions when module is removed
    Remove-Alias -Name 'idm' -Scope Global -Force -ErrorAction SilentlyContinue
    Remove-Alias -Name 'gdcs' -Scope Global -Force -ErrorAction SilentlyContinue
}

#endregion

# Export additional helper
Export-ModuleMember -Function @(
    'Get-DriverManagementConfig'
) -Alias @(
    'idm'
    'gdcs'
)
