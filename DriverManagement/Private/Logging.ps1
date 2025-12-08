#Requires -Version 5.1

<#
.SYNOPSIS
    Logging functions for DriverManagement module
.DESCRIPTION
    Provides dual logging to Windows Event Log and structured JSON files
#>

function Initialize-DriverManagementLogging {
    <#
    .SYNOPSIS
        Initializes the logging infrastructure
    .DESCRIPTION
        Creates the Event Log source and log directory if they don't exist
    .EXAMPLE
        Initialize-DriverManagementLogging
    #>
    [CmdletBinding()]
    param()
    
    if ($script:LoggingInitialized) {
        return
    }
    
    $config = $script:ModuleConfig
    
    # Create Event Log source if it doesn't exist
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($config.EventLogSource)) {
            # Check if we have admin rights
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            
            if ($isAdmin) {
                New-EventLog -LogName $config.EventLogName -Source $config.EventLogSource -ErrorAction Stop
                Limit-EventLog -LogName $config.EventLogName -MaximumSize 100MB -OverflowAction OverwriteOlder -ErrorAction SilentlyContinue
            }
            else {
                Write-Verbose "Skipping Event Log creation - requires elevation"
            }
        }
    }
    catch {
        Write-Verbose "Could not create Event Log source: $($_.Exception.Message)"
    }
    
    # Ensure log directory exists
    $logDir = Split-Path $config.LogPath -Parent
    if (-not (Test-Path $config.LogPath)) {
        New-Item -Path $config.LogPath -ItemType Directory -Force | Out-Null
    }
    
    $script:LoggingInitialized = $true
}

function Write-DriverLog {
    <#
    .SYNOPSIS
        Writes a log entry to Event Log and JSON file
    .DESCRIPTION
        Dual-output logging with structured data support
    .PARAMETER Message
        The log message
    .PARAMETER Severity
        Log severity: Debug, Info, Warning, Error
    .PARAMETER Component
        Component name for categorization
    .PARAMETER Context
        Additional structured data to include
    .EXAMPLE
        Write-DriverLog -Message "Starting update" -Severity Info -Context @{Model = "Precision 5690"}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Severity = 'Info',
        
        [Parameter()]
        [string]$Component = 'DriverManagement',
        
        [Parameter()]
        [hashtable]$Context = @{}
    )
    
    # Ensure logging is initialized
    if (-not $script:LoggingInitialized) {
        Initialize-DriverManagementLogging
    }
    
    $config = $script:ModuleConfig
    
    # Create log entry object
    $logEntry = [DriverLogEntry]::new($Message, $Severity)
    $logEntry.Component = $Component
    $logEntry.CorrelationId = $script:CorrelationId
    $logEntry.Context = $Context
    
    # Console output based on severity
    switch ($Severity) {
        'Debug'   { Write-Debug "[$Severity] $Message" }
        'Info'    { Write-Verbose "[$Severity] $Message" }
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error $Message -ErrorAction Continue }
    }
    
    # Event Log output
    try {
        $eventIdMap = @{ 'Debug' = 1000; 'Info' = 1001; 'Warning' = 2001; 'Error' = 3001 }
        $entryTypeMap = @{ 'Debug' = 'Information'; 'Info' = 'Information'; 'Warning' = 'Warning'; 'Error' = 'Error' }
        
        $eventMessage = @"
$Message

Component: $Component
CorrelationId: $($script:CorrelationId)
Context: $($Context | ConvertTo-Json -Compress -Depth 3)
"@
        
        if ([System.Diagnostics.EventLog]::SourceExists($config.EventLogSource)) {
            Write-EventLog -LogName $config.EventLogName `
                           -Source $config.EventLogSource `
                           -EventId $eventIdMap[$Severity] `
                           -EntryType $entryTypeMap[$Severity] `
                           -Message $eventMessage `
                           -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Silently continue if Event Log write fails
    }
    
    # JSON file output
    try {
        $dateStamp = Get-Date -Format "yyyyMMdd"
        $logFile = Join-Path $config.LogPath "DriverManagement_$dateStamp.json"
        
        # Rotate log if > MaxLogSizeMB
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length / 1MB) -gt $config.MaxLogSizeMB) {
            $archiveName = "DriverManagement_${dateStamp}_$(Get-Date -Format 'HHmmss').json"
            Rename-Item $logFile (Join-Path $config.LogPath $archiveName) -ErrorAction SilentlyContinue
        }
        
        $logEntry.ToJson() | Add-Content -Path $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Silently continue if file write fails
    }
    
    # Cleanup old logs
    try {
        Get-ChildItem $config.LogPath -Filter "DriverManagement_*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$config.MaxLogAgeDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Silently continue
    }
}

function Get-DriverManagementLogs {
    <#
    .SYNOPSIS
        Retrieves driver management logs
    .DESCRIPTION
        Gets logs from JSON files with optional filtering
    .PARAMETER StartDate
        Filter logs after this date
    .PARAMETER EndDate
        Filter logs before this date
    .PARAMETER Severity
        Filter by severity level
    .PARAMETER Last
        Get last N log entries
    .EXAMPLE
        Get-DriverManagementLogs -Last 50 -Severity Error
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [datetime]$StartDate,
        
        [Parameter()]
        [datetime]$EndDate,
        
        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string[]]$Severity,
        
        [Parameter()]
        [int]$Last = 100
    )
    
    $config = $script:ModuleConfig
    $logs = @()
    
    $logFiles = Get-ChildItem $config.LogPath -Filter "DriverManagement_*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    
    foreach ($file in $logFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $entries = $content -split "`n" | Where-Object { $_ } | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { }
            }
            $logs += $entries
        }
        
        if ($logs.Count -ge $Last * 2) { break }  # Get enough for filtering
    }
    
    # Apply filters
    if ($StartDate) {
        $logs = $logs | Where-Object { [datetime]$_.Timestamp -ge $StartDate }
    }
    if ($EndDate) {
        $logs = $logs | Where-Object { [datetime]$_.Timestamp -le $EndDate }
    }
    if ($Severity) {
        $logs = $logs | Where-Object { $_.Severity -in $Severity }
    }
    
    return $logs | Select-Object -Last $Last
}
