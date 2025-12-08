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
- **Comprehensive error handling** with retry logic

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

### Using the Installer Script

```powershell
# Download and run the installer
.\Install-PSDriverManagement.ps1 -ModuleNames DriverManagement
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
│   │   └── ScheduledTasks.ps1
│   └── en-US/
│       └── about_DriverManagement.help.txt
├── ModuleInstaller/
│   ├── Install-PSDriverManagement.ps1
│   └── Examples/
│       └── OrchestratorIntegration.ps1
├── LICENSE
└── README.md
```

## Orchestrator Integration

### Intune Win32 App

```
Install command:  powershell.exe -ExecutionPolicy Bypass -File Install-PSDriverManagement.ps1 -ModuleNames DriverManagement
Uninstall:        powershell.exe -Command "Remove-Module DriverManagement -Force; Remove-Item '$env:ProgramFiles\WindowsPowerShell\Modules\DriverManagement' -Recurse"
Detection:        Custom script checking Get-Module -ListAvailable -Name DriverManagement
```

### FleetDM

```yaml
# Fleet query to check module status
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

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PSDM_MODULE_SOURCE` | Base URL for module downloads | GitHub releases |
| `PSDM_LOG_PATH` | Custom log directory | `%ProgramData%\PSDriverManagement\Logs` |
| `PSDM_EVENT_LOG` | Custom event log name | `PSDriverManagement` |

### View Current Configuration

```powershell
Get-DriverManagementConfig
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

The module will automatically download and install the required driver management tools if they're not already present:

| OEM | Tool | Auto-Install Source |
|-----|------|---------------------|
| Dell | Dell Command Update | Dell's website (silent install) |
| Lenovo | LSUClient | PowerShell Gallery |
| Lenovo | Thin Installer | Fallback if LSUClient fails |

Non-Dell/Lenovo systems will be detected but skipped (no driver operations performed).

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Prerequisites not met |
| 3 | Download failure |
| 4 | Installation failure |
| 3010 | Success, reboot required |

## Aliases

| Alias | Command |
|-------|---------|
| `idm` | `Invoke-DriverManagement` |
| `gdcs` | `Get-DriverComplianceStatus` |

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
- Lenovo LSUClient PowerShell module
- PSWindowsUpdate module
