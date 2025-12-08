#Requires -Version 5.1

<#
.SYNOPSIS
    Main driver management orchestration function
#>

function Invoke-DriverManagement {
    <#
    .SYNOPSIS
        Orchestrates driver and Windows update management
    .DESCRIPTION
        Main entry point for driver management. Detects OEM, applies appropriate
        driver updates, and optionally includes Windows Updates.
    .PARAMETER Mode
        Update mode: Individual (surgical updates) or FullPack (complete reinstall)
    .PARAMETER UpdateTypes
        Types of updates: Driver, BIOS, Firmware, All
    .PARAMETER Severity
        Severity levels: Critical, Recommended, Optional
    .PARAMETER IncludeWindowsUpdates
        Also install Windows cumulative updates
    .PARAMETER NoReboot
        Suppress automatic reboot
    .PARAMETER Force
        Skip prerequisite checks
    .EXAMPLE
        Invoke-DriverManagement
        # Individual driver updates for detected OEM
    .EXAMPLE
        Invoke-DriverManagement -Mode FullPack -NoReboot
        # Full driver pack reinstall without reboot
    .EXAMPLE
        Invoke-DriverManagement -IncludeWindowsUpdates -UpdateTypes Driver, BIOS
        # Update drivers and BIOS plus Windows Updates
    .OUTPUTS
        DriverUpdateResult object with success status and details
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([DriverUpdateResult])]
    param(
        [Parameter()]
        [ValidateSet('Individual', 'FullPack')]
        [string]$Mode = 'Individual',
        
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'All')]
        [string[]]$UpdateTypes = @('Driver'),
        
        [Parameter()]
        [ValidateSet('Critical', 'Recommended', 'Optional')]
        [string[]]$Severity = @('Critical', 'Recommended'),
        
        [Parameter()]
        [switch]$IncludeWindowsUpdates,
        
        [Parameter()]
        [switch]$NoReboot,
        
        [Parameter()]
        [switch]$Force
    )
    
    # Initialize
    $result = [DriverUpdateResult]::new()
    $result.CorrelationId = $script:CorrelationId
    
    Write-DriverLog -Message "=== Driver Management Session Started ===" -Severity Info `
        -Context @{ Mode = $Mode; UpdateTypes = $UpdateTypes; Severity = $Severity }
    
    try {
        # Check prerequisites unless forced
        if (-not $Force) {
            if (-not (Test-IsElevated)) {
                throw "Elevation required. Run as Administrator or use -Force to skip checks."
            }
            
            if (Test-PendingReboot) {
                Write-DriverLog -Message "Pending reboot detected - deferring updates" -Severity Warning
                $result.Success = $false
                $result.Message = "Pending reboot - updates deferred"
                $result.ExitCode = 3010
                Update-DriverComplianceStatus -Status Pending -Message $result.Message
                return $result
            }
        }
        
        # Detect OEM
        $oemInfo = Get-OEMInfo
        Write-DriverLog -Message "Detected: $($oemInfo.OEM) $($oemInfo.Model)" -Severity Info `
            -Context @{ OEM = $oemInfo.OEM.ToString(); Model = $oemInfo.Model; Supported = $oemInfo.IsSupported }
        
        if (-not $oemInfo.IsSupported) {
            Write-DriverLog -Message "Unsupported hardware - skipping driver updates" -Severity Warning
            $result.Success = $true
            $result.Message = "Skipped - unsupported model: $($oemInfo.Model)"
            $result.ExitCode = 0
            Update-DriverComplianceStatus -Status Compliant -Message $result.Message
            return $result
        }
        
        # Execute OEM-specific updates
        $oemResult = switch ($oemInfo.OEM) {
            'Dell' {
                if ($Mode -eq 'Individual') {
                    Install-DellDriverUpdates -UpdateTypes $UpdateTypes -Severity $Severity -NoReboot:$NoReboot
                }
                else {
                    Install-DellFullDriverPack -NoReboot:$NoReboot
                }
            }
            'Lenovo' {
                if ($Mode -eq 'Individual') {
                    Install-LenovoDriverUpdates -UpdateTypes $UpdateTypes -Severity $Severity -NoReboot:$NoReboot
                }
                else {
                    Install-LenovoFullDriverPack -NoReboot:$NoReboot
                }
            }
            default {
                $r = [DriverUpdateResult]::new()
                $r.Success = $false
                $r.Message = "Unknown OEM: $($oemInfo.OEM)"
                $r.ExitCode = 1
                $r
            }
        }
        
        # Merge OEM result
        $result.Success = $oemResult.Success
        $result.Message = $oemResult.Message
        $result.UpdatesApplied = $oemResult.UpdatesApplied
        $result.RebootRequired = $oemResult.RebootRequired
        $result.Details['OEMResult'] = $oemResult.ToHashtable()
        
        # Windows Updates if requested
        if ($IncludeWindowsUpdates -and $result.Success) {
            Write-DriverLog -Message "Processing Windows Updates" -Severity Info
            
            $wuResult = Install-WindowsUpdates -NoReboot:$NoReboot
            
            $result.UpdatesApplied += $wuResult.UpdatesApplied
            $result.RebootRequired = $result.RebootRequired -or $wuResult.RebootRequired
            $result.Details['WindowsUpdateResult'] = $wuResult.ToHashtable()
            
            if (-not $wuResult.Success) {
                $result.Message += "; Windows Update issues"
            }
        }
        
        # Set final exit code
        $result.ExitCode = if ($result.RebootRequired) { 3010 } 
                          elseif ($result.Success) { 0 } 
                          else { 1 }
        
        # Update compliance status
        $complianceStatus = if ($result.Success) { [ComplianceStatus]::Compliant } else { [ComplianceStatus]::Error }
        Update-DriverComplianceStatus -Status $complianceStatus `
            -UpdatesApplied $result.UpdatesApplied `
            -Message $result.Message
        
        Write-DriverLog -Message "=== Driver Management Session Complete ===" -Severity Info `
            -Context $result.ToHashtable()
    }
    catch {
        Write-DriverLog -Message "Fatal error: $($_.Exception.Message)" -Severity Error `
            -Context @{ 
                ExceptionType = $_.Exception.GetType().FullName
                StackTrace = $_.ScriptStackTrace 
            }
        
        $result.Success = $false
        $result.Message = $_.Exception.Message
        $result.ExitCode = 1
        
        Update-DriverComplianceStatus -Status Error -Message $_.Exception.Message
    }
    
    return $result
}

# Export for direct script invocation
if ($MyInvocation.InvocationName -ne '.') {
    # Script was invoked directly, not dot-sourced
    # This allows: powershell -File Invoke-DriverManagement.ps1 -Mode Individual
}
