#Requires -Version 5.1

<#
.SYNOPSIS
  Intune setup script: install DriverManagement and create a Scheduled Task to run `Invoke-DriverManagement -Status`.

.DESCRIPTION
  Designed for Intune PowerShell scripts (commonly running as SYSTEM).

  This script will:
  - Ensure `DriverManagement` module version >= RequiredModuleVersion is installed (AllUsers).
  - Write a runner script to: %ProgramData%\PSDriverManagement\Invoke-DriverManagementStatus.ps1
  - Register a Scheduled Task: \PSDriverManagement\Status (hourly, runs as SYSTEM, highest)
  - Start the task immediately

  Diagnostics are written as single-line JSON to:
  - STDOUT (captured by Intune script output)
  - %ProgramData%\PSDriverManagement\Setup\setup.jsonl
  - Windows Application Event Log (Source: PSDriverManagement-Fleet), stable Event IDs

.NOTES
  Event IDs (Application log, source PSDriverManagement-Fleet):
    5100 SetupStart
    5110 ModuleDetected
    5120 ModuleInstallAttempt
    5121 ModuleInstallResult
    5130 RunnerScriptWritten
    5140 ScheduledTaskRegisterAttempt
    5141 ScheduledTaskRegisterResult
    5150 ScheduledTaskStartAttempt
    5151 ScheduledTaskStartResult
    5199 SetupComplete
    5500 SetupFailed

  Exit codes:
    0 = Success
    1 = Failure (Intune should report failure)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#region Configuration

$RequiredModuleName = 'DriverManagement'
$RequiredModuleVersion = [version]'1.5.6'

$TaskPath = '\PSDriverManagement\'
$TaskName = 'Status'
$TaskFullName = 'PSDriverManagement\Status'

$ProgramDataRoot = Join-Path $env:ProgramData 'PSDriverManagement'
$RunnerScriptPath = Join-Path $ProgramDataRoot 'Invoke-DriverManagementStatus.ps1'

$SetupRoot = Join-Path $ProgramDataRoot 'Setup'
$SetupLogPath = Join-Path $SetupRoot 'setup.jsonl'

$EventLogName = 'Application'
$EventSource = 'PSDriverManagement-Fleet'

$WindowsPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:CorrelationId = [guid]::NewGuid().ToString()
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:EventSourceReady = $false

#endregion Configuration

#region Helpers

function Test-IsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-EventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
        }
        $script:EventSourceReady = $true
    }
    catch {
        $script:EventSourceReady = $false
    }
}

function Write-SetupLog {
    param(
        [Parameter(Mandatory)][int]$EventId,
        [Parameter(Mandatory)][ValidateSet('Information', 'Warning', 'Error')][string]$EntryType,
        [Parameter(Mandatory)][string]$EventType,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][hashtable]$Data = @{}
    )

    $userName = $env:USERNAME
    try { $userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }

    $payload = [ordered]@{
        Schema        = 'PSDriverManagement.Setup'
        SchemaVersion = '1.0'
        EventType     = $EventType
        Stage         = $Stage
        Message       = $Message
        EventId       = $EventId
        EntryType     = $EntryType

        TimestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        CorrelationId = $script:CorrelationId
        ComputerName  = $env:COMPUTERNAME
        UserName      = $userName
        ProcessId     = $PID

        Data          = $Data
    }

    $json = $payload | ConvertTo-Json -Compress -Depth 10

    # STDOUT (Intune output)
    Write-Output $json

    # File (jsonl)
    try {
        Ensure-Directory -Path $SetupRoot
        [System.IO.File]::AppendAllText($SetupLogPath, $json + [Environment]::NewLine, $script:Utf8NoBom)
    }
    catch { }

    # Windows Event Log (Application)
    try {
        if ($script:EventSourceReady -and [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-EventLog -LogName $EventLogName -Source $EventSource -EventId $EventId -EntryType $EntryType -Message $json
        }
    }
    catch { }
}

function Write-SetupFailure {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][object]$ErrorRecord
    )

    $ex = $null
    try { $ex = $ErrorRecord.Exception } catch { $ex = $null }

    $msg = $ErrorRecord.ToString()
    $hresult = $null
    $fqid = $null
    $stack = $null
    try { $msg = $ErrorRecord.Exception.Message } catch { }
    try { $hresult = $ErrorRecord.Exception.HResult } catch { }
    try { $fqid = $ErrorRecord.FullyQualifiedErrorId } catch { }
    try { $stack = $ErrorRecord.ScriptStackTrace } catch { }

    Write-SetupLog -EventId 5500 -EntryType Error -EventType 'SetupFailed' -Stage $Stage -Message 'Setup failed' -Data @{
        Error = $msg
        HResult = $hresult
        FullyQualifiedErrorId = $fqid
        ScriptStackTrace = $stack
    }
}

function Ensure-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.ServicePointManager]::SecurityProtocol
    }
    catch {
        Write-SetupLog -EventId 5120 -EntryType Warning -EventType 'ModuleInstallAttempt' -Stage 'EnsureTls12' `
            -Message 'Failed to set TLS 1.2 (non-fatal)' -Data @{ Error = $_.Exception.Message }
    }
}

function Ensure-NuGetProvider {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
}

function Ensure-PsGalleryTrusted {
    try {
        $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
    }
    catch {
        Write-SetupLog -EventId 5120 -EntryType Warning -EventType 'ModuleInstallAttempt' -Stage 'EnsurePsGalleryTrusted' `
            -Message 'Unable to set PSGallery trust (Install-Module may fail)' -Data @{ Error = $_.Exception.Message }
    }
}

function Get-InstalledModuleState {
    $mods = @(Get-Module -ListAvailable -Name $RequiredModuleName -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    $top = $mods | Select-Object -First 1

    return [pscustomobject]@{
        Found = [bool]$top
        HighestVersion = if ($top) { [version]$top.Version } else { $null }
        ModuleBase = if ($top) { $top.ModuleBase } else { $null }
        Count = $mods.Count
        All = @($mods | Select-Object Name, Version, ModuleBase)
    }
}

function Ensure-DriverManagementModule {
    $state = Get-InstalledModuleState

    $locations = @()
    foreach ($p in @(
        'C:\Program Files\WindowsPowerShell\Modules\DriverManagement',
        'C:\Program Files\PowerShell\Modules\DriverManagement',
        'C:\Program Files (x86)\WindowsPowerShell\Modules\DriverManagement',
        'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\DriverManagement',
        'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\Modules\DriverManagement'
    )) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { $locations += $p }
    }

    Write-SetupLog -EventId 5110 -EntryType Information -EventType 'ModuleDetected' -Stage 'DetectModule' `
        -Message 'Detected module state' -Data @{
            RequiredModuleVersion = $RequiredModuleVersion.ToString()
            Found = $state.Found
            HighestVersion = if ($state.HighestVersion) { $state.HighestVersion.ToString() } else { $null }
            ModuleBase = $state.ModuleBase
            SearchLocations = @($locations)
            Discovered = @($state.All)
        }

    if ($state.Found -and $state.HighestVersion -ge $RequiredModuleVersion) {
        Write-SetupLog -EventId 5121 -EntryType Information -EventType 'ModuleInstallResult' -Stage 'EnsureModule' `
            -Message 'Module already installed' -Data @{ Version = $state.HighestVersion.ToString(); ModuleBase = $state.ModuleBase }
        return
    }

    Write-SetupLog -EventId 5120 -EntryType Information -EventType 'ModuleInstallAttempt' -Stage 'EnsureModule' `
        -Message 'Installing module from PSGallery' -Data @{ Name = $RequiredModuleName; RequiredVersion = $RequiredModuleVersion.ToString(); Scope = 'AllUsers' }

    Ensure-Tls12
    Ensure-NuGetProvider
    Ensure-PsGalleryTrusted

    Install-Module -Name $RequiredModuleName -RequiredVersion $RequiredModuleVersion.ToString() -Scope AllUsers -Force -AllowClobber -Repository PSGallery -ErrorAction Stop

    $state2 = Get-InstalledModuleState
    if (-not $state2.Found -or $state2.HighestVersion -lt $RequiredModuleVersion) {
        throw "Module install verification failed. HighestVersion=$($state2.HighestVersion)"
    }

    Write-SetupLog -EventId 5121 -EntryType Information -EventType 'ModuleInstallResult' -Stage 'EnsureModule' `
        -Message 'Module installed' -Data @{ Version = $state2.HighestVersion.ToString(); ModuleBase = $state2.ModuleBase }
}

function Ensure-RunnerScript {
    Ensure-Directory -Path $ProgramDataRoot

    $moduleNameLiteral = $RequiredModuleName
    $moduleVersionLiteral = $RequiredModuleVersion.ToString()

    $content = @"
#Requires -Version 5.1
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

try {
  Import-Module '$moduleNameLiteral' -RequiredVersion '$moduleVersionLiteral' -Force
  Invoke-DriverManagement -Status -LookbackHours 2 | Out-Null
}
catch {
  # If status execution fails, record a machine-readable error in Application log.
  try {
    `$evt = [ordered]@{
      Schema = 'PSDriverManagement.Runner'
      SchemaVersion = '1.0'
      EventType = 'RunnerError'
      TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
      ComputerName = `$env:COMPUTERNAME
      Error = (`$_ | Out-String)
    }
    Write-EventLog -LogName '$EventLogName' -Source '$EventSource' -EventId 5000 -EntryType Error -Message (`$evt | ConvertTo-Json -Compress -Depth 6)
  }
  catch { }
}
"@

    [System.IO.File]::WriteAllText($RunnerScriptPath, $content, $script:Utf8NoBom)

    $hash = $null
    try { $hash = (Get-FileHash -Path $RunnerScriptPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = $null }

    Write-SetupLog -EventId 5130 -EntryType Information -EventType 'RunnerScriptWritten' -Stage 'EnsureRunnerScript' `
        -Message 'Wrote runner script' -Data @{ Path = $RunnerScriptPath; Sha256 = $hash; Bytes = (Get-Item -LiteralPath $RunnerScriptPath).Length }
}

function Ensure-ScheduledTask {
    if (-not (Test-Path -LiteralPath $WindowsPowerShellExe -ErrorAction SilentlyContinue)) {
        throw "Windows PowerShell not found at expected path: $WindowsPowerShellExe"
    }

    Write-SetupLog -EventId 5140 -EntryType Information -EventType 'ScheduledTaskRegisterAttempt' -Stage 'EnsureScheduledTask' `
        -Message 'Registering scheduled task' -Data @{ TaskName = $TaskName; TaskPath = $TaskPath; Runner = $RunnerScriptPath; Execute = $WindowsPowerShellExe }

    Import-Module ScheduledTasks -ErrorAction Stop

    $action = New-ScheduledTaskAction -Execute $WindowsPowerShellExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerScriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-SetupLog -EventId 5140 -EntryType Warning -EventType 'ScheduledTaskRegisterAttempt' -Stage 'EnsureScheduledTask' `
                -Message 'Failed to unregister existing task (will retry register anyway)' -Data @{ Error = $_.Exception.Message }
        }
    }

    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop

    $taskState = $null
    $lastRunTime = $null
    $lastTaskResult = $null
    $nextRunTime = $null
    try { $taskState = $t.State.ToString() } catch { }
    try { $lastRunTime = $info.LastRunTime.ToString('o') } catch { }
    try { $lastTaskResult = $info.LastTaskResult } catch { }
    try { $nextRunTime = $info.NextRunTime.ToString('o') } catch { }

    Write-SetupLog -EventId 5141 -EntryType Information -EventType 'ScheduledTaskRegisterResult' -Stage 'EnsureScheduledTask' `
        -Message 'Scheduled task registered' -Data @{
            TaskExists = $true
            State = $taskState
            LastRunTime = $lastRunTime
            LastTaskResult = $lastTaskResult
            NextRunTime = $nextRunTime
        }

    Write-SetupLog -EventId 5150 -EntryType Information -EventType 'ScheduledTaskStartAttempt' -Stage 'EnsureScheduledTask' `
        -Message 'Starting scheduled task' -Data @{ TaskName = $TaskName; TaskPath = $TaskPath }

    $before = $info.LastRunTime
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop

    # Poll briefly so we can report whether it actually ran.
    $maxWaitSeconds = 45
    $deadline = (Get-Date).AddSeconds($maxWaitSeconds)
    do {
        Start-Sleep -Seconds 3
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    } while ($info -and $info.LastRunTime -le $before -and (Get-Date) -lt $deadline)

    $lastRunTime2 = $null
    $lastTaskResult2 = $null
    $nextRunTime2 = $null
    $observedRun = $false
    try { $lastRunTime2 = $info.LastRunTime.ToString('o') } catch { }
    try { $lastTaskResult2 = $info.LastTaskResult } catch { }
    try { $nextRunTime2 = $info.NextRunTime.ToString('o') } catch { }
    try { $observedRun = [bool]($info.LastRunTime -gt $before) } catch { $observedRun = $false }

    Write-SetupLog -EventId 5151 -EntryType Information -EventType 'ScheduledTaskStartResult' -Stage 'EnsureScheduledTask' `
        -Message 'Scheduled task start issued' -Data @{
            LastRunTime = $lastRunTime2
            LastTaskResult = $lastTaskResult2
            NextRunTime = $nextRunTime2
            ObservedRun = $observedRun
            MaxWaitSeconds = $maxWaitSeconds
        }
}

#endregion Helpers

try {
    Ensure-Directory -Path $SetupRoot
    Initialize-EventSource

    Write-SetupLog -EventId 5100 -EntryType Information -EventType 'SetupStart' -Stage 'Start' -Message 'Setup starting' -Data @{
        RequiredModuleName = $RequiredModuleName
        RequiredModuleVersion = $RequiredModuleVersion.ToString()
        TaskFullName = $TaskFullName
        RunnerScriptPath = $RunnerScriptPath
        ProgramDataRoot = $ProgramDataRoot
        SetupLogPath = $SetupLogPath
        EventLogName = $EventLogName
        EventSource = $EventSource
        EventSourceReady = $script:EventSourceReady
        IsAdmin = (Test-IsAdministrator)
        PSVersion = $PSVersionTable.PSVersion.ToString()
        Is64BitProcess = [Environment]::Is64BitProcess
        Is64BitOS = [Environment]::Is64BitOperatingSystem
    }

    try {
        Ensure-DriverManagementModule
    }
    catch {
        Write-SetupFailure -Stage 'EnsureModule' -ErrorRecord $_
        throw
    }

    try {
        Ensure-RunnerScript
    }
    catch {
        Write-SetupFailure -Stage 'EnsureRunnerScript' -ErrorRecord $_
        throw
    }

    try {
        Ensure-ScheduledTask
    }
    catch {
        Write-SetupFailure -Stage 'EnsureScheduledTask' -ErrorRecord $_
        throw
    }

    Write-SetupLog -EventId 5199 -EntryType Information -EventType 'SetupComplete' -Stage 'End' -Message 'Setup complete' -Data @{
        RequiredModuleVersion = $RequiredModuleVersion.ToString()
        TaskFullName = $TaskFullName
        RunnerScriptPath = $RunnerScriptPath
        SetupLogPath = $SetupLogPath
    }

    exit 0
}
catch {
    # If we already emitted a stage-specific SetupFailed, avoid spamming; still ensure Intune gets a non-zero exit.
    exit 1
}


