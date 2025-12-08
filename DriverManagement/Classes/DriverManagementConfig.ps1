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
    [string]$Version
    [ComplianceStatus]$Status
    [datetime]$LastCheckDate
    [string]$Computer
    [OEMType]$OEM
    [string]$Model
    [int]$UpdatesApplied
    [int]$UpdatesPending
    [string]$Message
    [string]$CorrelationId
    
    DriverComplianceStatus() {
        $this.Version = "1.0.0"
        $this.Status = [ComplianceStatus]::Unknown
        $this.LastCheckDate = [datetime]::UtcNow
        $this.Computer = $env:COMPUTERNAME
    }
    
    [hashtable] ToHashtable() {
        return @{
            Version = $this.Version
            Status = $this.Status.ToString()
            LastCheckDate = $this.LastCheckDate.ToString('o')
            Computer = $this.Computer
            OEM = $this.OEM.ToString()
            Model = $this.Model
            UpdatesApplied = $this.UpdatesApplied
            UpdatesPending = $this.UpdatesPending
            Message = $this.Message
            CorrelationId = $this.CorrelationId
        }
    }
    
    static [DriverComplianceStatus] FromJson([string]$json) {
        $obj = $json | ConvertFrom-Json
        $status = [DriverComplianceStatus]::new()
        $status.Version = $obj.Version
        $status.Status = [ComplianceStatus]$obj.Status
        $status.LastCheckDate = [datetime]$obj.LastCheckDate
        $status.Computer = $obj.Computer
        $status.OEM = [OEMType]$obj.OEM
        $status.Model = $obj.Model
        $status.UpdatesApplied = $obj.UpdatesApplied
        $status.UpdatesPending = $obj.UpdatesPending
        $status.Message = $obj.Message
        $status.CorrelationId = $obj.CorrelationId
        return $status
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
        $this.ProcessId = $PID
        $this.Message = $message
        $this.Context = @{}
    }
    
    [string] ToJson() {
        return $this | ConvertTo-Json -Compress -Depth 5
    }
}
