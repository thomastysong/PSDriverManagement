<#
.SYNOPSIS
    PSDriverManagement Module Installer
    
.DESCRIPTION
    Bootstrap installer for PSDriverManagement PowerShell modules. Designed to run
    during pre-provisioning before Intune enrollment completes. Can be called by
    any orchestration platform: Intune, FleetDM, Chef, Ansible, SCCM, etc.
    
    This installer:
    - Downloads modules from a configured source (GitHub, Azure Blob, internal repo)
    - Installs to the system-wide PowerShell modules path
    - Registers modules for auto-import
    - Supports offline installation from local packages
    - Provides comprehensive logging
    
.PARAMETER ModuleNames
    Names of modules to install. Use '*' for all available modules.
    
.PARAMETER Source
    Source URL or path for modules:
    - GitHub releases URL
    - Azure Blob Storage URL
    - Network share path
    - Local directory path
    
.PARAMETER Version
    Specific version to install, or 'latest' for most recent
    
.PARAMETER Offline
    Install from local package without network access
    
.PARAMETER PackagePath
    Path to local module package when using -Offline
    
.PARAMETER Force
    Reinstall even if already present
    
.EXAMPLE
    # Install specific module from default source
    .\Install-PSDriverManagement.ps1 -ModuleNames DriverManagement
    
.EXAMPLE
    # Install all modules during pre-provisioning
    .\Install-PSDriverManagement.ps1 -ModuleNames * -Source "https://github.com/thomastysong/PSDriverManagement/releases/latest/download"
    
.EXAMPLE
    # Offline installation from local package
    .\Install-PSDriverManagement.ps1 -ModuleNames DriverManagement -Offline -PackagePath "C:\Packages\DriverManagement.zip"
    
.EXAMPLE
    # FleetDM/Chef invocation
    powershell.exe -ExecutionPolicy Bypass -File Install-PSDriverManagement.ps1 -ModuleNames DriverManagement
    
.NOTES
    Author: Thomas Tyson
    Version: 1.0.0
    
    Exit Codes:
        0    - Success
        1    - General failure
        2    - Prerequisites not met
        3    - Download failure
        4    - Installation failure
        3010 - Success, reboot required
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ModuleNames,
    
    [Parameter()]
    [string]$Source = $env:PSDM_MODULE_SOURCE ?? 'https://github.com/thomastysong/PSDriverManagement/releases/latest/download',
    
    [Parameter()]
    [string]$Version = 'latest',
    
    [Parameter()]
    [switch]$Offline,
    
    [Parameter()]
    [string]$PackagePath,
    
    [Parameter()]
    [switch]$Force,
    
    [Parameter()]
    [string]$LogPath = "$env:ProgramData\PSDriverManagement\ModuleInstaller\Logs"
)

#region Configuration

$script:Config = @{
    # Installation paths
    SystemModulePath = "$env:ProgramFiles\WindowsPowerShell\Modules"
    UserModulePath   = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
    InstallPath      = "$env:ProgramFiles\WindowsPowerShell\Modules"  # Default to system-wide
    
    # Logging
    LogPath          = $LogPath
    EventLogName     = 'PSDriverManagement'
    EventLogSource   = 'ModuleInstaller'
    
    # Available modules manifest
    AvailableModules = @{
        'DriverManagement' = @{
            Description = 'Enterprise driver and Windows update management'
            MinVersion  = '1.0.0'
            Dependencies = @()
            RequiresElevation = $true
        }
        'ComplianceCheck' = @{
            Description = 'Endpoint compliance validation'
            MinVersion  = '1.0.0'
            Dependencies = @()
            RequiresElevation = $false
        }
        'SecurityBaseline' = @{
            Description = 'Security configuration management'
            MinVersion  = '1.0.0'
            Dependencies = @('ComplianceCheck')
            RequiresElevation = $true
        }
        'AssetInventory' = @{
            Description = 'Hardware and software inventory collection'
            MinVersion  = '1.0.0'
            Dependencies = @()
            RequiresElevation = $false
        }
        'NetworkDiagnostics' = @{
            Description = 'Network troubleshooting and validation'
            MinVersion  = '1.0.0'
            Dependencies = @()
            RequiresElevation = $true
        }
    }
    
    # Installer metadata
    InstallerVersion = '1.0.0'
    CorrelationId    = [guid]::NewGuid().ToString()
}

#endregion

#region Logging

function Initialize-InstallerLogging {
    # Ensure log directory exists
    if (-not (Test-Path $script:Config.LogPath)) {
        New-Item -Path $script:Config.LogPath -ItemType Directory -Force | Out-Null
    }
    
    # Create event log source if needed
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:Config.EventLogSource)) {
            New-EventLog -LogName $script:Config.EventLogName -Source $script:Config.EventLogSource -ErrorAction Stop
        }
    }
    catch {
        Write-Verbose "Could not create event log source: $_"
    }
}

function Write-InstallerLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Severity = 'Info',
        
        [hashtable]$Context = @{}
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
    
    $logEntry = @{
        Timestamp = $timestamp
        Severity = $Severity
        Message = $Message
        CorrelationId = $script:Config.CorrelationId
        Computer = $env:COMPUTERNAME
        Context = $Context
    }
    
    # Console output
    $color = switch ($Severity) {
        'Info' { 'White' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
    }
    Write-Host "[$timestamp] [$Severity] $Message" -ForegroundColor $color
    
    # File output
    $logFile = Join-Path $script:Config.LogPath "ModuleInstaller_$(Get-Date -Format 'yyyyMMdd').json"
    $logEntry | ConvertTo-Json -Compress | Add-Content -Path $logFile -Encoding UTF8
    
    # Event log output
    try {
        $eventId = switch ($Severity) { 'Info' { 1000 }; 'Warning' { 2000 }; 'Error' { 3000 } }
        $entryType = switch ($Severity) { 'Info' { 'Information' }; 'Warning' { 'Warning' }; 'Error' { 'Error' } }
        
        if ([System.Diagnostics.EventLog]::SourceExists($script:Config.EventLogSource)) {
            Write-EventLog -LogName $script:Config.EventLogName -Source $script:Config.EventLogSource `
                -EventId $eventId -EntryType $entryType -Message "$Message`n`nContext: $($Context | ConvertTo-Json -Compress)"
        }
    }
    catch { }
}

#endregion

#region Module Installation

function Get-ModulePackage {
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName,
        
        [string]$Version = 'latest'
    )
    
    if ($Offline) {
        if (-not $PackagePath -or -not (Test-Path $PackagePath)) {
            throw "Offline mode requires valid -PackagePath"
        }
        return $PackagePath
    }
    
    $downloadDir = "$env:TEMP\PSDriverManagement\$($script:Config.CorrelationId)"
    New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
    
    # Construct download URL
    $versionPath = if ($Version -eq 'latest') { 'latest' } else { "v$Version" }
    $downloadUrl = "$Source/$ModuleName/$versionPath/$ModuleName.zip"
    
    $localPath = Join-Path $downloadDir "$ModuleName.zip"
    
    Write-InstallerLog -Message "Downloading $ModuleName from $downloadUrl" -Context @{ URL = $downloadUrl }
    
    try {
        # Try BITS first for reliability
        $bitsJob = Start-BitsTransfer -Source $downloadUrl -Destination $localPath -Asynchronous -ErrorAction Stop
        
        $timeout = [datetime]::Now.AddMinutes(10)
        while ($bitsJob.JobState -in @('Transferring', 'Connecting') -and [datetime]::Now -lt $timeout) {
            Start-Sleep -Seconds 2
        }
        
        if ($bitsJob.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $bitsJob
        }
        else {
            Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
            throw "BITS transfer failed: $($bitsJob.JobState)"
        }
    }
    catch {
        # Fallback to Invoke-WebRequest
        Write-InstallerLog -Message "BITS failed, using web request fallback" -Severity Warning
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
    }
    
    if (-not (Test-Path $localPath)) {
        throw "Download failed - file not found at $localPath"
    }
    
    return $localPath
}

function Install-ModulePackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,
        
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    
    $installPath = $script:Config.InstallPath
    $modulePath = Join-Path $installPath $ModuleName
    
    # Remove existing if Force
    if ((Test-Path $modulePath) -and $Force) {
        Write-InstallerLog -Message "Removing existing module: $modulePath" -Context @{ Path = $modulePath }
        Remove-Item -Path $modulePath -Recurse -Force
    }
    elseif (Test-Path $modulePath) {
        Write-InstallerLog -Message "Module already installed: $ModuleName" -Context @{ Path = $modulePath }
        return @{ Success = $true; AlreadyInstalled = $true; Path = $modulePath }
    }
    
    # Extract package
    Write-InstallerLog -Message "Installing $ModuleName to $modulePath" -Context @{ Source = $PackagePath; Destination = $modulePath }
    
    $extractPath = "$env:TEMP\PSDriverManagement\Extract\$ModuleName"
    if (Test-Path $extractPath) { Remove-Item -Path $extractPath -Recurse -Force }
    
    Expand-Archive -Path $PackagePath -DestinationPath $extractPath -Force
    
    # Find the module folder (may be nested)
    $manifestFile = Get-ChildItem -Path $extractPath -Filter "$ModuleName.psd1" -Recurse | Select-Object -First 1
    if (-not $manifestFile) {
        throw "Module manifest not found in package"
    }
    
    $sourceModulePath = $manifestFile.DirectoryName
    
    # Copy to install location
    Copy-Item -Path $sourceModulePath -Destination $modulePath -Recurse -Force
    
    # Verify installation
    $installed = Get-Module -ListAvailable -Name $ModuleName | Select-Object -First 1
    if (-not $installed) {
        throw "Module installation verification failed"
    }
    
    Write-InstallerLog -Message "Successfully installed $ModuleName v$($installed.Version)" `
        -Context @{ Version = $installed.Version.ToString(); Path = $modulePath }
    
    return @{ Success = $true; Version = $installed.Version; Path = $modulePath }
}

function Install-ModuleDependencies {
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    
    $moduleInfo = $script:Config.AvailableModules[$ModuleName]
    if (-not $moduleInfo -or -not $moduleInfo.Dependencies) {
        return @()
    }
    
    $installed = @()
    
    foreach ($dep in $moduleInfo.Dependencies) {
        Write-InstallerLog -Message "Installing dependency: $dep for $ModuleName"
        
        $result = Install-SingleModule -ModuleName $dep
        $installed += $result
    }
    
    return $installed
}

function Install-SingleModule {
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    
    Write-InstallerLog -Message "=== Installing module: $ModuleName ===" -Context @{ Module = $ModuleName }
    
    try {
        # Install dependencies first
        Install-ModuleDependencies -ModuleName $ModuleName
        
        # Get package
        $package = Get-ModulePackage -ModuleName $ModuleName -Version $Version
        
        # Install
        $result = Install-ModulePackage -PackagePath $package -ModuleName $ModuleName
        
        return @{
            ModuleName = $ModuleName
            Success = $result.Success
            Version = $result.Version
            Path = $result.Path
            AlreadyInstalled = $result.AlreadyInstalled
        }
    }
    catch {
        Write-InstallerLog -Message "Failed to install $ModuleName : $($_.Exception.Message)" -Severity Error
        return @{
            ModuleName = $ModuleName
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#endregion

#region Main Execution

function Invoke-ModuleInstallation {
    Write-InstallerLog -Message "=== PSDriverManagement Module Installer v$($script:Config.InstallerVersion) ===" `
        -Context @{ 
            Modules = $ModuleNames
            Source = $Source
            Version = $Version
            Offline = $Offline.IsPresent
        }
    
    # Expand '*' to all available modules
    $modulesToInstall = if ($ModuleNames -contains '*') {
        $script:Config.AvailableModules.Keys
    }
    else {
        $ModuleNames
    }
    
    # Validate requested modules
    foreach ($module in $modulesToInstall) {
        if (-not $script:Config.AvailableModules.ContainsKey($module)) {
            Write-InstallerLog -Message "Unknown module: $module" -Severity Warning
        }
    }
    
    $results = @()
    
    foreach ($module in $modulesToInstall) {
        if ($script:Config.AvailableModules.ContainsKey($module)) {
            $result = Install-SingleModule -ModuleName $module
            $results += $result
        }
    }
    
    # Summary
    $successCount = ($results | Where-Object { $_.Success }).Count
    $failCount = ($results | Where-Object { -not $_.Success }).Count
    
    Write-InstallerLog -Message "=== Installation Complete: $successCount succeeded, $failCount failed ===" `
        -Context @{ Results = $results }
    
    # Generate manifest for orchestrators
    $manifest = @{
        InstallerVersion = $script:Config.InstallerVersion
        CorrelationId = $script:Config.CorrelationId
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Computer = $env:COMPUTERNAME
        Results = $results
        Success = $failCount -eq 0
    }
    
    $manifestPath = "$env:ProgramData\PSDriverManagement\ModuleInstaller\install-manifest.json"
    $manifestDir = Split-Path $manifestPath -Parent
    if (-not (Test-Path $manifestDir)) {
        New-Item -Path $manifestDir -ItemType Directory -Force | Out-Null
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
    
    return $manifest
}

# Main entry point
try {
    Initialize-InstallerLogging
    $result = Invoke-ModuleInstallation
    
    if ($result.Success) {
        exit 0
    }
    else {
        exit 4
    }
}
catch {
    Write-InstallerLog -Message "Fatal error: $($_.Exception.Message)" -Severity Error `
        -Context @{ StackTrace = $_.ScriptStackTrace }
    exit 1
}

#endregion
