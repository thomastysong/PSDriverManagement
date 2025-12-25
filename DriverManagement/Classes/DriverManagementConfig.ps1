#Requires -Version 5.1

<#
.SYNOPSIS
    Class definitions for DriverManagement module
#>

# Enum for update modes
enum DriverUpdateMode {
    Individual
    FullPack
}

# Enum for OEM types
enum OEMType {
    Dell
    Lenovo
    Unknown
}

# Enum for update types
enum UpdateType {
    Driver
    BIOS
    Firmware
    All
}

# Enum for severity levels
enum UpdateSeverity {
    Critical
    Recommended
    Optional
}

# Enum for compliance status
enum ComplianceStatus {
    Compliant
    NonCompliant
    Pending
    Error
    Unknown
}

# Class for OEM information
class OEMInfo {
    [OEMType]$OEM
    [string]$Manufacturer
    [string]$Model
    [string]$SystemID
    [string]$MTM
    [bool]$IsSupported
    [string]$SerialNumber
    
    OEMInfo() {
        $this.OEM = [OEMType]::Unknown
        $this.IsSupported = $false
    }
    
    [string] ToString() {
        return "$($this.OEM): $($this.Model)"
    }
}

# Class for driver update result
class DriverUpdateResult {
    [bool]$Success
    [string]$Message
    [int]$ExitCode
    [bool]$RebootRequired
    [int]$UpdatesApplied
    [int]$UpdatesFailed
    [datetime]$Timestamp
    [string]$CorrelationId
    [hashtable]$Details
    
    DriverUpdateResult() {
        $this.Timestamp = [datetime]::UtcNow
        $this.Details = @{}
    }
    
    [hashtable] ToHashtable() {
        return @{
            Success = $this.Success
            Message = $this.Message
            ExitCode = $this.ExitCode
            RebootRequired = $this.RebootRequired
            UpdatesApplied = $this.UpdatesApplied
            UpdatesFailed = $this.UpdatesFailed
            Timestamp = $this.Timestamp.ToString('o')
            CorrelationId = $this.CorrelationId
            Details = $this.Details
        }
    }
}

# Class for compliance status
class DriverComplianceStatus {
    [string]$SchemaVersion
    [string]$Version
    [ComplianceStatus]$Status
    [datetime]$LastCheckDate
    [string]$Computer
    [OEMType]$OEM
    [string]$Model
    [bool]$UpToDate
    [bool]$ScanIncomplete
    [bool]$RebootPending
    [int]$UpdatesApplied
    [int]$UpdatesPending
    [object[]]$PendingUpdates
    [object[]]$HardwareIssues
    [object[]]$Errors
    [hashtable]$Summary
    [string]$Message
    [string]$CorrelationId
    
    DriverComplianceStatus() {
        $this.SchemaVersion = "2.0"
        $this.Version = "1.0.0"
        $this.Status = [ComplianceStatus]::Unknown
        $this.LastCheckDate = [datetime]::UtcNow
        $this.Computer = $env:COMPUTERNAME
        $this.UpToDate = $false
        $this.ScanIncomplete = $true
        $this.RebootPending = $false
        $this.PendingUpdates = @()
        $this.HardwareIssues = @()
        $this.Errors = @()
        $this.Summary = @{}
    }
    
    [hashtable] ToHashtable() {
        $pendingCount = if ($this.PendingUpdates) { @($this.PendingUpdates).Count } else { 0 }
        $hardwareCount = if ($this.HardwareIssues) { @($this.HardwareIssues).Count } else { 0 }
        $errorCount = if ($this.Errors) { @($this.Errors).Count } else { 0 }

        # NOTE: In PowerShell classes, locals cannot share names with properties (case-insensitive).
        $summaryLocal = if ($this.Summary) { $this.Summary } else { @{} }
        try {
            if (-not $summaryLocal.ContainsKey('PendingUpdatesCount')) { $summaryLocal['PendingUpdatesCount'] = $pendingCount }
            if (-not $summaryLocal.ContainsKey('HardwareIssuesCount')) { $summaryLocal['HardwareIssuesCount'] = $hardwareCount }
            if (-not $summaryLocal.ContainsKey('ErrorsCount')) { $summaryLocal['ErrorsCount'] = $errorCount }
        }
        catch {
            $summaryLocal = @{
                PendingUpdatesCount = $pendingCount
                HardwareIssuesCount = $hardwareCount
                ErrorsCount = $errorCount
            }
        }

        return @{
            SchemaVersion = $this.SchemaVersion
            Version = $this.Version
            Status = $this.Status.ToString()
            LastCheckDate = $this.LastCheckDate.ToString('o')
            Computer = $this.Computer
            OEM = $this.OEM.ToString()
            Model = $this.Model
            UpToDate = $this.UpToDate
            ScanIncomplete = $this.ScanIncomplete
            RebootPending = $this.RebootPending
            UpdatesApplied = $this.UpdatesApplied
            UpdatesPending = $this.UpdatesPending
            PendingUpdates = @($this.PendingUpdates)
            HardwareIssues = @($this.HardwareIssues)
            Errors = @($this.Errors)
            Summary = $summaryLocal
            Message = $this.Message
            CorrelationId = $this.CorrelationId
        }
    }
    
    static [DriverComplianceStatus] FromJson([string]$json) {
        $obj = $json | ConvertFrom-Json
        $result = [DriverComplianceStatus]::new()
        if ($obj.PSObject.Properties.Match('SchemaVersion').Count -gt 0 -and $obj.SchemaVersion) { $result.SchemaVersion = [string]$obj.SchemaVersion }

        if ($obj.PSObject.Properties.Match('Version').Count -gt 0 -and $obj.Version) { $result.Version = [string]$obj.Version }
        if ($obj.PSObject.Properties.Match('Status').Count -gt 0 -and $obj.Status) { $result.Status = [ComplianceStatus]$obj.Status }
        if ($obj.PSObject.Properties.Match('LastCheckDate').Count -gt 0 -and $obj.LastCheckDate) { $result.LastCheckDate = [datetime]$obj.LastCheckDate }
        if ($obj.PSObject.Properties.Match('Computer').Count -gt 0 -and $obj.Computer) { $result.Computer = [string]$obj.Computer }
        if ($obj.PSObject.Properties.Match('OEM').Count -gt 0 -and $obj.OEM) { $result.OEM = [OEMType]$obj.OEM }
        if ($obj.PSObject.Properties.Match('Model').Count -gt 0 -and $obj.Model) { $result.Model = [string]$obj.Model }

        if ($obj.PSObject.Properties.Match('UpToDate').Count -gt 0 -and $null -ne $obj.UpToDate) { $result.UpToDate = [bool]$obj.UpToDate }
        if ($obj.PSObject.Properties.Match('ScanIncomplete').Count -gt 0 -and $null -ne $obj.ScanIncomplete) { $result.ScanIncomplete = [bool]$obj.ScanIncomplete }
        if ($obj.PSObject.Properties.Match('RebootPending').Count -gt 0 -and $null -ne $obj.RebootPending) { $result.RebootPending = [bool]$obj.RebootPending }

        if ($obj.PSObject.Properties.Match('UpdatesApplied').Count -gt 0 -and $null -ne $obj.UpdatesApplied) { $result.UpdatesApplied = [int]$obj.UpdatesApplied }
        if ($obj.PSObject.Properties.Match('UpdatesPending').Count -gt 0 -and $null -ne $obj.UpdatesPending) { $result.UpdatesPending = [int]$obj.UpdatesPending }

        if ($obj.PSObject.Properties.Match('PendingUpdates').Count -gt 0 -and $obj.PendingUpdates) { $result.PendingUpdates = @($obj.PendingUpdates) } else { $result.PendingUpdates = @() }
        if ($obj.PSObject.Properties.Match('HardwareIssues').Count -gt 0 -and $obj.HardwareIssues) { $result.HardwareIssues = @($obj.HardwareIssues) } else { $result.HardwareIssues = @() }
        if ($obj.PSObject.Properties.Match('Errors').Count -gt 0 -and $obj.Errors) { $result.Errors = @($obj.Errors) } else { $result.Errors = @() }
        if ($obj.PSObject.Properties.Match('Summary').Count -gt 0 -and $obj.Summary) { $result.Summary = @{} + $obj.Summary } else { $result.Summary = @{} }

        if ($obj.PSObject.Properties.Match('Message').Count -gt 0 -and $obj.Message) { $result.Message = [string]$obj.Message }
        if ($obj.PSObject.Properties.Match('CorrelationId').Count -gt 0 -and $obj.CorrelationId) { $result.CorrelationId = [string]$obj.CorrelationId }
        return $result
    }
}

# Class for log entry
class DriverLogEntry {
    [datetime]$Timestamp
    [string]$Severity
    [string]$Component
    [string]$CorrelationId
    [string]$Computer
    [string]$User
    [int]$ProcessId
    [string]$Message
    [hashtable]$Context
    
    DriverLogEntry([string]$message, [string]$severity) {
        $this.Timestamp = [datetime]::UtcNow
        $this.Severity = $severity
        $this.Component = 'DriverManagement'
        $this.Computer = $env:COMPUTERNAME
        $this.User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $this.ProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $this.Message = $message
        $this.Context = @{}
    }
    
    [string] ToJson() {
        return $this | ConvertTo-Json -Compress -Depth 5
    }
}
