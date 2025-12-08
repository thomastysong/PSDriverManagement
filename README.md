# PSDriverManagement

Enterprise-grade PowerShell module for automated driver and Windows update management on Dell and Lenovo endpoints.

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/DriverManagement.svg)](https://www.powershellgallery.com/packages/DriverManagement)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

PSDriverManagement provides automated driver management for enterprise fleets. It supports Dell and Lenovo hardware with two operational modes:

- **Individual**: Surgical updates for outdated or missing drivers only
- **FullPack**: Complete driver pack reinstallation

Key features:
- **Dual logging** to Windows Event Log and structured JSON files
- **Cross-platform orchestrator support** (Intune, FleetDM, Chef, Ansible, SCCM)
- **Pre-provisioning capable** (installs before Intune enrollment completes)
- **Update blocking/approval workflows** for enterprise control
- **Driver rollback** with multiple mechanisms (Device Manager, DCU restore, snapshots)
- **Offline catalog support** for air-gapped environments
- **Comprehensive error handling** with retry logic

## What's New in v1.3.0

### Windows Update Blocking
Block specific updates by KB article ID to prevent problematic updates from installing:

```powershell
# Block a specific update
Block-WindowsUpdate -KBArticleID 'KB5001234'

# View blocked updates
Get-BlockedUpdates

# Export/import blocklists for fleet management
Export-UpdateBlocklist -Path 'C:\blocklist.json'
Import-UpdateBlocklist -Path 'C:\blocklist.json' -Apply
```

### Driver Rollback
Multiple rollback mechanisms for when updates cause issues:

```powershell
# View drivers that can be rolled back
Get-RollbackableDrivers

# Rollback a specific driver
Invoke-DriverRollback -DeviceName "NVIDIA GeForce"

# Create driver snapshot before updates
New-DriverSnapshot -Name "Pre-Update Baseline" -IncludeInfFiles

# Restore from snapshot
Restore-DriverSnapshot -Name "Pre-Update Baseline"
```

### Update Approval Workflow
Enterprise-grade approval controls with multiple sources:

```powershell
# Block specific updates via local blocklist
Set-UpdateApproval -AddBlockedKB 'KB5001234', 'KB5005678'
Set-UpdateApproval -AddBlockedDriver 'nvlddmkm.inf'

# Enable approved-only mode (whitelist)
Set-UpdateApproval -ApprovedOnly $true

# Sync from external approval API
Set-ApprovalEndpoint -Uri 'https://approvals.company.com/api/v1' -ApiKey 'xxx'
Sync-ExternalApproval

# Check if update is approved before installing
$update | Test-UpdateApproval
```

### Dell Command Update Improvements
Inspired by [Gary Blok's Dell-EMPS.ps1](https://github.com/gwblok/garytown):

```powershell
# Check DCU installation details
Get-DCUInstallDetails

# Get latest DCU version info
Get-LatestDCUVersion -CheckUpdate

# Comprehensive exit code information
Get-DCUExitInfo -ExitCode 500

# Configure DCU settings
Set-DCUSettings -AutoSuspendBitLocker enable -AdvancedDriverRestore enable

# Create offline catalog for air-gapped environments
New-DCUOfflineCatalog -OutputPath 'C:\DCUOffline' -IncludeDrivers
```

## Installation

### From PowerShell Gallery (Recommended)

```powershell
Install-Module -Name DriverManagement -Scope AllUsers
```

### Manual Installation

```powershell
# Clone the repository
git clone https://github.com/thomastysong/PSDriverManagement.git

# Copy module to PowerShell modules path
Copy-Item -Path .\PSDriverManagement\DriverManagement -Destination "$env:ProgramFiles\WindowsPowerShell\Modules" -Recurse
```

## Quick Start

```powershell
# Import the module
Import-Module DriverManagement

# Check system info
Get-OEMInfo

# Run individual driver updates
Invoke-DriverManagement -Mode Individual -UpdateTypes Driver -NoReboot

# Run full driver pack reinstall
Invoke-DriverManagement -Mode FullPack -IncludeWindowsUpdates

# Schedule weekly updates
Register-DriverManagementTask -TriggerType Weekly -Time "03:00"

# Check compliance status
Get-DriverComplianceStatus
```

## Directory Structure

```
PSDriverManagement/
├── DriverManagement/
│   ├── DriverManagement.psd1         # Module manifest
│   ├── DriverManagement.psm1         # Module loader
│   ├── Classes/
│   │   └── DriverManagementConfig.ps1
│   ├── Private/
│   │   ├── Logging.ps1
│   │   ├── Utilities.ps1
│   │   └── VersionComparison.ps1
│   ├── Public/
│   │   ├── Invoke-DriverManagement.ps1
│   │   ├── Get-OEMInfo.ps1
│   │   ├── Dell.ps1
│   │   ├── Lenovo.ps1
│   │   ├── WindowsUpdate.ps1
│   │   ├── ScheduledTasks.ps1
│   │   ├── UpdateBlocking.ps1        # NEW: Update blocking
│   │   ├── DriverRollback.ps1        # NEW: Driver rollback
│   │   └── UpdateApproval.ps1        # NEW: Approval workflows
│   └── en-US/
│       └── about_DriverManagement.help.txt
├── ModuleInstaller/
│   ├── Install-PSDriverManagement.ps1
│   └── Examples/
│       └── OrchestratorIntegration.ps1
├── LICENSE
└── README.md
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PSDM_MODULE_SOURCE` | Base URL for module downloads | GitHub releases |
| `PSDM_LOG_PATH` | Custom log directory | `%ProgramData%\PSDriverManagement\Logs` |
| `PSDM_EVENT_LOG` | Custom event log name | `PSDriverManagement` |
| `PSDM_DCU_URL` | Dell Command Update installer URL | Dell CDN |
| `PSDM_DCU_CATALOG` | Custom DCU catalog path | Dell online |
| `PSDM_APPROVAL_API` | External approval API endpoint | None |

### Customizing Dell Command Update Download URL

If Dell's CDN is blocked or you want to host DCU internally:

```powershell
# Option 1: Environment variable (runtime)
$env:PSDM_DCU_URL = "https://your-cdn.company.com/software/Dell-Command-Update.exe"

# Option 2: Set permanently
[Environment]::SetEnvironmentVariable("PSDM_DCU_URL", "https://your-cdn.com/DCU.exe", "Machine")
```

### Offline Catalog for Air-Gapped Environments

```powershell
# Create offline catalog with drivers
New-DCUOfflineCatalog -OutputPath '\\server\share\DCU' -IncludeDrivers

# Configure DCU to use offline catalog
Set-DCUCatalogPath -CatalogPath '\\server\share\DCU\Catalog\OfflineCatalog.xml'

# Reset to online catalog
Set-DCUCatalogPath -Reset
```

### View Current Configuration

```powershell
Get-DriverManagementConfig
```

## Update Blocking & Approval

### Block Specific Updates

```powershell
# Block by KB
Block-WindowsUpdate -KBArticleID 'KB5001234', 'KB5005678'

# Block by title pattern
Block-WindowsUpdate -Title '*NVIDIA*'

# View all blocked updates
Get-BlockedUpdates -IncludeLocal

# Unblock
Unblock-WindowsUpdate -KBArticleID 'KB5001234'
Unblock-WindowsUpdate -All
```

### Enterprise Approval Workflow

```powershell
# Local JSON-based approval
Set-UpdateApproval -ApprovedOnly $true
Set-UpdateApproval -AddApprovedUpdate 'KB5002345'
Set-UpdateApproval -AddBlockedDriver 'nvlddmkm.inf'

# Intune integration
Set-IntuneApprovalConfig -TenantId 'xxx' -ClientId 'yyy' -UseManagedIdentity
Sync-IntuneUpdateApproval

# External API
Set-ApprovalEndpoint -Uri 'https://approvals.company.com/api' -ApiKey 'xxx'
Sync-ExternalApproval
```

## Driver Rollback

### Device Manager Rollback

```powershell
# List drivers with rollback available
Get-RollbackableDrivers

# Rollback specific device
Invoke-DriverRollback -DeviceID 'PCI\VEN_10DE...'
```

### Dell Driver Restore

```powershell
# Enable Dell's advanced driver restore
Enable-DellDriverRestore

# Create restore point
New-DellDriverRestorePoint -Name "Before graphics update"

# Restore
Restore-DellDrivers -Latest
```

### Driver Snapshots

```powershell
# Create snapshot (with INF files for full restore capability)
New-DriverSnapshot -Name "Baseline" -IncludeInfFiles

# List snapshots
Get-DriverSnapshots

# Restore from snapshot
Restore-DriverSnapshot -Name "Baseline"

# Remove old snapshots
Remove-DriverSnapshot -Name "OldSnapshot"
```

## Logging

All modules log to:
- **Windows Event Log**: `PSDriverManagement` application log
- **JSON files**: `%ProgramData%\PSDriverManagement\Logs\`

Event ID ranges:
- 1000-1099: Informational
- 2000-2099: Warning
- 3000-3099: Error

Retrieve logs:
```powershell
Get-DriverManagementLogs -Last 100 -Severity Error, Warning
```

## Supported Hardware

**All Dell and Lenovo systems are supported.** The module automatically detects the OEM and applies the appropriate driver management strategy:

- **Dell**: Uses Dell Command Update CLI (auto-installed if not present)
- **Lenovo**: Uses LSUClient module (auto-installed from PowerShell Gallery if not present)

### Automatic Tool Installation

| OEM | Tool | Auto-Install Source |
|-----|------|---------------------|
| Dell | Dell Command Update | Dell's website (silent install) |
| Lenovo | LSUClient | PowerShell Gallery |
| Lenovo | Thin Installer | Fallback if LSUClient fails |

Non-Dell/Lenovo systems will be detected but skipped.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Prerequisites not met |
| 3 | Download failure |
| 4 | Installation failure |
| 3010 | Success, reboot required |

Get detailed DCU exit code information:
```powershell
Get-DCUExitInfo -ExitCode 500
```

## Aliases

| Alias | Command |
|-------|---------|
| `idm` | `Invoke-DriverManagement` |
| `gdcs` | `Get-DriverComplianceStatus` |

## Orchestrator Integration

### Intune Win32 App

```
Install command:  powershell.exe -ExecutionPolicy Bypass -File Install-PSDriverManagement.ps1 -ModuleNames DriverManagement
Uninstall:        powershell.exe -Command "Remove-Module DriverManagement -Force; Remove-Item '$env:ProgramFiles\WindowsPowerShell\Modules\DriverManagement' -Recurse"
Detection:        Custom script checking Get-Module -ListAvailable -Name DriverManagement
```

### FleetDM

```yaml
SELECT name, version, path FROM powershell_modules WHERE name = 'DriverManagement';
```

### Chef

```ruby
powershell_script 'install_driver_management' do
  code 'Install-PSDriverManagement.ps1 -ModuleNames DriverManagement'
  creates 'C:\Program Files\WindowsPowerShell\Modules\DriverManagement'
end
```

### Ansible

```yaml
- name: Install PSDriverManagement modules
  win_shell: |
    & C:\Temp\Install-PSDriverManagement.ps1 -ModuleNames DriverManagement -Force
```

See `ModuleInstaller/Examples/OrchestratorIntegration.ps1` for complete integration examples.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## Testing

```powershell
# Import without installing
Import-Module .\DriverManagement\DriverManagement.psd1 -Force

# Run Pester tests (when available)
Invoke-Pester .\Tests\
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Dell Command Update CLI
- [Gary Blok's Dell-EMPS.ps1](https://github.com/gwblok/garytown) - Inspiration for DCU improvements
- Lenovo LSUClient PowerShell module
- PSWindowsUpdate module
