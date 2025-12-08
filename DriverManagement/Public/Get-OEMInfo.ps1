#Requires -Version 5.1

<#
.SYNOPSIS
    OEM detection functions for DriverManagement module
#>

function Get-OEMInfo {
    <#
    .SYNOPSIS
        Detects the OEM manufacturer and model information
    .DESCRIPTION
        Queries WMI to determine if the system is Dell or Lenovo and retrieves
        model-specific identifiers needed for driver management
    .EXAMPLE
        $oem = Get-OEMInfo
        if ($oem.OEM -eq 'Dell') { Write-Host "Dell $($oem.Model)" }
    .EXAMPLE
        Get-OEMInfo | Format-List
    .OUTPUTS
        OEMInfo object with OEM, Model, SystemID/MTM, and IsSupported properties
    #>
    [CmdletBinding()]
    [OutputType([OEMInfo])]
    param()
    
    $config = $script:ModuleConfig
    $oemInfo = [OEMInfo]::new()
    
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        
        $oemInfo.Manufacturer = $system.Manufacturer
        $oemInfo.SerialNumber = $bios.SerialNumber
        
        switch -Regex ($system.Manufacturer) {
            'Dell' {
                $oemInfo.OEM = [OEMType]::Dell
                $oemInfo.Model = $system.Model
                $oemInfo.SystemID = $system.SystemSKUNumber
                
                # Check if model is in supported list
                $oemInfo.IsSupported = $config.SupportedDellModels | Where-Object { 
                    $system.Model -like "*$_*" 
                } | Select-Object -First 1
            }
            'LENOVO' {
                $oemInfo.OEM = [OEMType]::Lenovo
                $oemInfo.Model = $product.Version  # Lenovo stores friendly name here
                $oemInfo.MTM = $product.Name.Substring(0, 4)  # First 4 chars are MTM
                
                # Check if MTM is in supported list
                $oemInfo.IsSupported = $oemInfo.MTM -in $config.SupportedLenovoMTMs
            }
            default {
                $oemInfo.OEM = [OEMType]::Unknown
                $oemInfo.Model = $system.Model
                $oemInfo.IsSupported = $false
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to detect OEM info: $($_.Exception.Message)" -Severity Error
        $oemInfo.OEM = [OEMType]::Unknown
        $oemInfo.IsSupported = $false
    }
    
    return $oemInfo
}

function Test-DriverManagementPrerequisites {
    <#
    .SYNOPSIS
        Tests if all prerequisites are met for driver management
    .DESCRIPTION
        Checks for required tools, elevation, and supported hardware
    .PARAMETER Detailed
        Returns detailed information about each prerequisite
    .EXAMPLE
        if (Test-DriverManagementPrerequisites) { Invoke-DriverManagement }
    .EXAMPLE
        Test-DriverManagementPrerequisites -Detailed | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Detailed
    )
    
    $results = @()
    $allPassed = $true
    
    # Check elevation
    $isElevated = Test-IsElevated
    $results += [PSCustomObject]@{
        Check = 'Elevation'
        Status = if ($isElevated) { 'Pass' } else { 'Fail' }
        Message = if ($isElevated) { 'Running as Administrator' } else { 'Requires elevation' }
        Required = $true
    }
    if (-not $isElevated) { $allPassed = $false }
    
    # Check OEM support
    $oemInfo = Get-OEMInfo
    $results += [PSCustomObject]@{
        Check = 'Supported Hardware'
        Status = if ($oemInfo.IsSupported) { 'Pass' } else { 'Skip' }
        Message = "$($oemInfo.OEM): $($oemInfo.Model)"
        Required = $false
    }
    
    # Check Dell Command Update (for Dell systems)
    if ($oemInfo.OEM -eq [OEMType]::Dell) {
        $dcuPath = Get-DellCommandUpdatePath
        $results += [PSCustomObject]@{
            Check = 'Dell Command Update'
            Status = if ($dcuPath) { 'Pass' } else { 'Warning' }
            Message = if ($dcuPath) { "Found at $dcuPath" } else { 'Not installed - will use catalog fallback' }
            Required = $false
        }
    }
    
    # Check LSUClient (for Lenovo systems)
    if ($oemInfo.OEM -eq [OEMType]::Lenovo) {
        $lsuClient = Get-Module -ListAvailable -Name LSUClient
        $results += [PSCustomObject]@{
            Check = 'LSUClient Module'
            Status = if ($lsuClient) { 'Pass' } else { 'Warning' }
            Message = if ($lsuClient) { "Version $($lsuClient.Version)" } else { 'Not installed - will attempt to install' }
            Required = $false
        }
    }
    
    # Check pending reboot
    $pendingReboot = Test-PendingReboot
    $results += [PSCustomObject]@{
        Check = 'Pending Reboot'
        Status = if (-not $pendingReboot) { 'Pass' } else { 'Warning' }
        Message = if (-not $pendingReboot) { 'No pending reboot' } else { 'Reboot pending - may defer updates' }
        Required = $false
    }
    
    # Check network connectivity
    $networkOk = Test-Connection -ComputerName 'downloads.dell.com' -Count 1 -Quiet -ErrorAction SilentlyContinue
    $results += [PSCustomObject]@{
        Check = 'Network Connectivity'
        Status = if ($networkOk) { 'Pass' } else { 'Warning' }
        Message = if ($networkOk) { 'Can reach update servers' } else { 'May have connectivity issues' }
        Required = $false
    }
    
    if ($Detailed) {
        return $results
    }
    
    return $allPassed
}
