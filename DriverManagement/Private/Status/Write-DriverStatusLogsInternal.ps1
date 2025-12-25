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

    # Determine compliance severity -> event id/type mapping (stable for FleetDM/Osquery)
    $complianceStatus = $null
    try { $complianceStatus = [string]$Report.Compliance.Status } catch { $complianceStatus = $null }
    if (-not $complianceStatus) { $complianceStatus = 'Pending' }

    $entryType = 'Information'
    $eventId = 1200
    switch ($complianceStatus) {
        'Compliant'    { $entryType = 'Information'; $eventId = 1200 }
        'NonCompliant' { $entryType = 'Warning';     $eventId = 2200 }
        'Pending'      { $entryType = 'Warning';     $eventId = 2200 }
        'Error'        { $entryType = 'Error';       $eventId = 3200 }
        default        { $entryType = 'Warning';     $eventId = 2200 }
    }

    $attempted = $true
    $written = $false
    $err = $null

    $logName = $script:ModuleConfig.EventLogName
    $source = $script:ModuleConfig.EventLogSource

    # Build single-line JSON summary message (best for Osquery/FleetDM parsing)
    $upToDate = $false
    $scanIncomplete = $true
    $rebootPending = $false
    $updatesPendingCount = 0
    $hardwareIssuesCount = 0
    $errorsCount = 0

    try { $upToDate = [bool]$Report.Compliance.UpToDate } catch { $upToDate = $false }
    try { $scanIncomplete = [bool]$Report.Compliance.ScanIncomplete } catch { $scanIncomplete = $true }
    try { $rebootPending = [bool]$Report.Compliance.RebootPending } catch { try { $rebootPending = [bool]$Report.PendingReboot.IsRebootPending } catch { $rebootPending = $false } }
    try { $updatesPendingCount = [int]$Report.Updates.PendingCount } catch { $updatesPendingCount = 0 }
    try { $hardwareIssuesCount = [int]$Report.Devices.NonOkCount } catch { $hardwareIssuesCount = 0 }
    try { $errorsCount = @($Report.Updates.Errors).Count } catch { $errorsCount = 0 }

    $summary = [ordered]@{
        EventType = 'StatusSummary'
        SchemaVersion = '1.0'
        GeneratedAt = $Report.GeneratedAt
        ComputerName = $Report.Host.ComputerName
        OEM = $Report.OEM.Detected
        Model = $Report.Host.Hardware.Model
        CorrelationId = $Report.CorrelationId

        ComplianceStatus = $complianceStatus
        UpToDate = $upToDate
        ScanIncomplete = $scanIncomplete
        RebootPending = $rebootPending

        UpdatesPendingCount = $updatesPendingCount
        HardwareIssuesCount = $hardwareIssuesCount
        ErrorsCount = $errorsCount

        ArtifactPath = $artifact.Path
    }

    $msg = ($summary | ConvertTo-Json -Compress -Depth 6)

    try {
        # Only write if source exists (Initialize-DriverManagementLogging will create it when elevated)
        if ([System.Diagnostics.EventLog]::SourceExists($source)) {
            Write-EventLog -LogName $logName -Source $source -EventId $eventId -EntryType $entryType -Message $msg -ErrorAction Stop
            $written = $true

            # Emit per-issue events (bounded) so monitoring can alert on exact problems
            $maxIssueEvents = 25

            # 2101 UpdatePending (Warning) - avoid collision with Write-DriverLog's generic Warning event id (2001)
            $pending = @()
            try { $pending = @($Report.Updates.PendingUpdates | Select-Object -First $maxIssueEvents) } catch { $pending = @() }
            foreach ($u in $pending) {
                $evt = [ordered]@{
                    EventType = 'UpdatePending'
                    ComputerName = $Report.Host.ComputerName
                    CorrelationId = $Report.CorrelationId
                    Provider = $u.Provider
                    UpdateType = $u.UpdateType
                    Title = $u.Title
                    Identifier = $u.Identifier
                    InstalledVersion = $u.InstalledVersion
                    AvailableVersion = $u.AvailableVersion
                    Severity = $u.Severity
                    RebootRequired = $u.RebootRequired
                }
                Write-EventLog -LogName $logName -Source $source -EventId 2101 -EntryType Warning -Message ($evt | ConvertTo-Json -Compress -Depth 6) -ErrorAction SilentlyContinue
            }

            # 2102 HardwareIssue (Warning)
            $hw = @()
            try { $hw = @($Report.Devices.NonOkDevices | Select-Object -First $maxIssueEvents) } catch { $hw = @() }
            foreach ($d in $hw) {
                $evt = [ordered]@{
                    EventType = 'HardwareIssue'
                    ComputerName = $Report.Host.ComputerName
                    CorrelationId = $Report.CorrelationId
                    FriendlyName = $d.FriendlyName
                    Class = $d.Class
                    InstanceId = $d.InstanceId
                    Status = $d.Status
                    Problem = $d.Problem
                    ConfigManagerErrorCode = $d.ConfigManagerErrorCode
                    ErrorDescription = $d.ErrorDescription
                    Remediation = $d.Remediation
                    DriverProviderName = $d.DriverProviderName
                    DriverVersion = $d.DriverVersion
                    InfName = $d.InfName
                }
                Write-EventLog -LogName $logName -Source $source -EventId 2102 -EntryType Warning -Message ($evt | ConvertTo-Json -Compress -Depth 6) -ErrorAction SilentlyContinue
            }

            # 3101 ProviderScanError (Error) - avoid collision with Write-DriverLog's generic Error event id (3001)
            $scanErrs = @()
            try { $scanErrs = @($Report.Updates.Errors | Select-Object -First $maxIssueEvents) } catch { $scanErrs = @() }
            foreach ($e in $scanErrs) {
                $evt = [ordered]@{
                    EventType = 'ProviderScanError'
                    ComputerName = $Report.Host.ComputerName
                    CorrelationId = $Report.CorrelationId
                    Provider = $e.Provider
                    Stage = $e.Stage
                    Message = $e.Message
                    Details = $e.Details
                }
                Write-EventLog -LogName $logName -Source $source -EventId 3101 -EntryType Error -Message ($evt | ConvertTo-Json -Compress -Depth 6) -ErrorAction SilentlyContinue
            }
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


