#Requires -Version 5.1

<#
.SYNOPSIS
    Windows Update blocking and hiding functions
.DESCRIPTION
    Provides functions to block, unblock, and manage Windows Update visibility
    using PSWindowsUpdate module integration.
#>

function Block-WindowsUpdate {
    <#
    .SYNOPSIS
        Hides/blocks specific Windows Updates by KB article ID
    .DESCRIPTION
        Uses PSWindowsUpdate to hide updates, preventing them from being installed.
        Hidden updates won't appear in Windows Update scans.
    .PARAMETER KBArticleID
        One or more KB article IDs to block (e.g., 'KB5001234', 'KB5005678')
    .PARAMETER Title
        Block updates matching this title pattern (supports wildcards)
    .EXAMPLE
        Block-WindowsUpdate -KBArticleID 'KB5001234'
    .EXAMPLE
        Block-WindowsUpdate -KBArticleID 'KB5001234', 'KB5005678'
    .EXAMPLE
        Block-WindowsUpdate -Title '*NVIDIA*'
    .OUTPUTS
        Array of blocked update objects
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByKB')]
        [string[]]$KBArticleID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByTitle')]
        [string]$Title
    )
    
    Assert-Elevation -Operation "Blocking Windows Updates"
    
    # Ensure PSWindowsUpdate is available
    Initialize-PSWindowsUpdate
    
    $blockedUpdates = @()
    
    try {
        if ($PSCmdlet.ParameterSetName -eq 'ByKB') {
            foreach ($kb in $KBArticleID) {
                # Normalize KB format
                $normalizedKB = if ($kb -match '^KB') { $kb } else { "KB$kb" }
                
                if ($PSCmdlet.ShouldProcess($normalizedKB, "Block Windows Update")) {
                    Write-DriverLog -Message "Blocking Windows Update: $normalizedKB" -Severity Info
                    
                    $result = Hide-WindowsUpdate -KBArticleID $normalizedKB -Confirm:$false -ErrorAction Stop
                    
                    if ($result) {
                        $blockedUpdates += $result
                        Write-DriverLog -Message "Successfully blocked: $normalizedKB" -Severity Info
                        
                        # Also add to local blocklist
                        Add-ToLocalBlocklist -KBArticleID $normalizedKB
                    }
                }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByTitle') {
            if ($PSCmdlet.ShouldProcess($Title, "Block Windows Updates matching title")) {
                Write-DriverLog -Message "Blocking Windows Updates matching: $Title" -Severity Info
                
                $result = Hide-WindowsUpdate -Title $Title -Confirm:$false -ErrorAction Stop
                
                if ($result) {
                    $blockedUpdates += $result
                    foreach ($update in $result) {
                        Write-DriverLog -Message "Successfully blocked: $($update.Title)" -Severity Info
                        Add-ToLocalBlocklist -KBArticleID $update.KB -Title $update.Title
                    }
                }
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to block update: $($_.Exception.Message)" -Severity Error
        throw
    }
    
    return $blockedUpdates
}

function Unblock-WindowsUpdate {
    <#
    .SYNOPSIS
        Shows/unblocks previously hidden Windows Updates
    .DESCRIPTION
        Uses PSWindowsUpdate to show hidden updates, making them available for installation again.
    .PARAMETER KBArticleID
        One or more KB article IDs to unblock
    .PARAMETER Title
        Unblock updates matching this title pattern
    .PARAMETER All
        Unblock all hidden updates
    .EXAMPLE
        Unblock-WindowsUpdate -KBArticleID 'KB5001234'
    .EXAMPLE
        Unblock-WindowsUpdate -All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByKB')]
        [string[]]$KBArticleID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByTitle')]
        [string]$Title,
        
        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All
    )
    
    Assert-Elevation -Operation "Unblocking Windows Updates"
    
    Initialize-PSWindowsUpdate
    
    $unblockedUpdates = @()
    
    try {
        if ($All) {
            if ($PSCmdlet.ShouldProcess("All hidden updates", "Unblock")) {
                Write-DriverLog -Message "Unblocking all hidden Windows Updates" -Severity Info
                
                $hiddenUpdates = Get-WindowsUpdate -IsHidden -ErrorAction SilentlyContinue
                
                foreach ($update in $hiddenUpdates) {
                    $result = Show-WindowsUpdate -KBArticleID $update.KB -Confirm:$false -ErrorAction Stop
                    if ($result) {
                        $unblockedUpdates += $result
                        Remove-FromLocalBlocklist -KBArticleID $update.KB
                    }
                }
                
                Write-DriverLog -Message "Unblocked $($unblockedUpdates.Count) updates" -Severity Info
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByKB') {
            foreach ($kb in $KBArticleID) {
                $normalizedKB = if ($kb -match '^KB') { $kb } else { "KB$kb" }
                
                if ($PSCmdlet.ShouldProcess($normalizedKB, "Unblock Windows Update")) {
                    Write-DriverLog -Message "Unblocking Windows Update: $normalizedKB" -Severity Info
                    
                    $result = Show-WindowsUpdate -KBArticleID $normalizedKB -Confirm:$false -ErrorAction Stop
                    
                    if ($result) {
                        $unblockedUpdates += $result
                        Remove-FromLocalBlocklist -KBArticleID $normalizedKB
                        Write-DriverLog -Message "Successfully unblocked: $normalizedKB" -Severity Info
                    }
                }
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByTitle') {
            if ($PSCmdlet.ShouldProcess($Title, "Unblock Windows Updates matching title")) {
                $result = Show-WindowsUpdate -Title $Title -Confirm:$false -ErrorAction Stop
                
                if ($result) {
                    $unblockedUpdates += $result
                    foreach ($update in $result) {
                        Remove-FromLocalBlocklist -KBArticleID $update.KB
                    }
                }
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to unblock update: $($_.Exception.Message)" -Severity Error
        throw
    }
    
    return $unblockedUpdates
}

function Get-BlockedUpdates {
    <#
    .SYNOPSIS
        Lists all blocked/hidden Windows Updates
    .DESCRIPTION
        Returns a list of all updates that have been hidden from Windows Update.
        Also includes updates from the local blocklist that may not be currently available.
    .PARAMETER IncludeLocal
        Include entries from the local blocklist file that may not be currently hidden
    .EXAMPLE
        Get-BlockedUpdates
    .EXAMPLE
        Get-BlockedUpdates -IncludeLocal
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeLocal
    )
    
    Initialize-PSWindowsUpdate
    
    $blockedUpdates = @()
    
    # Get currently hidden updates from Windows Update
    try {
        $hiddenUpdates = Get-WindowsUpdate -IsHidden -ErrorAction SilentlyContinue
        
        if ($hiddenUpdates) {
            foreach ($update in $hiddenUpdates) {
                $blockedUpdates += [PSCustomObject]@{
                    KBArticleID  = $update.KB
                    Title        = $update.Title
                    Size         = $update.Size
                    Source       = 'WindowsUpdate'
                    HiddenDate   = $null
                    IsCurrentlyHidden = $true
                }
            }
        }
    }
    catch {
        Write-DriverLog -Message "Failed to query hidden updates: $($_.Exception.Message)" -Severity Warning
    }
    
    # Include local blocklist entries
    if ($IncludeLocal) {
        $localBlocklist = Get-LocalBlocklist
        
        foreach ($entry in $localBlocklist.BlockedKBs) {
            # Check if already in list
            if ($blockedUpdates.KBArticleID -notcontains $entry.KBArticleID) {
                $blockedUpdates += [PSCustomObject]@{
                    KBArticleID  = $entry.KBArticleID
                    Title        = $entry.Title
                    Size         = $null
                    Source       = 'LocalBlocklist'
                    HiddenDate   = $entry.DateBlocked
                    IsCurrentlyHidden = $false
                }
            }
        }
    }
    
    return $blockedUpdates
}

function Export-UpdateBlocklist {
    <#
    .SYNOPSIS
        Exports the update blocklist to a JSON file
    .DESCRIPTION
        Exports both the local blocklist and currently hidden updates to a portable JSON format.
    .PARAMETER Path
        Path to export the blocklist to
    .PARAMETER IncludeHidden
        Include currently hidden Windows Updates (not just local blocklist)
    .EXAMPLE
        Export-UpdateBlocklist -Path 'C:\Backup\blocklist.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [switch]$IncludeHidden
    )
    
    $exportData = @{
        ExportDate = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        LocalBlocklist = (Get-LocalBlocklist)
        HiddenUpdates = @()
    }
    
    if ($IncludeHidden) {
        Initialize-PSWindowsUpdate
        $hidden = Get-WindowsUpdate -IsHidden -ErrorAction SilentlyContinue
        if ($hidden) {
            $exportData.HiddenUpdates = $hidden | ForEach-Object {
                @{
                    KBArticleID = $_.KB
                    Title = $_.Title
                    Size = $_.Size
                }
            }
        }
    }
    
    $exportData | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
    
    Write-DriverLog -Message "Exported blocklist to: $Path" -Severity Info
    
    return $Path
}

function Import-UpdateBlocklist {
    <#
    .SYNOPSIS
        Imports an update blocklist from a JSON file
    .DESCRIPTION
        Imports blocklist entries and optionally applies them (hides the updates).
    .PARAMETER Path
        Path to the blocklist JSON file
    .PARAMETER Apply
        Actually hide the imported updates (requires elevation)
    .EXAMPLE
        Import-UpdateBlocklist -Path 'C:\Backup\blocklist.json' -Apply
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path,
        
        [Parameter()]
        [switch]$Apply
    )
    
    $importData = Get-Content -Path $Path -Raw | ConvertFrom-Json
    
    Write-DriverLog -Message "Importing blocklist from: $Path (exported: $($importData.ExportDate))" -Severity Info
    
    # Merge with existing local blocklist
    $localBlocklist = Get-LocalBlocklist
    
    foreach ($entry in $importData.LocalBlocklist.BlockedKBs) {
        if ($localBlocklist.BlockedKBs.KBArticleID -notcontains $entry.KBArticleID) {
            $localBlocklist.BlockedKBs += $entry
        }
    }
    
    foreach ($driver in $importData.LocalBlocklist.BlockedDrivers) {
        if ($localBlocklist.BlockedDrivers -notcontains $driver) {
            $localBlocklist.BlockedDrivers += $driver
        }
    }
    
    Save-LocalBlocklist -Blocklist $localBlocklist
    
    # Apply hidden updates if requested
    if ($Apply) {
        Assert-Elevation -Operation "Applying imported blocklist"
        Initialize-PSWindowsUpdate
        
        $allKBs = @()
        $allKBs += $importData.LocalBlocklist.BlockedKBs.KBArticleID
        $allKBs += $importData.HiddenUpdates.KBArticleID
        $allKBs = $allKBs | Where-Object { $_ } | Select-Object -Unique
        
        foreach ($kb in $allKBs) {
            if ($PSCmdlet.ShouldProcess($kb, "Hide imported update")) {
                try {
                    Hide-WindowsUpdate -KBArticleID $kb -Confirm:$false -ErrorAction SilentlyContinue
                    Write-DriverLog -Message "Applied block for: $kb" -Severity Info
                }
                catch {
                    Write-DriverLog -Message "Could not hide $kb (may not be available): $($_.Exception.Message)" -Severity Warning
                }
            }
        }
    }
    
    return $importData
}

#region Helper Functions

function Initialize-PSWindowsUpdate {
    <#
    .SYNOPSIS
        Ensures PSWindowsUpdate module is available
    #>
    [CmdletBinding()]
    param()
    
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-DriverLog -Message "Installing PSWindowsUpdate module" -Severity Info
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
    }
    
    # Remove module if already loaded to avoid alias conflicts
    if (Get-Module -Name PSWindowsUpdate) {
        Remove-Module -Name PSWindowsUpdate -Force -ErrorAction SilentlyContinue
    }
    
    # Import module, suppressing alias warnings (they're harmless if module was already loaded)
    # Use error redirection to suppress alias creation warnings during import
    $originalErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    
    # Redirect all output and filter out alias errors
    $importOutput = Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 2>&1
    
    # Check if import actually failed (not just alias warnings)
    $realErrors = $importOutput | Where-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            # Only keep errors that aren't alias-related
            return $_.Exception.Message -notmatch 'alias.*already exists'
        }
        return $false
    }
    
    $ErrorActionPreference = $originalErrorAction
    
    # If there were real errors (not just alias warnings), throw them
    if ($realErrors) {
        throw "Failed to import PSWindowsUpdate: $($realErrors[0].Exception.Message)"
    }
    
    # Verify module loaded successfully
    if (-not (Get-Module -Name PSWindowsUpdate)) {
        throw "Failed to import PSWindowsUpdate module"
    }
}

function Get-LocalBlocklistPath {
    $config = $script:ModuleConfig
    $basePath = Split-Path $config.CompliancePath -Parent
    return Join-Path $basePath "blocklist.json"
}

function Get-LocalBlocklist {
    <#
    .SYNOPSIS
        Gets the local blocklist from JSON file
    #>
    $path = Get-LocalBlocklistPath
    
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    
    # Return default structure
    return [PSCustomObject]@{
        Version = '1.0'
        LastModified = $null
        BlockedKBs = @()
        BlockedDrivers = @()
        ApprovedOnly = $false
        ApprovedUpdates = @()
    }
}

function Save-LocalBlocklist {
    param(
        [Parameter(Mandatory)]
        $Blocklist
    )
    
    $path = Get-LocalBlocklistPath
    $dir = Split-Path $path -Parent
    
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    
    $Blocklist.LastModified = (Get-Date).ToString('o')
    $Blocklist | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Add-ToLocalBlocklist {
    param(
        [string]$KBArticleID,
        [string]$Title,
        [string]$DriverInf
    )
    
    $blocklist = Get-LocalBlocklist
    
    if ($KBArticleID) {
        $entry = [PSCustomObject]@{
            KBArticleID = $KBArticleID
            Title = $Title
            DateBlocked = (Get-Date).ToString('o')
            BlockedBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        
        # Avoid duplicates
        $existing = $blocklist.BlockedKBs | Where-Object { $_.KBArticleID -eq $KBArticleID }
        if (-not $existing) {
            $blocklist.BlockedKBs = @($blocklist.BlockedKBs) + $entry
        }
    }
    
    if ($DriverInf) {
        if ($blocklist.BlockedDrivers -notcontains $DriverInf) {
            $blocklist.BlockedDrivers = @($blocklist.BlockedDrivers) + $DriverInf
        }
    }
    
    Save-LocalBlocklist -Blocklist $blocklist
}

function Remove-FromLocalBlocklist {
    param(
        [string]$KBArticleID,
        [string]$DriverInf
    )
    
    $blocklist = Get-LocalBlocklist
    
    if ($KBArticleID) {
        $blocklist.BlockedKBs = @($blocklist.BlockedKBs | Where-Object { $_.KBArticleID -ne $KBArticleID } | Where-Object { $null -ne $_ })
    }
    
    if ($DriverInf) {
        $blocklist.BlockedDrivers = @($blocklist.BlockedDrivers | Where-Object { $_ -ne $DriverInf } | Where-Object { $null -ne $_ })
    }
    
    Save-LocalBlocklist -Blocklist $blocklist
}

#endregion

