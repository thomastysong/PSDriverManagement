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
    .PARAMETER IncludeIntel
        Include Intel driver updates (default: auto-detect Intel devices)
    .PARAMETER IntelOnly
        Only install Intel driver updates (skip OEM and Windows Updates)
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
    [OutputType('DriverUpdateResult')]
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
        [switch]$IncludeIntel = $true,
        
        [Parameter()]
        [switch]$IntelOnly,
        
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
            
            # Only warn about pending reboot, don't block - allow Intel/Windows Updates to proceed
            if (Test-PendingReboot) {
                Write-DriverLog -Message "Pending reboot detected - proceeding with updates anyway" -Severity Warning
            }
        }
        
        # Intel-only mode: skip OEM and Windows Updates
        if ($IntelOnly) {
            Write-DriverLog -Message "Intel-only mode: skipping OEM and Windows Updates" -Severity Info
            
            # Detect Intel devices
            $intelDevices = Get-IntelDevices
            if ($intelDevices.Count -eq 0) {
                $result.Success = $true
                $result.Message = "No Intel devices detected"
                $result.ExitCode = 0
                Update-DriverComplianceStatus -Status Compliant -Message $result.Message
                return $result
            }
            
            # Install Intel updates
            $intelResult = Install-IntelDriverUpdates -NoReboot:$NoReboot
            
            $result.Success = $intelResult.Success
            $result.Message = $intelResult.Message
            $result.UpdatesApplied = $intelResult.UpdatesApplied
            $result.RebootRequired = $intelResult.RebootRequired
            $result.Details['IntelResult'] = $intelResult.ToHashtable()
        }
        else {
            # Normal mode: OEM + Intel + Windows Updates
            
            # Detect OEM
            $oemInfo = Get-OEMInfo
            Write-DriverLog -Message "Detected: $($oemInfo.OEM) $($oemInfo.Model)" -Severity Info `
                -Context @{ OEM = $oemInfo.OEM.ToString(); Model = $oemInfo.Model; Supported = $oemInfo.IsSupported }
            
            $oemUpdatesApplied = $false
            
            # Execute OEM-specific updates (if supported)
            if ($oemInfo.IsSupported) {
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
                $oemUpdatesApplied = $true
            }
            else {
                Write-DriverLog -Message "Unsupported OEM hardware - skipping OEM driver updates" -Severity Warning
                # Don't set result.Success = false here - allow Intel/Windows Updates to proceed
                $result.Success = $true
                $result.Message = "Skipped OEM updates - unsupported model: $($oemInfo.Model)"
            }
            
            # Intel Updates if requested (proceed even if OEM failed or was skipped)
            $intelDevices = @()
            if ($IncludeIntel) {
                Write-DriverLog -Message "Processing Intel driver updates" -Severity Info
                
                $intelDevices = Get-IntelDevices
                if ($intelDevices.Count -gt 0) {
                    $intelResult = Install-IntelDriverUpdates -NoReboot:$NoReboot
                    
                    $result.UpdatesApplied += $intelResult.UpdatesApplied
                    $result.RebootRequired = $result.RebootRequired -or $intelResult.RebootRequired
                    $result.Details['IntelResult'] = $intelResult.ToHashtable()
                    
                    if (-not $intelResult.Success) {
                        if ($result.Message) {
                            $result.Message += "; Intel driver update issues"
                        }
                        else {
                            $result.Message = $intelResult.Message
                        }
                        # Only fail if OEM also failed and Intel failed
                        if (-not $oemUpdatesApplied -or -not $result.Success) {
                            $result.Success = $false
                        }
                    }
                    elseif ($intelResult.UpdatesApplied -gt 0) {
                        if ($result.Message -and $result.Message -notmatch "Intel") {
                            $result.Message += "; Intel updates applied"
                        }
                        elseif (-not $result.Message) {
                            $result.Message = $intelResult.Message
                        }
                        $result.Success = $true  # At least Intel updates succeeded
                    }
                }
                else {
                    Write-DriverLog -Message "No Intel devices detected" -Severity Info
                }
            }
            
            # Windows Updates if requested (proceed even if OEM/Intel failed)
            if ($IncludeWindowsUpdates) {
                Write-DriverLog -Message "Processing Windows Updates" -Severity Info
                
                $wuResult = Install-WindowsUpdates -NoReboot:$NoReboot
                
                $result.UpdatesApplied += $wuResult.UpdatesApplied
                $result.RebootRequired = $result.RebootRequired -or $wuResult.RebootRequired
                $result.Details['WindowsUpdateResult'] = $wuResult.ToHashtable()
                
                if (-not $wuResult.Success) {
                    if ($result.Message) {
                        $result.Message += "; Windows Update issues"
                    }
                    else {
                        $result.Message = $wuResult.Message
                    }
                    # Only fail if nothing else succeeded
                    if ($result.UpdatesApplied -eq 0) {
                        $result.Success = $false
                    }
                }
                elseif ($wuResult.UpdatesApplied -gt 0) {
                    if ($result.Message -and $result.Message -notmatch "Windows") {
                        $result.Message += "; Windows Updates applied"
                    }
                    elseif (-not $result.Message) {
                        $result.Message = $wuResult.Message
                    }
                    $result.Success = $true  # At least Windows Updates succeeded
                }
            }
            
            # If no updates were applied at all, set appropriate message
            if ($result.UpdatesApplied -eq 0) {
                if (-not $oemInfo.IsSupported -and $intelDevices.Count -eq 0 -and -not $IncludeWindowsUpdates) {
                    $result.Message = "No OEM support, no Intel devices, and Windows Updates not requested"
                }
                elseif (-not $oemInfo.IsSupported -and $intelDevices.Count -eq 0) {
                    $result.Message = "No OEM support and no Intel devices detected"
                }
                $result.Success = $true  # Not an error, just nothing to update
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
