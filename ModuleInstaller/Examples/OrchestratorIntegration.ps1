<#
.SYNOPSIS
    Example orchestrator integration patterns for PSDriverManagement PowerShell modules
    
.DESCRIPTION
    This file demonstrates how different orchestration platforms can invoke
    the PSDriverManagement module installer and use installed modules.
#>

#region Intune Win32 App - Install Command
<#
    Install Command (for .intunewin package):
    
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { 
        $ErrorActionPreference = 'Stop'
        Set-Location $PSScriptRoot
        .\Install-PSDriverManagement.ps1 -ModuleNames DriverManagement -Force
        Import-Module DriverManagement -Force
        Invoke-DriverManagement -Mode Individual -NoReboot
    }"
    
    Uninstall Command:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item '$env:ProgramFiles\WindowsPowerShell\Modules\DriverManagement' -Recurse -Force"
    
    Detection Script:
    $module = Get-Module -ListAvailable -Name DriverManagement
    if ($module -and $module.Version -ge '1.0.0') { 
        Write-Host "Found DriverManagement v$($module.Version)"
        exit 0 
    }
    exit 1
#>
#endregion

#region FleetDM osquery Extension
<#
    FleetDM can execute PowerShell via osquery's powershell_events table.
    Create a policy that runs the module check:
    
    Policy Query:
    SELECT * FROM powershell_events 
    WHERE script LIKE '%Invoke-DriverManagement%' 
    AND time > (strftime('%s','now') - 86400);
    
    Fleet script to deploy:
#>

$FleetDMScript = @'
# FleetDM Deployment Script
$ErrorActionPreference = 'Stop'

# Check if module is installed
$module = Get-Module -ListAvailable -Name DriverManagement
if (-not $module) {
    # Download and install
    $installerUrl = $env:PSDM_MODULE_SOURCE + '/Install-PSDriverManagement.ps1'
    $installerPath = "$env:TEMP\Install-PSDriverManagement.ps1"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    & $installerPath -ModuleNames DriverManagement
}

# Import and execute
Import-Module DriverManagement -Force
$result = Invoke-DriverManagement -Mode Individual -NoReboot

# Output for FleetDM collection
@{
    success = $result.Success
    updates_applied = $result.UpdatesApplied
    reboot_required = $result.RebootRequired
    message = $result.Message
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json
'@
#endregion

#region Chef Recipe
<#
    Chef recipe for PSDriverManagement module deployment:
    
    # psdrivermanagement/recipes/driver_management.rb
    
    powershell_script 'install_driver_management_module' do
      code <<-EOH
        $ErrorActionPreference = 'Stop'
        
        # Check if already installed
        $module = Get-Module -ListAvailable -Name DriverManagement
        if ($module -and $module.Version -ge '1.0.0') {
            Write-Host "DriverManagement already installed"
            exit 0
        }
        
        # Download installer
        $installerPath = "C:\\chef\\cache\\Install-PSDriverManagement.ps1"
        Invoke-WebRequest -Uri "#{node['psdm']['source']}/Install-PSDriverManagement.ps1" `
            -OutFile $installerPath -UseBasicParsing
        
        # Install module
        & $installerPath -ModuleNames DriverManagement -Force
      EOH
      only_if { node['psdm']['driver_management']['enabled'] }
    end
    
    powershell_script 'run_driver_management' do
      code <<-EOH
        Import-Module DriverManagement -Force
        $result = Invoke-DriverManagement -Mode Individual -NoReboot
        
        if (-not $result.Success) {
            throw "Driver management failed: $($result.Message)"
        }
      EOH
      action :run
      only_if { node['psdm']['driver_management']['auto_run'] }
    end
#>
#endregion

#region Ansible Playbook
<#
    Ansible playbook for PSDriverManagement module deployment:
    
    # psdrivermanagement.yml
    ---
    - name: Deploy PSDriverManagement PowerShell Modules
      hosts: windows
      vars:
        psdm_source: "https://github.com/thomastysong/PSDriverManagement/releases/latest/download"
        modules_to_install:
          - DriverManagement
          - ComplianceCheck
      
      tasks:
        - name: Download module installer
          win_get_url:
            url: "{{ psdm_source }}/Install-PSDriverManagement.ps1"
            dest: C:\Temp\Install-PSDriverManagement.ps1
        
        - name: Install PSDriverManagement modules
          win_shell: |
            $ErrorActionPreference = 'Stop'
            C:\Temp\Install-PSDriverManagement.ps1 -ModuleNames {{ modules_to_install | join(',') }} -Force
          args:
            creates: C:\Program Files\WindowsPowerShell\Modules\DriverManagement\DriverManagement.psd1
        
        - name: Run driver management
          win_shell: |
            Import-Module DriverManagement -Force
            $result = Invoke-DriverManagement -Mode Individual -NoReboot
            $result | ConvertTo-Json
          register: driver_result
          when: run_driver_management | default(true)
        
        - name: Display results
          debug:
            var: driver_result.stdout_lines
#>
#endregion

#region SCCM/MECM Task Sequence
<#
    SCCM Task Sequence PowerShell Step:
    
    Step Name: Install PSDriverManagement Modules
    Type: Run PowerShell Script
    Script: (embedded)
#>

$SCCMScript = @'
# SCCM Task Sequence - Install PSDriverManagement Modules
param(
    [string]$ModuleSource = 'https://github.com/thomastysong/PSDriverManagement/releases/latest/download',
    [string[]]$Modules = @('DriverManagement')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Create TSEnvironment COM object for variable access
try {
    $tsenv = New-Object -ComObject Microsoft.SMS.TSEnvironment
    $logPath = $tsenv.Value("_SMSTSLogPath")
}
catch {
    $logPath = "$env:TEMP\Logs"
}

# Log function
function Write-TSLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath "$logPath\PSDriverManagement.log" -Append
    Write-Host $Message
}

Write-TSLog "Starting PSDriverManagement module installation"
Write-TSLog "Source: $ModuleSource"
Write-TSLog "Modules: $($Modules -join ', ')"

# Download installer
$installerPath = "$env:TEMP\Install-PSDriverManagement.ps1"
Write-TSLog "Downloading installer to $installerPath"
Invoke-WebRequest -Uri "$ModuleSource/Install-PSDriverManagement.ps1" -OutFile $installerPath -UseBasicParsing

# Install modules
Write-TSLog "Installing modules..."
& $installerPath -ModuleNames $Modules -Source $ModuleSource -Force

# Verify installation
foreach ($module in $Modules) {
    $installed = Get-Module -ListAvailable -Name $module
    if ($installed) {
        Write-TSLog "SUCCESS: $module v$($installed.Version) installed"
    }
    else {
        Write-TSLog "ERROR: $module installation failed"
        exit 1
    }
}

Write-TSLog "PSDriverManagement module installation complete"
exit 0
'@
#endregion

#region Pre-Provisioning (Autopilot ESP)
<#
    For Autopilot Enrollment Status Page, deploy as a Win32 app with:
    - Install during Device Setup phase
    - Required assignment to All Devices
    - Detection: Registry key or compliance.json file
#>

$AutopilotPreProvScript = @'

# Autopilot Pre-Provisioning Script
# Runs before user enrollment completes

$ErrorActionPreference = 'Stop'

# Check if in provisioning mode
$autopilotDiag = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotSettings" -ErrorAction SilentlyContinue
$isProvisioning = $null -ne $autopilotDiag

Write-Host "Running in Autopilot mode: $isProvisioning"

# Install core modules
$modules = @('DriverManagement', 'ComplianceCheck', 'SecurityBaseline')

foreach ($module in $modules) {
    Write-Host "Installing module: $module"
    
    # Check if already present
    if (Get-Module -ListAvailable -Name $module) {
        Write-Host "  Already installed, skipping"
        continue
    }
    
    # Download and install
    $installerUrl = "https://github.com/thomastysong/PSDriverManagement/releases/latest/download/Install-PSDriverManagement.ps1"
    $installerPath = "$env:TEMP\Install-PSDriverManagement.ps1"
    
    if (-not (Test-Path $installerPath)) {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    }
    
    & $installerPath -ModuleNames $module -Force
}

# Run driver management if applicable
$oem = (Get-CimInstance Win32_ComputerSystem).Manufacturer
if ($oem -match 'Dell|Lenovo') {
    Write-Host "Running initial driver management for $oem system..."
    Import-Module DriverManagement -Force
    $result = Invoke-DriverManagement -Mode Individual -NoReboot
    Write-Host "Result: $($result.Message)"
}

# Mark provisioning complete
$registryPath = "HKLM:\SOFTWARE\PSDriverManagement\Provisioning"
if (-not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}
Set-ItemProperty -Path $registryPath -Name "ModulesInstalled" -Value (Get-Date).ToString('o')
Set-ItemProperty -Path $registryPath -Name "ModuleList" -Value ($modules -join ',')

Write-Host "Pre-provisioning complete"
exit 0
'@
#endregion

#region Direct PowerShell Invocation
<#
    Simple direct invocation patterns for any orchestrator:
#>

# Pattern 1: One-liner for quick deployment
$OneLiner = 'irm https://github.com/thomastysong/PSDriverManagement/releases/latest/download/Install-PSDriverManagement.ps1 | iex; Install-PSDriverManagement -ModuleNames DriverManagement'

# Pattern 2: With error handling
$RobustInvocation = @'
try {
    $installer = Invoke-WebRequest -Uri 'https://github.com/thomastysong/PSDriverManagement/releases/latest/download/Install-PSDriverManagement.ps1' -UseBasicParsing
    $installerPath = "$env:TEMP\Install-PSDriverManagement.ps1"
    $installer.Content | Set-Content -Path $installerPath -Encoding UTF8
    
    $result = & $installerPath -ModuleNames DriverManagement -Force
    
    if ($result.Success) {
        Import-Module DriverManagement -Force
        Invoke-DriverManagement -Mode Individual
    }
}
catch {
    Write-Error "Module installation failed: $_"
    exit 1
}
'@

# Pattern 3: Module-as-a-service check
$ModuleServiceCheck = @'
# Run periodically to ensure modules are current
$requiredModules = @{
    'DriverManagement' = '1.0.0'
    'ComplianceCheck' = '1.0.0'
}

foreach ($module in $requiredModules.GetEnumerator()) {
    $installed = Get-Module -ListAvailable -Name $module.Key
    
    if (-not $installed -or $installed.Version -lt [version]$module.Value) {
        Write-Host "Updating $($module.Key)..."
        & "$env:ProgramData\PSDriverManagement\ModuleInstaller\Install-PSDriverManagement.ps1" -ModuleNames $module.Key -Force
    }
}
'@
#endregion
