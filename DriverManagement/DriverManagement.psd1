@{
    # Module identification
    RootModule        = 'DriverManagement.psm1'
    ModuleVersion     = '1.2.1'
    GUID              = 'd42594f7-6005-4bcb-a6bf-23274f1eff9f'
    
    # Author and company
    Author            = 'Thomas Tyson'
    CompanyName       = ''
    Copyright         = '(c) 2024 Thomas Tyson. MIT License.'
    
    # Description
    Description       = 'Enterprise driver and Windows update management for Dell and Lenovo endpoints. Supports individual driver updates, full pack reinstalls, and Windows cumulative updates with comprehensive logging.'
    
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
        
        # Lenovo-specific
        'Get-LenovoDriverUpdates'
        'Install-LenovoDriverUpdates'
        'Install-LenovoFullDriverPack'
        
        # Windows Updates
        'Install-WindowsUpdates'
        
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
            )
            
            # License URI
            LicenseUri   = 'https://github.com/thomastysong/PSDriverManagement/blob/main/LICENSE'
            
            # Project URI
            ProjectUri   = 'https://github.com/thomastysong/PSDriverManagement'
            
            # Icon URI
            IconUri      = ''
            
            # Release notes
            ReleaseNotes = @'
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
