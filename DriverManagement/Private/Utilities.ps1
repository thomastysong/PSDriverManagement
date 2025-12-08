#Requires -Version 5.1

<#
.SYNOPSIS
    Utility functions for DriverManagement module
#>

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with retry logic
    .DESCRIPTION
        Implements exponential backoff retry pattern
    .PARAMETER ScriptBlock
        The code to execute
    .PARAMETER MaxAttempts
        Maximum number of attempts
    .PARAMETER InitialDelayMs
        Initial delay between retries in milliseconds
    .PARAMETER ExponentialBackoff
        Use exponential backoff for delays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [int]$MaxAttempts = 5,
        
        [Parameter()]
        [int]$InitialDelayMs = 2000,
        
        [Parameter()]
        [switch]$ExponentialBackoff
    )
    
    $attempt = 0
    $lastError = $null
    
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $ErrorActionPreference = 'Stop'
            return Invoke-Command -ScriptBlock $ScriptBlock
        }
        catch {
            $lastError = $_
            
            if ($attempt -ge $MaxAttempts) {
                Write-DriverLog -Message "Operation failed after $MaxAttempts attempts: $($_.Exception.Message)" -Severity Error
                throw
            }
            
            $delay = if ($ExponentialBackoff) {
                [Math]::Min($InitialDelayMs * [Math]::Pow(2, $attempt - 1), 60000)
            } else { $InitialDelayMs }
            
            $jitter = Get-Random -Minimum 0 -Maximum 1000
            $totalDelay = $delay + $jitter
            
            Write-DriverLog -Message "Attempt $attempt failed. Retrying in $($totalDelay)ms..." -Severity Warning `
                -Context @{ Error = $_.Exception.Message; Attempt = $attempt }
            
            Start-Sleep -Milliseconds $totalDelay
        }
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Checks if a system reboot is pending
    .DESCRIPTION
        Checks multiple registry locations for pending reboot flags
    .EXAMPLE
        if (Test-PendingReboot) { Write-Host "Reboot required" }
    #>
    [CmdletBinding()]
    param()
    
    $rebootPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    
    foreach ($path in $rebootPaths) {
        if (Test-Path $path) { return $true }
    }
    
    # Check PendingFileRenameOperations
    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pendingRenames = (Get-ItemProperty -Path $sessionManager -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pendingRenames) { return $true }
    
    return $false
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Checks if current process is running elevated
    #>
    [CmdletBinding()]
    param()
    
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-DownloadWithVerification {
    <#
    .SYNOPSIS
        Downloads a file with BITS and optional hash verification
    .PARAMETER SourceUrl
        URL to download from
    .PARAMETER DestinationPath
        Local path to save file
    .PARAMETER ExpectedHash
        Optional SHA256 hash to verify
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceUrl,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [Parameter()]
        [string]$ExpectedHash,
        
        [Parameter()]
        [ValidateSet('SHA256', 'SHA1', 'MD5')]
        [string]$HashAlgorithm = 'SHA256'
    )
    
    $jobName = "DriverDownload-$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    try {
        # Use BITS for resilient download
        $job = Start-BitsTransfer -Source $SourceUrl -Destination $DestinationPath -Asynchronous `
            -Priority Normal -RetryInterval 600 -RetryTimeout 86400 -DisplayName $jobName -ErrorAction Stop
        
        # Monitor transfer
        while ($job.JobState -in @('Transferring', 'Connecting')) {
            if ($job.BytesTotal -gt 0) {
                $pct = [int](($job.BytesTransferred / $job.BytesTotal) * 100)
                Write-Progress -Activity "Downloading" -Status "$pct% Complete" -PercentComplete $pct
            }
            Start-Sleep -Seconds 2
            $job = Get-BitsTransfer -JobId $job.JobId
        }
        
        Write-Progress -Activity "Downloading" -Completed
        
        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job
            
            # Verify hash if provided
            if ($ExpectedHash) {
                $actualHash = (Get-FileHash -Path $DestinationPath -Algorithm $HashAlgorithm).Hash
                if ($actualHash -ne $ExpectedHash) {
                    Remove-Item $DestinationPath -Force
                    throw "Hash verification failed. Expected: $ExpectedHash, Got: $actualHash"
                }
            }
            
            return @{ Success = $true; Path = $DestinationPath }
        }
        else {
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            throw "BITS transfer failed with state: $($job.JobState)"
        }
    }
    catch {
        # Fallback to direct download
        Write-DriverLog -Message "BITS failed, falling back to Invoke-WebRequest" -Severity Warning
        
        Invoke-WithRetry -ScriptBlock {
            Invoke-WebRequest -Uri $SourceUrl -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        } -MaxAttempts 3 -ExponentialBackoff
        
        return @{ Success = $true; Path = $DestinationPath; UsedFallback = $true }
    }
}

function Get-InstalledDrivers {
    <#
    .SYNOPSIS
        Gets installed third-party drivers
    .PARAMETER DeviceClasses
        Filter by device classes
    .PARAMETER ThirdPartyOnly
        Exclude Microsoft drivers
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$DeviceClasses = @('Display', 'Net', 'MEDIA', 'USB', 'SYSTEM'),
        
        [Parameter()]
        [switch]$ThirdPartyOnly
    )
    
    $filter = if ($DeviceClasses) {
        $classFilter = ($DeviceClasses | ForEach-Object { "DeviceClass='$_'" }) -join ' OR '
        "($classFilter)"
    } else { $null }
    
    $drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter $filter -ErrorAction SilentlyContinue |
        Where-Object { $_.DriverVersion } |
        Select-Object @{N='DeviceName';E={$_.DeviceName}},
                      @{N='HardwareID';E={$_.HardWareID}},
                      @{N='DriverVersion';E={$_.DriverVersion}},
                      @{N='DriverDate';E={$_.DriverDate}},
                      @{N='Provider';E={$_.DriverProviderName}},
                      @{N='DeviceClass';E={$_.DeviceClass}},
                      @{N='InfName';E={$_.InfName}}
    
    if ($ThirdPartyOnly) {
        $drivers = $drivers | Where-Object { $_.Provider -ne 'Microsoft' }
    }
    
    return $drivers
}

function Assert-Elevation {
    <#
    .SYNOPSIS
        Throws if not running elevated
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Operation = "This operation"
    )
    
    if (-not (Test-IsElevated)) {
        throw "$Operation requires elevation. Please run as Administrator."
    }
}
