#Requires -Version 5.1

<#
.SYNOPSIS
  Prototype collector: harvest driver/device health signals locally (PnP state, installed drivers, event logs, reboot pending).

.DESCRIPTION
  Standalone script (NOT integrated into the DriverManagement module yet).
  Intended to help design a future `-Status` mode for PSDriverManagement.

  Outputs a single object with:
  - System/OEM/tooling inventory
  - Device state (Get-PnpDevice) + signed driver info (Win32_PnPSignedDriver)
  - Recent Kernel-PnP/Configuration errors (EventId 411: "had a problem starting")
  - Reboot pending indicators
  - Optional best-effort write to Windows Event Log

.PARAMETER LookbackDays
  How far back to query event logs for driver-related signals.

.PARAMETER IncludeDriverInventory
  If set, enumerates driver store via pnputil.exe and returns a parsed inventory summary.

.PARAMETER IncludeSetupApiTail
  If set, reads the last N lines of setupapi.dev.log to capture recent device install failures.

.PARAMETER SetupApiTailLines
  Tail size for setupapi.dev.log when -IncludeSetupApiTail is used.

.PARAMETER WriteEventLog
  Best-effort write a summary event into Application log.
  If elevated, will create the event source if missing. If not elevated, it will only write if the source already exists.

.PARAMETER EventLogName
  Target event log name (default: Application).

.PARAMETER EventSource
  Event source to use/create when -WriteEventLog is specified.

.OUTPUTS
  PSCustomObject (driver state harvest)

.EXAMPLE
  .\Invoke-DriverStateHarvest.ps1 -LookbackDays 30 -IncludeDriverInventory -IncludeSetupApiTail -WriteEventLog
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$LookbackDays = 30,

    [Parameter()]
    [switch]$IncludeDriverInventory,

    [Parameter()]
    [switch]$IncludeSetupApiTail,

    [Parameter()]
    [ValidateRange(50, 5000)]
    [int]$SetupApiTailLines = 400,

    [Parameter()]
    [switch]$WriteEventLog,

    [Parameter()]
    [string]$EventLogName = 'Application',

    [Parameter()]
    [string]$EventSource = 'PSDriverManagement-StatusPrototype'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [Security.Principal.WindowsPrincipal]::new($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-PendingRebootState {
    [CmdletBinding()]
    param()

    $pending = [ordered]@{}

    $pending.CBSRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $pending.WURebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

    $pfr = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $pending.PendingFileRenameOperationsCount = if ($pfr) { @($pfr).Count } else { 0 }

    $cn = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $acn = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $pending.PendingComputerRename = ($cn -and $acn -and ($cn -ne $acn))

    # Heuristic "any pending" – use this for a warning only (not a definitive reboot-required for drivers).
    $pending.IsRebootPending = [bool]($pending.CBSRebootPending -or $pending.WURebootRequired -or $pending.PendingComputerRename -or ($pending.PendingFileRenameOperationsCount -gt 0))

    [pscustomobject]$pending
}

function Get-OemToolingState {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $mfr = ($cs.Manufacturer | ForEach-Object { $_.Trim() })

    $isDell = $mfr -match 'Dell'
    $isLenovo = $mfr -match 'Lenovo'

    $dcuPaths = @(
        Join-Path $env:ProgramFiles 'Dell\CommandUpdate\dcu-cli.exe'
        Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }

    $dcuRegPaths = @(
        'HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate'
        'HKLM:\SOFTWARE\DELL\CommandUpdate'
    )
    $dcuVersion = $null
    foreach ($rp in $dcuRegPaths) {
        if (Test-Path $rp) {
            try {
                $r = Get-ItemProperty -Path $rp -ErrorAction Stop
                $dcuVersion = if ($r.Version) { $r.Version } elseif ($r.ProductVersion) { $r.ProductVersion } else { $null }
                if ($dcuVersion) { break }
            }
            catch { }
        }
    }

    $lenovoThinInstaller = Join-Path ${env:ProgramFiles(x86)} 'Lenovo\ThinInstaller\ThinInstaller.exe'
    $lenovoSystemUpdate = Join-Path ${env:ProgramFiles(x86)} 'Lenovo\System Update\tvsu.exe'
    $lsuClientModule = [bool](Get-Module -ListAvailable -Name LSUClient -ErrorAction SilentlyContinue)

    $dcuLogDirs = @(
        Join-Path $env:ProgramData 'Dell\CommandUpdate\Log'
        Join-Path $env:ProgramData 'Dell\UpdateService\Log'
        Join-Path $env:ProgramData 'Dell\Logs'
    )
    $existingDcuLogDirs = $dcuLogDirs | Where-Object { Test-Path $_ }

    $lenovoLogDirs = @(
        Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs'
        Join-Path $env:ProgramData 'Lenovo\System Update\logs'
        Join-Path $env:ProgramData 'Lenovo\Vantage\Logs'
    )
    $existingLenovoLogDirs = $lenovoLogDirs | Where-Object { Test-Path $_ }

    [pscustomobject]@{
        Manufacturer = $mfr
        Model = $cs.Model
        IsDell = $isDell
        IsLenovo = $isLenovo
        DellCommandUpdate = [pscustomobject]@{
            Present = ((@($dcuPaths).Count -gt 0) -or [bool]$dcuVersion)
            Version = $dcuVersion
            CliPath = ($dcuPaths | Select-Object -First 1)
            LogDirectories = @($existingDcuLogDirs)
        }
        Lenovo = [pscustomobject]@{
            ThinInstallerPresent = Test-Path $lenovoThinInstaller
            ThinInstallerPath = if (Test-Path $lenovoThinInstaller) { $lenovoThinInstaller } else { $null }
            SystemUpdatePresent = Test-Path $lenovoSystemUpdate
            SystemUpdatePath = if (Test-Path $lenovoSystemUpdate) { $lenovoSystemUpdate } else { $null }
            LSUClientModulePresent = $lsuClientModule
            LogDirectories = @($existingLenovoLogDirs)
        }
    }
}

function Get-ProblemDevices {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$Top = 100
    )

    $nonOk = Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' }
    $rows = foreach ($d in ($nonOk | Select-Object -First $Top)) {
        # Win32_PnPSignedDriver.DeviceID matches Get-PnpDevice.InstanceId on modern Windows
        $sd = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $d.InstanceId } | Select-Object -First 1

        [pscustomobject]@{
            Status = $d.Status
            Class = $d.Class
            FriendlyName = $d.FriendlyName
            InstanceId = $d.InstanceId
            Problem = $d.Problem
            ConfigManagerErrorCode = $d.ConfigManagerErrorCode
            DriverProviderName = $sd.DriverProviderName
            DriverVersion = $sd.DriverVersion
            DriverDate = $sd.DriverDate
            InfName = $sd.InfName
            Manufacturer = $sd.Manufacturer
        }
    }

    [pscustomobject]@{
        NonOkCount = @($nonOk).Count
        NonOkDevices = @($rows)
    }
}

function Get-KernelPnpProblemStartingEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Since
    )

    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 411; StartTime = $Since } -ErrorAction SilentlyContinue
    $rows = foreach ($e in $events) {
        $m = $e.Message

        $dev = if ($m -match '^Device\s+(.+?)\s+had a problem starting\.') { $Matches[1] } else { $null }
        $drv = if ($m -match '(?im)Driver Name:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $clsGuid = if ($m -match '(?im)Class GUID:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $svc = if ($m -match '(?im)Service:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $prob = if ($m -match '(?im)Problem:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $pstat = if ($m -match '(?im)Problem Status:\s*(.+)$') { $Matches[1].Trim() } else { $null }

        [pscustomobject]@{
            TimeCreated = $e.TimeCreated
            DeviceId = $dev
            DriverName = $drv
            ClassGuid = $clsGuid
            Service = $svc
            Problem = $prob
            ProblemStatus = $pstat
        }
    }

    $byDevice = $rows | Group-Object DeviceId | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{ DeviceId = $_.Name; Count = $_.Count }
    }
    $byDriver = $rows | Group-Object DriverName | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{ DriverName = $_.Name; Count = $_.Count }
    }

    [pscustomobject]@{
        Count = @($rows).Count
        Events = @($rows | Sort-Object TimeCreated -Descending)
        TopDevices = @($byDevice)
        TopDrivers = @($byDriver)
    }
}

function Get-DriverInventoryFromPnpUtil {
    [CmdletBinding()]
    param()

    $p = Get-Command pnputil.exe -ErrorAction SilentlyContinue
    if (-not $p) {
        return [pscustomobject]@{
            Available = $false
            Message = 'pnputil.exe not found'
            Drivers = @()
        }
    }

    $raw = & $p.Source /enum-drivers 2>$null
    $lines = @($raw)
    if (-not $lines -or $lines.Count -lt 5) {
        return [pscustomobject]@{
            Available = $true
            Message = 'No output or insufficient output from pnputil /enum-drivers'
            Drivers = @()
        }
    }

    # pnputil output is grouped; parse key/value lines.
    $drivers = [System.Collections.Generic.List[object]]::new()
    $current = [ordered]@{}

    function Flush-Current {
        param([hashtable]$h)
        if ($h.Count -eq 0) { return }
        $drivers.Add([pscustomobject]@{
            PublishedName = $h.PublishedName
            OriginalName = $h.OriginalName
            ProviderName = $h.ProviderName
            ClassName = $h.ClassName
            ClassGuid = $h.ClassGuid
            DriverVersion = $h.DriverVersion
            DriverDate = $h.DriverDate
            SignerName = $h.SignerName
        }) | Out-Null
        $h.Clear()
    }

    foreach ($line in $lines) {
        if (-not $line -or $line.Trim().Length -eq 0) {
            Flush-Current -h $current
            continue
        }

        if ($line -match '^\s*Published Name\s*:\s*(.+)$') { $current.PublishedName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Original Name\s*:\s*(.+)$') { $current.OriginalName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Provider Name\s*:\s*(.+)$') { $current.ProviderName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Class Name\s*:\s*(.+)$') { $current.ClassName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Class GUID\s*:\s*(.+)$') { $current.ClassGuid = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Signer Name\s*:\s*(.+)$') { $current.SignerName = $Matches[1].Trim(); continue }

        if ($line -match '^\s*Driver Version\s*:\s*(.+)$') {
            # Typically: "06/21/2006 10.0.26100.1"
            $v = $Matches[1].Trim()
            $parts = $v -split '\s+'
            if ($parts.Count -ge 2) {
                $current.DriverDate = $parts[0]
                $current.DriverVersion = $parts[-1]
            }
            else {
                $current.DriverVersion = $v
            }
            continue
        }
    }
    Flush-Current -h $current

    return [pscustomobject]@{
        Available = $true
        Message = 'OK'
        Drivers = @($drivers)
    }
}

function Get-SetupApiTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$TailLines
    )

    $path = Join-Path $env:windir 'INF\setupapi.dev.log'
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{
            Available = $false
            Path = $path
            Tail = @()
        }
    }

    $tail = Get-Content -Path $path -Tail $TailLines -ErrorAction SilentlyContinue
    $errorLines = @($tail | Where-Object { $_ -match '!!!|failed|error' })

    [pscustomobject]@{
        Available = $true
        Path = $path
        TailLines = $TailLines
        ErrorLineCount = $errorLines.Count
        Tail = @($tail)
    }
}

function Write-SummaryEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogName,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Information',

        [Parameter()]
        [int]$EventId = 1001
    )

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            if (Test-IsAdmin) {
                New-EventLog -LogName $LogName -Source $Source -ErrorAction Stop
            }
            else {
                # Can't create source without admin.
                return [pscustomobject]@{ Written = $false; Message = 'Event source missing and not elevated' }
            }
        }

        Write-EventLog -LogName $LogName -Source $Source -EventId $EventId -EntryType $EntryType -Message $Message -ErrorAction Stop
        return [pscustomobject]@{ Written = $true; Message = 'OK' }
    }
    catch {
        return [pscustomobject]@{ Written = $false; Message = $_.Exception.Message }
    }
}

$since = (Get-Date).AddDays(-$LookbackDays)

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

$pending = Get-PendingRebootState
$oem = Get-OemToolingState
$problems = Get-ProblemDevices
$kpnp = Get-KernelPnpProblemStartingEvents -Since $since

$driverInventory = $null
if ($IncludeDriverInventory) {
    $driverInventory = Get-DriverInventoryFromPnpUtil
}

$setupApi = $null
if ($IncludeSetupApiTail) {
    $setupApi = Get-SetupApiTail -TailLines $SetupApiTailLines
}

$summary = [pscustomobject]@{
    GeneratedAt = (Get-Date)
    LookbackDays = $LookbackDays
    Computer = [pscustomobject]@{
        Name = $env:COMPUTERNAME
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
    }
    OS = [pscustomobject]@{
        Caption = $os.Caption
        Version = $os.Version
        BuildNumber = $os.BuildNumber
    }
    BIOS = [pscustomobject]@{
        SMBIOSBIOSVersion = $bios.SMBIOSBIOSVersion
        ReleaseDate = $bios.ReleaseDate
    }
    PendingReboot = $pending
    OemTooling = $oem
    Pnp = $problems
    KernelPnp = $kpnp
    DriverInventory = $driverInventory
    SetupApi = $setupApi
    Health = [pscustomobject]@{
        NonOkDeviceCount = $problems.NonOkCount
        KernelPnpProblemStartingEventCount = $kpnp.Count
        IsRebootPending = $pending.IsRebootPending
        HasIssues = [bool](($problems.NonOkCount -gt 0) -or ($kpnp.Count -gt 0))
    }
}

if ($WriteEventLog) {
    $entryType = if ($summary.Health.HasIssues) { 'Warning' } else { 'Information' }
    $msg = @()
    $msg += "PSDriverManagement status prototype summary"
    $msg += "Computer: $($summary.Computer.Name) ($($summary.Computer.Manufacturer) $($summary.Computer.Model))"
    $msg += "OS: $($summary.OS.Caption) $($summary.OS.Version) (Build $($summary.OS.BuildNumber))"
    $msg += "LookbackDays: $LookbackDays"
    $msg += "Non-OK devices: $($summary.Health.NonOkDeviceCount)"
    $msg += "Kernel-PnP 411 errors: $($summary.Health.KernelPnpProblemStartingEventCount)"
    $msg += "Reboot pending (heuristic): $($summary.Health.IsRebootPending)"
    if ($summary.OemTooling.DellCommandUpdate.Present) { $msg += "DCU: Present (v$($summary.OemTooling.DellCommandUpdate.Version))" }
    if ($summary.OemTooling.Lenovo.SystemUpdatePresent -or $summary.OemTooling.Lenovo.ThinInstallerPresent -or $summary.OemTooling.Lenovo.LSUClientModulePresent) {
        $msg += "Lenovo tools present: SystemUpdate=$($summary.OemTooling.Lenovo.SystemUpdatePresent) ThinInstaller=$($summary.OemTooling.Lenovo.ThinInstallerPresent) LSUClientModule=$($summary.OemTooling.Lenovo.LSUClientModulePresent)"
    }
    $msg += ""
    $msg += "Top Kernel-PnP 411 drivers:"
    foreach ($d in ($summary.KernelPnp.TopDrivers | Select-Object -First 5)) {
        $msg += " - $($d.DriverName): $($d.Count)"
    }

    $evResult = Write-SummaryEvent -LogName $EventLogName -Source $EventSource -Message ($msg -join "`r`n") -EntryType $entryType -EventId 1101
    $summary | Add-Member -NotePropertyName EventLogWrite -NotePropertyValue $evResult
}

$summary


