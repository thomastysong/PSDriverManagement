#Requires -Version 5.1

function Write-DriverStatusLogsInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Report,

        [Parameter()]
        [string]$OutputPath
    )

    # Always write JSON artifact (dual-logging default requirement)
    $artifact = Write-DriverStatusArtifactInternal -Report $Report -OutputPath $OutputPath

    # Determine severity -> event id/type mapping
    $sev = $null
    try { $sev = $Report.Health.Severity } catch { $sev = 'Warning' }

    $entryType = 'Information'
    $eventId = 1200
    switch ($sev) {
        'Healthy'  { $entryType = 'Information'; $eventId = 1200 }
        'Warning'  { $entryType = 'Warning';     $eventId = 2200 }
        'Degraded' { $entryType = 'Warning';     $eventId = 2200 }
        'Critical' { $entryType = 'Error';       $eventId = 3200 }
        default    { $entryType = 'Warning';     $eventId = 2200 }
    }

    $attempted = $true
    $written = $false
    $err = $null

    $logName = $script:ModuleConfig.EventLogName
    $source = $script:ModuleConfig.EventLogSource

    # Build summary message (must be small; do not embed full JSON)
    $msg = New-Object System.Collections.Generic.List[string]
    $msg.Add('PSDriverManagement Status Summary') | Out-Null
    $msg.Add(("Computer: {0}" -f $Report.Host.ComputerName)) | Out-Null
    $msg.Add(("OEM: {0}" -f $Report.OEM.Detected)) | Out-Null
    $msg.Add(("LookbackHours: {0}" -f $Report.Lookback.Hours)) | Out-Null
    $msg.Add(("NonOkDevices: {0}" -f $Report.Devices.NonOkCount)) | Out-Null
    $msg.Add(("KernelPnp411: {0}" -f $Report.DriverSignals.KernelPnp.ProblemStarting411.Count)) | Out-Null
    $msg.Add(("RebootPendingHeuristic: {0}" -f $Report.PendingReboot.IsRebootPending)) | Out-Null
    $msg.Add(("Severity: {0}" -f $Report.Health.Severity)) | Out-Null
    $msg.Add(("CorrelationId: {0}" -f $Report.CorrelationId)) | Out-Null
    $msg.Add('') | Out-Null
    $msg.Add('Top Kernel-PnP 411 Drivers:') | Out-Null

    $top = @()
    try { $top = @($Report.DriverSignals.KernelPnp.ProblemStarting411.TopDrivers | Select-Object -First 5) } catch { $top = @() }
    if (-not $top -or $top.Count -eq 0) {
        $msg.Add(' - (none)') | Out-Null
    }
    else {
        foreach ($d in $top) {
            $msg.Add((" - {0}: {1}" -f $d.DriverName, $d.Count)) | Out-Null
        }
    }

    $msg.Add('') | Out-Null
    $msg.Add(("JsonArtifact: {0}" -f $artifact.Path)) | Out-Null

    try {
        # Only write if source exists (Initialize-DriverManagementLogging will create it when elevated)
        if ([System.Diagnostics.EventLog]::SourceExists($source)) {
            Write-EventLog -LogName $logName -Source $source -EventId $eventId -EntryType $entryType -Message ($msg -join "`r`n") -ErrorAction Stop
            $written = $true
        }
        else {
            $written = $false
            $err = 'Event source missing (not elevated to create or not yet created)'
        }
    }
    catch {
        $written = $false
        $err = $_.Exception.Message
    }

    return [pscustomobject]@{
        EventLog = [pscustomobject]@{
            Attempted = $attempted
            Written = $written
            LogName = $logName
            Source = $source
            EventId = $eventId
            EntryType = $entryType
            Error = $err
        }
        JsonArtifact = [pscustomobject]@{
            Path = $artifact.Path
            Written = $artifact.Written
            Error = $artifact.Error
            Copy = $artifact.Copy
        }
    }
}


