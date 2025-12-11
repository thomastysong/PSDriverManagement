@{
    # Module identification
    RootModule        = 'DriverManagement.psm1'
    ModuleVersion     = '1.3.3'
    GUID              = 'd42594f7-6005-4bcb-a6bf-23274f1eff9f'
    
    # Author and company
    Author            = 'Thomas Tyson'
    CompanyName       = ''
    Copyright         = '(c) 2024 Thomas Tyson. MIT License.'
    
    # Description
    Description       = 'Enterprise driver and Windows update management for Dell and Lenovo endpoints. Supports individual driver updates, full pack reinstalls, Windows cumulative updates, update blocking/approval workflows, driver rollback, and offline catalog support.'
    
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
        'Get-DCUInstallDetails'
        'Get-DCUExitInfo'
        'Get-DCUSettings'
        'Set-DCUSettings'
        'Get-DellCatalog'
        'Get-LatestDCUVersion'
        'Get-DCUCatalogPath'
        'Set-DCUCatalogPath'
        'New-DCUOfflineCatalog'
        
        # Dell driver restore
        'Enable-DellDriverRestore'
        'New-DellDriverRestorePoint'
        'Get-DellDriverRestorePoints'
        'Restore-DellDrivers'
        
        # Lenovo-specific
        'Get-LenovoDriverUpdates'
        'Install-LenovoDriverUpdates'
        'Install-LenovoFullDriverPack'
        
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
        'Public\WindowsUpdate.ps1'
        'Public\ScheduledTasks.ps1'
        'Public\UpdateBlocking.ps1'
        'Public\DriverRollback.ps1'
        'Public\UpdateApproval.ps1'
        'Private\Logging.ps1'
        'Private\Utilities.ps1'
        'Private\VersionComparison.ps1'
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
## Version 1.3.3
### Bug Fixes
- Fixed missing function exports: Block-WindowsUpdate, Get-UpdateApproval, and other UpdateBlocking/UpdateApproval functions were not exported
- Added all missing functions to Export-ModuleMember in DriverManagement.psm1
- Functions are now properly available after Import-Module

## Version 1.3.2
### Bug Fixes
- Fixed array filtering bug where removing the last item from BlockedKBs, BlockedDrivers, or ApprovedUpdates would leave a null element instead of an empty array
- Now properly filters out null values after Where-Object operations

## Version 1.3.1
### Bug Fixes
- **PowerShell 5.1 Compatibility**: Fixed null-coalescing operator (`??`) usage that prevented module from loading in PowerShell 5.1
  - Replaced all `??` operators with PowerShell 5.1-compatible `if/else` syntax
  - Module now works correctly in both PowerShell 5.1 and PowerShell 7+

## Version 1.3.0
### New Features
- **Windows Update Blocking**: Block/unblock updates by KB article ID using PSWindowsUpdate integration
  - `Block-WindowsUpdate`, `Unblock-WindowsUpdate`, `Get-BlockedUpdates`
  - `Export-UpdateBlocklist`, `Import-UpdateBlocklist` for portable blocklists
  
- **Driver Rollback System**: Multiple rollback mechanisms
  - Device Manager integration: `Get-RollbackableDrivers`, `Invoke-DriverRollback`
  - Dell advancedDriverRestore: `Enable-DellDriverRestore`, `New-DellDriverRestorePoint`, `Restore-DellDrivers`
  - Driver snapshots: `New-DriverSnapshot`, `Restore-DriverSnapshot`, `Get-DriverSnapshots`
  
- **Update Approval Workflow**: Enterprise approval controls
  - Local JSON blocklist: `Get-UpdateApproval`, `Set-UpdateApproval`, `Test-UpdateApproval`
  - Intune integration: `Set-IntuneApprovalConfig`, `Sync-IntuneUpdateApproval`
  - External API support: `Set-ApprovalEndpoint`, `Sync-ExternalApproval`
  
- **Dell Command Update Improvements** (inspired by Gary Blok's Dell-EMPS.ps1)
  - Catalog-based version detection: `Get-DellCatalog`, `Get-LatestDCUVersion`
  - Comprehensive exit code handling: `Get-DCUExitInfo` with 25+ documented codes
  - Version check before download: `Get-DCUInstallDetails`
  - Offline catalog support: `Set-DCUCatalogPath`, `New-DCUOfflineCatalog`
  - Settings management: `Get-DCUSettings`, `Set-DCUSettings`

### Environment Variables
- `PSDM_DCU_URL`: Custom Dell Command Update download URL
- `PSDM_DCU_CATALOG`: Custom DCU catalog path for offline use
- `PSDM_APPROVAL_API`: External approval API endpoint

## Version 1.2.1
- Added PSDM_DCU_URL environment variable for custom Dell Command Update download URL
- Enables enterprises to host DCU on internal CDN/repository
- Updated documentation with CDN customization instructions

## Version 1.2.0
- Automatic Dell Command Update installation if not present
- Downloads DCU from Dell's website and installs silently
- Configurable download URL in module manifest
- Matches Lenovo LSUClient auto-install behavior

## Version 1.1.0
- Universal support for ALL Dell and Lenovo systems (removed model restrictions)
- No longer limited to specific models - works with any Dell or Lenovo hardware

## Version 1.0.0
- Initial release
- Support for Dell Command Update CLI integration
- Support for Lenovo LSUClient and Thin Installer
- Dual-mode operation: Individual updates and Full pack reinstall
- Windows Event Log and JSON file logging
- Intune, FleetDM, Chef, Ansible, SCCM compatible
- Pre-provisioning installation support
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
