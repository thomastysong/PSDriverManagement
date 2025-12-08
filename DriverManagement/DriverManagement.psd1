@{
    # Module identification
    RootModule        = 'DriverManagement.psm1'
    ModuleVersion     = '1.0.0'
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
            SupportedDellModels  = @(
                'Precision 5690', 'Precision 5760', 'Precision 5680', 'Precision 5490'
                'Precision 5480', 'Precision 5750', 'Precision 3561', 'Precision 3551'
                'Precision 7680', 'Latitude 7420', 'Latitude 9440'
            )
            SupportedLenovoMTMs  = @('21KC', '21KD', '21NS', '21NT')
        }
    }
    
    # Help info URI
    HelpInfoURI       = 'https://github.com/thomastysong/PSDriverManagement'
    
    # Default command prefix (optional)
    DefaultCommandPrefix = ''
}
