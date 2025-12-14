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

function Initialize-TlsForDownloads {
    <#
    .SYNOPSIS
        Ensures modern TLS protocols are enabled for outbound HTTPS requests.
    .DESCRIPTION
        Some endpoints (including Intel download hosts) reject older TLS defaults,
        which can cause: "The underlying connection was closed: An unexpected error occurred on a send."
        This function enables TLS 1.2 in the current PowerShell process.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $current = [System.Net.ServicePointManager]::SecurityProtocol
        # Always include TLS 1.2 if available
        if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls12') {
            $current = $current -bor [System.Net.SecurityProtocolType]::Tls12
        }
        # Best-effort: keep TLS 1.1 if present (some older middleboxes)
        if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls11') {
            $current = $current -bor [System.Net.SecurityProtocolType]::Tls11
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $current
        
        # Reduce edge-case HTTP behavior problems
        [System.Net.ServicePointManager]::Expect100Continue = $false
    }
    catch {
        # Non-fatal; continue without TLS tuning
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
    
    # Ensure TLS is modern enough for common download hosts
    Initialize-TlsForDownloads
    
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
            Initialize-TlsForDownloads
            Invoke-WebRequest -Uri $SourceUrl -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        } -MaxAttempts 3 -ExponentialBackoff
        
        return @{ Success = $true; Path = $DestinationPath; UsedFallback = $true }
    }
}

function Test-WinGetAvailableInternal {
    [CmdletBinding()]
    param()
    
    try {
        return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

function Install-WinGetInternal {
    <#
    .SYNOPSIS
        Best-effort WinGet installation (App Installer MSIXBundle).
    .DESCRIPTION
        Downloads the App Installer MSIXBundle from the official aka.ms redirect and installs it via Add-AppxPackage.
        This may fail on some images (Server/LTSC/Store-disabled) and will log and return $false in that case.
    .OUTPUTS
        [bool] success
    #>
    [CmdletBinding()]
    param()
    
    # If already present, nothing to do
    if (Test-WinGetAvailableInternal) { return $true }
    
    $bundleUrl = 'https://aka.ms/getwinget'
    $bundlePath = Join-Path $env:TEMP "Microsoft.DesktopAppInstaller_$(Get-Date -Format 'yyyyMMddHHmmss').msixbundle"
    
    try {
        Write-DriverLog -Message "WinGet not found. Downloading App Installer from aka.ms/getwinget" -Severity Warning
        
        Start-DownloadWithVerification -SourceUrl $bundleUrl -DestinationPath $bundlePath | Out-Null
        if (-not (Test-Path $bundlePath)) {
            throw "Download failed - MSIXBundle not found"
        }
        
        Write-DriverLog -Message "Installing App Installer (WinGet) via Add-AppxPackage" -Severity Info
        Add-AppxPackage -Path $bundlePath -ErrorAction Stop | Out-Null
        
        Start-Sleep -Seconds 2
        if (-not (Test-WinGetAvailableInternal)) {
            throw "WinGet still not available after Add-AppxPackage"
        }
        
        Write-DriverLog -Message "WinGet installed successfully" -Severity Info
        return $true
    }
    catch {
        Write-DriverLog -Message "Failed to auto-install WinGet: $($_.Exception.Message)" -Severity Warning
        return $false
    }
    finally {
        Remove-Item -Path $bundlePath -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-WinGetInternal {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$AutoInstall
    )
    
    if (Test-WinGetAvailableInternal) { return $true }
    if (-not $AutoInstall) { return $false }
    return (Install-WinGetInternal)
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
