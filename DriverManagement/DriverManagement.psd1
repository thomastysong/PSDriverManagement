@{
    # Module identification
    RootModule        = 'DriverManagement.psm1'
    ModuleVersion     = '1.5.9'
    GUID              = 'd42594f7-6005-4bcb-a6bf-23274f1eff9f'
    
    # Author and company
    Author            = 'Thomas Tyson'
    CompanyName       = ''
    Copyright         = '(c) 2024 Thomas Tyson. MIT License.'
    
    # Description
    Description       = 'Enterprise driver and Windows update management for Dell, Lenovo, and Intel endpoints. Supports individual driver updates, full pack reinstalls, Windows cumulative updates, update blocking/approval workflows, driver rollback, and offline catalog support.'
    
    # Minimum PowerShell version
    PowerShellVersion = '5.1'
    
    # CLR version required
    CLRVersion        = '4.0'
    
    # Processor architecture
    ProcessorArchitecture = 'None'
    
    # Required modules
    RequiredModules   = @()
    
    # Optional modules that enhance functionality
    # LSUClient for Lenovo, PSWindowsUpdate for Windows Updates
    
    # Assemblies required
    RequiredAssemblies = @()
    
    # Scripts to process when module loads
    ScriptsToProcess  = @()
    
    # Type files to load
    TypesToProcess    = @()
    
    # Format files to load
    FormatsToProcess  = @()
    
    # Nested modules
    NestedModules     = @()
    
    # Functions to export - these are the PUBLIC API
    FunctionsToExport = @(
        # Core driver management
        'Invoke-DriverManagement'
        'Get-DriverComplianceStatus'
        'Update-DriverComplianceStatus'
        
        # Dell-specific
        'Get-DellDriverUpdates'
        'Install-DellDriverUpdates'
        'Install-DellFullDriverPack'
        'Install-DellCommandUpdate'
        'Uninstall-DellSupportAssist'
        'Get-DCUInstallDetails'
        'Get-DCUExitInfo'
        'Get-DCUSettings'
        'Set-DCUSettings'
        'Get-DellCatalog'
        'Get-LatestDCUVersion'
        'Get-DCUCatalogPath'
        'Set-DCUCatalogPath'
        'New-DCUOfflineCatalog'
        'Get-DellDriverPackUrl'
        'Install-DellDriverPackDirect'
        'Test-DellOOBEBlocked'
        'Clear-DellOOBEFlag'
        
        # Dell driver restore
        'Enable-DellDriverRestore'
        'New-DellDriverRestorePoint'
        'Get-DellDriverRestorePoints'
        'Restore-DellDrivers'
        
        # Lenovo-specific
        'Get-LenovoDriverUpdates'
        'Install-LenovoDriverUpdates'
        'Install-LenovoFullDriverPack'
        
        # Intel-specific
        'Get-IntelDevices'
        'Get-IntelDriverUpdates'
        'Install-IntelDriverUpdates'
        'Initialize-IntelModule'
        
        # Windows Updates
        'Install-WindowsUpdates'
        
        # Update blocking
        'Block-WindowsUpdate'
        'Unblock-WindowsUpdate'
        'Get-BlockedUpdates'
        'Export-UpdateBlocklist'
        'Import-UpdateBlocklist'
        
        # Driver rollback
        'Get-RollbackableDrivers'
        'Invoke-DriverRollback'
        'Invoke-IntelDriverRollback'
        'New-DriverSnapshot'
        'Get-DriverSnapshots'
        'Get-DriverSnapshotDetails'
        'Restore-DriverSnapshot'
        'Remove-DriverSnapshot'
        
        # Update approval
        'Get-UpdateApproval'
        'Set-UpdateApproval'
        'Test-UpdateApproval'
        'Set-IntuneApprovalConfig'
        'Sync-IntuneUpdateApproval'
        'Set-ApprovalEndpoint'
        'Sync-ExternalApproval'
        'Send-UpdateReport'
        
        # Utility functions
        'Get-OEMInfo'
        'Test-DriverManagementPrerequisites'
        'Initialize-DriverManagementLogging'
        'Get-DriverManagementLogs'
        'Get-DriverManagementConfig'
        
        # Scheduled task management
        'Register-DriverManagementTask'
        'Unregister-DriverManagementTask'
    )
    
    # Cmdlets to export
    CmdletsToExport   = @()
    
    # Variables to export
    VariablesToExport = @()
    
    # Aliases to export
    AliasesToExport   = @(
        'idm'      # Invoke-DriverManagement
        'gdcs'     # Get-DriverComplianceStatus
    )
    
    # DSC resources to export
    DscResourcesToExport = @()
    
    # List of all files packaged with module
    FileList          = @(
        'DriverManagement.psd1'
        'DriverManagement.psm1'
        'Public\Invoke-DriverManagement.ps1'
        'Public\Get-DriverComplianceStatus.ps1'
        'Public\Update-DriverComplianceStatus.ps1'
        'Public\Get-OEMInfo.ps1'
        'Public\Dell.ps1'
        'Public\Lenovo.ps1'
        'Public\Intel.ps1'
        'Public\WindowsUpdate.ps1'
        'Public\ScheduledTasks.ps1'
        'Public\UpdateBlocking.ps1'
        'Public\DriverRollback.ps1'
        'Public\UpdateApproval.ps1'
        'Private\Logging.ps1'
        'Private\Utilities.ps1'
        'Private\VersionComparison.ps1'
        'Private\Status\Get-PendingRebootStateInternal.ps1'
        'Private\Status\Get-OemToolingStateInternal.ps1'
        'Private\Status\Get-PnpNonOkDevicesInternal.ps1'
        'Private\Status\Get-KernelPnp411Internal.ps1'
        'Private\Status\Get-WindowsUpdatePendingInternal.ps1'
        'Private\Status\Get-StatusPendingUpdatesInternal.ps1'
        'Private\Status\Get-DriverStoreInventoryInternal.ps1'
        'Private\Status\Get-DriverHealthScoreInternal.ps1'
        'Private\Status\New-DriverStatusReportInternal.ps1'
        'Private\Status\Write-DriverStatusArtifactInternal.ps1'
        'Private\Status\Write-DriverStatusLogsInternal.ps1'
        'Classes\DriverManagementConfig.ps1'
        'en-US\about_DriverManagement.help.txt'
    )
    
    # Private data - module configuration defaults
    PrivateData       = @{
        PSData = @{
            # Tags for module discovery
            Tags         = @(
                'Driver'
                'Windows'
                'Dell'
                'Lenovo'
                'Intel'
                'Intune'
                'Enterprise'
                'Updates'
                'Fleet'
                'MDM'
                'SCCM'
                'Autopilot'
                'Rollback'
                'Approval'
                'Blocking'
                'Compliance'
            )
            
            # License URI
            LicenseUri   = 'https://github.com/thomastysong/PSDriverManagement/blob/main/LICENSE'
            
            # Project URI
            ProjectUri   = 'https://github.com/thomastysong/PSDriverManagement'
            
            # Icon URI
            IconUri      = ''
            
            # Release notes
            ReleaseNotes = @'
## Version 1.5.9
### Bug Fixes
- **Dell DCU Stale XML Fix**: Fixed false-positive "1 applicable update" when DCU scan actually found no updates. The module now deletes the stale `DCUApplicableUpdates.xml` before each scan and does not trust the XML if the scan returns exit code 6 (no update information). This prevents the module from attempting `/applyUpdates` when there are no applicable updates for the requested filter (e.g., previous scan found a BIOS update but current scan is for drivers only).

## Version 1.5.8
### Bug Fixes
- **PowerShell 5.1 Compatibility**: Fixed `try` expression syntax in `Get-WindowsUpdatePendingInternal.ps1` and `Get-StatusPendingUpdatesInternal.ps1` that caused WindowsUpdate and Lenovo providers to fail in status mode on PowerShell 5.1.
- **Lenovo Status Mode**: Lenovo provider now correctly scans for pending updates via LSUClient when the module is installed.

### Improvements
- **Enhanced Lenovo Tooling Detection**: `Get-OemToolingStateInternal` now captures version and path information for LSUClient, Thin Installer, and System Update (matching Dell DCU's detail level).
- **Better Telemetry Parity**: Lenovo endpoints now emit the same level of detail to Event Viewer as Dell endpoints.

## Version 1.5.6
- **Dell DCU exit code 6 handling**: Treats DCU exit code `6` as **No applicable updates** when scan shows 0 applicable updates.

## Version 1.5.5
- Added `Invoke-DriverManagement -Status` for read-only driver/device health snapshots with Event Log and JSON artifact logging.

## Version 1.5.4
- Fixed PowerShell 5.1 module import failure caused by invalid `finally {}` block.

## Version 1.5.3
- **Fully non-interactive Windows Updates**: No Y/N prompts, forces `-Confirm:$false`, pre-registers Microsoft Update silently.

## Version 1.5.2
- **DCU scan-before-apply**: Runs `/scan` first, only `/applyUpdates` when updates detected.
- Better DCU exit code handling (retries on code 12, treats code 6 as success when appropriate).

## Version 1.5.1
- **DCU Install via WinGet Only**: Uses `winget install Dell.CommandUpdate` exclusively.

## Version 1.5.0
- Fixed DCU privilege error handling (exit codes 4, 5).
- Failure propagation from OEM/Intel/Windows Update providers.

## Version 1.4.x Summary
- **Intel Driver Management**: Full support via Intel DSA data feed.
- Dynamic Intel updates (Graphics/Wireless) using `dsadata.intel.com`.
- WinGet auto-install for DCU fallback.
- Auto-uninstalls Dell SupportAssist before DCU install.
- Hardened Intel driver downloads with TLS 1.2.

## Version 1.3.x Summary
- **Windows Update Blocking**: Block/unblock by KB ID.
- **Driver Rollback System**: Device Manager, Dell advancedDriverRestore, snapshots.
- **Update Approval Workflow**: Local JSON, Intune, External API support.
- **Dell Command Update Improvements**: Catalog-based detection, 25+ exit codes, offline catalog.
- PowerShell 5.1 compatibility fixes.

## Earlier Versions
- v1.2.x: DCU auto-install, custom download URL support.
- v1.1.0: Universal Dell/Lenovo support (all models).
- v1.0.0: Initial release with Dell/Lenovo/Windows Update support.

Full changelog: https://github.com/thomastysong/PSDriverManagement/releases
'@
            
            # Prerelease tag
            Prerelease   = ''
            
            # External module dependencies
            ExternalModuleDependencies = @()
        }
        
        # Module-specific configuration defaults
        ModuleConfig = @{
            LogPath              = '$env:ProgramData\PSDriverManagement\Logs'
            CompliancePath       = '$env:ProgramData\PSDriverManagement\compliance.json'
            EventLogName         = 'PSDriverManagement'
            EventLogSource       = 'DriverManagement'
            MaxLogAgeDays        = 30
            MaxLogSizeMB         = 50
            DefaultMode          = 'Individual'
            DefaultUpdateTypes   = @('Driver')
            DefaultSeverity      = @('Critical', 'Recommended')
            # Note: As of v1.1.0, ALL Dell and Lenovo systems are supported
            # These lists are kept for reference but no longer used for filtering
            SupportedDellModels  = @()  # All Dell models supported
            SupportedLenovoMTMs  = @()  # All Lenovo models supported
            
            # Dell Command Update download URL (auto-installed if not present)
            # Update this URL when new DCU versions are released
            DellCommandUpdateUrl = 'https://dl.dell.com/FOLDER11914155M/1/Dell-Command-Update-Windows-Universal-Application_601KT_WIN_5.4.0_A00.EXE'
        }
    }
    
    # Help info URI
    HelpInfoURI       = 'https://github.com/thomastysong/PSDriverManagement'
    
    # Default command prefix (optional)
    DefaultCommandPrefix = ''
}
