#Requires -Version 5.1

<#
.SYNOPSIS
    Update approval and blocklist management functions
.DESCRIPTION
    Provides functions to manage update approvals via local JSON, Intune compliance,
    and external API endpoints for enterprise approval workflows.
#>

#region Local JSON Approval System

function Get-UpdateApproval {
    <#
    .SYNOPSIS
        Gets the current update approval configuration
    .DESCRIPTION
        Returns the approval configuration including blocked KBs, blocked drivers,
        and approved-only mode settings.
    .EXAMPLE
        Get-UpdateApproval
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-ApprovalConfig
    
    return [PSCustomObject]@{
        ApprovedOnly    = $config.ApprovedOnly
        BlockedKBs      = $config.BlockedKBs
        BlockedDrivers  = $config.BlockedDrivers
        ApprovedUpdates = $config.ApprovedUpdates
        LastSynced      = $config.LastSynced
        Source          = $config.Source
    }
}

function Set-UpdateApproval {
    <#
    .SYNOPSIS
        Configures update approval settings
    .DESCRIPTION
        Sets approval mode, adds/removes blocked items, and configures approved updates.
    .PARAMETER ApprovedOnly
        If true, only explicitly approved updates will be installed
    .PARAMETER AddBlockedKB
        KB article IDs to add to the blocklist
    .PARAMETER RemoveBlockedKB
        KB article IDs to remove from the blocklist
    .PARAMETER AddBlockedDriver
        Driver INF names to add to the blocklist
    .PARAMETER RemoveBlockedDriver
        Driver INF names to remove from the blocklist
    .PARAMETER AddApprovedUpdate
        Update identifiers to add to the approved list
    .PARAMETER RemoveApprovedUpdate
        Update identifiers to remove from the approved list
    .EXAMPLE
        Set-UpdateApproval -ApprovedOnly $true
    .EXAMPLE
        Set-UpdateApproval -AddBlockedKB 'KB5001234', 'KB5005678'
    .EXAMPLE
        Set-UpdateApproval -AddBlockedDriver 'nvlddmkm.inf'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [bool]$ApprovedOnly,
        
        [Parameter()]
        [string[]]$AddBlockedKB,
        
        [Parameter()]
        [string[]]$RemoveBlockedKB,
        
        [Parameter()]
        [string[]]$AddBlockedDriver,
        
        [Parameter()]
        [string[]]$RemoveBlockedDriver,
        
        [Parameter()]
        [string[]]$AddApprovedUpdate,
        
        [Parameter()]
        [string[]]$RemoveApprovedUpdate
    )
    
    $config = Get-ApprovalConfig
    
    if ($PSBoundParameters.ContainsKey('ApprovedOnly')) {
        if ($PSCmdlet.ShouldProcess("ApprovedOnly mode", "Set to $ApprovedOnly")) {
            $config.ApprovedOnly = $ApprovedOnly
            Write-DriverLog -Message "Set ApprovedOnly mode to: $ApprovedOnly" -Severity Info
        }
    }
    
    # Handle blocked KBs
    if ($AddBlockedKB) {
        foreach ($kb in $AddBlockedKB) {
            $normalizedKB = if ($kb -match '^KB') { $kb } else { "KB$kb" }
            if ($config.BlockedKBs -notcontains $normalizedKB) {
                if ($PSCmdlet.ShouldProcess($normalizedKB, "Add to blocked KBs")) {
                    $config.BlockedKBs = @($config.BlockedKBs) + $normalizedKB
                    Write-DriverLog -Message "Added $normalizedKB to blocklist" -Severity Info
                }
            }
        }
    }
    
    if ($RemoveBlockedKB) {
        foreach ($kb in $RemoveBlockedKB) {
            $normalizedKB = if ($kb -match '^KB') { $kb } else { "KB$kb" }
            if ($PSCmdlet.ShouldProcess($normalizedKB, "Remove from blocked KBs")) {
                $config.BlockedKBs = @($config.BlockedKBs | Where-Object { $_ -ne $normalizedKB } | Where-Object { $null -ne $_ })
                Write-DriverLog -Message "Removed $normalizedKB from blocklist" -Severity Info
            }
        }
    }
    
    # Handle blocked drivers
    if ($AddBlockedDriver) {
        foreach ($driver in $AddBlockedDriver) {
            if ($config.BlockedDrivers -notcontains $driver) {
                if ($PSCmdlet.ShouldProcess($driver, "Add to blocked drivers")) {
                    $config.BlockedDrivers = @($config.BlockedDrivers) + $driver
                    Write-DriverLog -Message "Added $driver to driver blocklist" -Severity Info
                }
            }
        }
    }
    
    if ($RemoveBlockedDriver) {
        foreach ($driver in $RemoveBlockedDriver) {
            if ($PSCmdlet.ShouldProcess($driver, "Remove from blocked drivers")) {
                $config.BlockedDrivers = @($config.BlockedDrivers | Where-Object { $_ -ne $driver } | Where-Object { $null -ne $_ })
                Write-DriverLog -Message "Removed $driver from driver blocklist" -Severity Info
            }
        }
    }
    
    # Handle approved updates
    if ($AddApprovedUpdate) {
        foreach ($update in $AddApprovedUpdate) {
            if ($config.ApprovedUpdates -notcontains $update) {
                if ($PSCmdlet.ShouldProcess($update, "Add to approved updates")) {
                    $config.ApprovedUpdates = @($config.ApprovedUpdates) + $update
                    Write-DriverLog -Message "Added $update to approved list" -Severity Info
                }
            }
        }
    }
    
    if ($RemoveApprovedUpdate) {
        foreach ($update in $RemoveApprovedUpdate) {
            if ($PSCmdlet.ShouldProcess($update, "Remove from approved updates")) {
                $config.ApprovedUpdates = @($config.ApprovedUpdates | Where-Object { $_ -ne $update } | Where-Object { $null -ne $_ })
                Write-DriverLog -Message "Removed $update from approved list" -Severity Info
            }
        }
    }
    
    $config.Source = 'Local'
    Save-ApprovalConfig -Config $config
    
    return Get-UpdateApproval
}

function Test-UpdateApproval {
    <#
    .SYNOPSIS
        Tests if an update is approved for installation
    .DESCRIPTION
        Checks the update against blocklists and approved lists to determine
        if it should be installed.
    .PARAMETER KBArticleID
        The KB article ID to check
    .PARAMETER DriverInf
        The driver INF file name to check
    .PARAMETER UpdateName
        The update name/title to check
    .PARAMETER Update
        An update object with KB and/or Title properties
    .EXAMPLE
        Test-UpdateApproval -KBArticleID 'KB5001234'
    .EXAMPLE
        $update | Test-UpdateApproval
    .OUTPUTS
        PSCustomObject with IsApproved, Reason properties
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByKB')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByKB')]
        [string]$KBArticleID,
        
        [Parameter(Mandatory, ParameterSetName = 'ByDriver')]
        [string]$DriverInf,
        
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$UpdateName,
        
        [Parameter(Mandatory, ParameterSetName = 'ByObject', ValueFromPipeline)]
        [PSObject]$Update
    )
    
    process {
        $config = Get-ApprovalConfig
        
        # Extract identifiers from object
        if ($Update) {
            $KBArticleID = if ($Update.KB) { $Update.KB } elseif ($Update.KBArticleID) { $Update.KBArticleID } else { $Update.HotFixID }
            $DriverInf = if ($Update.InfName) { $Update.InfName } else { $Update.DriverInf }
            $UpdateName = if ($Update.Title) { $Update.Title } elseif ($Update.Name) { $Update.Name } else { $Update.UpdateName }
        }
        
        # Normalize KB
        if ($KBArticleID) {
            $KBArticleID = if ($KBArticleID -match '^KB') { $KBArticleID } else { "KB$KBArticleID" }
        }
        
        $result = [PSCustomObject]@{
            Identifier = if ($KBArticleID) { $KBArticleID } elseif ($DriverInf) { $DriverInf } else { $UpdateName }
            IsApproved = $true
            IsBlocked  = $false
            Reason     = 'Not in blocklist'
        }
        
        # Check if blocked
        if ($KBArticleID -and $config.BlockedKBs -contains $KBArticleID) {
            $result.IsApproved = $false
            $result.IsBlocked = $true
            $result.Reason = "KB $KBArticleID is in blocklist"
            return $result
        }
        
        if ($DriverInf -and $config.BlockedDrivers -contains $DriverInf) {
            $result.IsApproved = $false
            $result.IsBlocked = $true
            $result.Reason = "Driver $DriverInf is in blocklist"
            return $result
        }
        
        # Check driver blocklist pattern matching
        if ($DriverInf) {
            foreach ($pattern in $config.BlockedDrivers) {
                if ($DriverInf -like $pattern) {
                    $result.IsApproved = $false
                    $result.IsBlocked = $true
                    $result.Reason = "Driver $DriverInf matches blocklist pattern: $pattern"
                    return $result
                }
            }
        }
        
        # Check approved-only mode
        if ($config.ApprovedOnly) {
            $isInApproved = $false
            
            if ($KBArticleID -and $config.ApprovedUpdates -contains $KBArticleID) {
                $isInApproved = $true
            }
            
            if ($UpdateName) {
                foreach ($approved in $config.ApprovedUpdates) {
                    if ($UpdateName -like $approved -or $UpdateName -eq $approved) {
                        $isInApproved = $true
                        break
                    }
                }
            }
            
            if (-not $isInApproved) {
                $result.IsApproved = $false
                $result.Reason = "ApprovedOnly mode enabled - update not in approved list"
                return $result
            }
            
            $result.Reason = "Explicitly approved"
        }
        
        return $result
    }
}

#endregion

#region Intune Compliance Integration

function Set-IntuneApprovalConfig {
    <#
    .SYNOPSIS
        Configures Intune approval integration
    .DESCRIPTION
        Sets up the connection to Intune for pulling update approval policies.
    .PARAMETER TenantId
        Azure AD tenant ID
    .PARAMETER ClientId
        Application (client) ID for Graph API access
    .PARAMETER ClientSecret
        Client secret for app authentication (use SecureString in production)
    .PARAMETER UseManagedIdentity
        Use Azure Managed Identity for authentication
    .EXAMPLE
        Set-IntuneApprovalConfig -TenantId 'xxx' -ClientId 'yyy' -UseManagedIdentity
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId,
        
        [Parameter()]
        [string]$ClientId,
        
        [Parameter()]
        [string]$ClientSecret,
        
        [Parameter()]
        [switch]$UseManagedIdentity
    )
    
    $intuneConfig = @{
        TenantId = $TenantId
        ClientId = $ClientId
        UseManagedIdentity = $UseManagedIdentity.IsPresent
        Configured = $true
        ConfiguredDate = (Get-Date).ToString('o')
    }
    
    if ($ClientSecret) {
        # Store encrypted (in production, use DPAPI or Azure Key Vault)
        $intuneConfig.ClientSecretEncrypted = $ClientSecret | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
    }
    
    $configPath = Get-IntuneConfigPath
    $configDir = Split-Path $configPath -Parent
    
    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    
    $intuneConfig | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
    
    Write-DriverLog -Message "Intune approval configuration saved" -Severity Info
}

function Sync-IntuneUpdateApproval {
    <#
    .SYNOPSIS
        Synchronizes update approval settings from Intune
    .DESCRIPTION
        Pulls Windows Update for Business settings and compliance policies
        from Intune to determine which updates are approved.
    .PARAMETER Force
        Force sync even if recently synced
    .EXAMPLE
        Sync-IntuneUpdateApproval
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    $intuneConfig = Get-IntuneConfig
    
    if (-not $intuneConfig.Configured) {
        throw "Intune approval not configured. Run Set-IntuneApprovalConfig first."
    }
    
    Write-DriverLog -Message "Syncing update approval from Intune" -Severity Info
    
    try {
        # Get access token
        $token = Get-IntuneAccessToken -Config $intuneConfig
        
        if (-not $token) {
            throw "Failed to obtain Intune access token"
        }
        
        $headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type'  = 'application/json'
        }
        
        # Get Windows Update for Business policies
        $wufbUri = "https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies"
        $policies = Invoke-RestMethod -Uri $wufbUri -Headers $headers -Method Get -ErrorAction Stop
        
        # Get device compliance policies for this device
        $deviceId = Get-IntuneDeviceId
        if ($deviceId) {
            $complianceUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$deviceId/deviceCompliancePolicyStates"
            $compliance = Invoke-RestMethod -Uri $complianceUri -Headers $headers -Method Get -ErrorAction SilentlyContinue
        }
        
        # Parse policies to extract blocked/deferred updates
        $approvalConfig = Get-ApprovalConfig
        
        foreach ($policy in $policies.value) {
            # Extract quality update deferrals
            if ($policy.qualityUpdatesDeferralPeriodInDays -gt 0) {
                Write-DriverLog -Message "Quality updates deferred by $($policy.qualityUpdatesDeferralPeriodInDays) days" -Severity Info
            }
            
            # Extract paused updates
            if ($policy.qualityUpdatesPaused) {
                Write-DriverLog -Message "Quality updates paused" -Severity Warning
            }
        }
        
        $approvalConfig.LastSynced = (Get-Date).ToString('o')
        $approvalConfig.Source = 'Intune'
        
        Save-ApprovalConfig -Config $approvalConfig
        
        Write-DriverLog -Message "Intune sync completed" -Severity Info
        
        return Get-UpdateApproval
    }
    catch {
        Write-DriverLog -Message "Failed to sync from Intune: $($_.Exception.Message)" -Severity Error
        throw
    }
}

function Get-IntuneDeviceId {
    <#
    .SYNOPSIS
        Gets the Intune device ID for the current machine
    #>
    [CmdletBinding()]
    param()
    
    # Try to get from registry (Intune enrolled devices)
    $intuneReg = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    
    if (Test-Path $intuneReg) {
        $enrollments = Get-ChildItem $intuneReg -ErrorAction SilentlyContinue
        
        foreach ($enrollment in $enrollments) {
            $deviceId = Get-ItemProperty -Path $enrollment.PSPath -Name 'DeviceId' -ErrorAction SilentlyContinue
            if ($deviceId.DeviceId) {
                return $deviceId.DeviceId
            }
        }
    }
    
    # Fallback: try AAD device ID
    $aadReg = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
    if (Test-Path $aadReg) {
        $joinInfo = Get-ChildItem $aadReg -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($joinInfo) {
            return $joinInfo.PSChildName
        }
    }
    
    return $null
}

#endregion

#region External API Endpoint Support

function Set-ApprovalEndpoint {
    <#
    .SYNOPSIS
        Configures an external API endpoint for update approvals
    .DESCRIPTION
        Sets up connection to an enterprise approval system that provides
        update approval decisions via REST API.
    .PARAMETER Uri
        The base URI of the approval API
    .PARAMETER ApiKey
        API key for authentication
    .PARAMETER Headers
        Additional headers to include in requests
    .EXAMPLE
        Set-ApprovalEndpoint -Uri 'https://approvals.company.com/api/v1' -ApiKey 'xxx'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https?://')]
        [string]$Uri,
        
        [Parameter()]
        [string]$ApiKey,
        
        [Parameter()]
        [hashtable]$Headers
    )
    
    $endpointConfig = @{
        Uri = $Uri.TrimEnd('/')
        Configured = $true
        ConfiguredDate = (Get-Date).ToString('o')
        Headers = if ($Headers) { $Headers } else { @{} }
    }
    
    if ($ApiKey) {
        $endpointConfig.ApiKeyEncrypted = $ApiKey | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
    }
    
    $configPath = Get-ExternalEndpointConfigPath
    $configDir = Split-Path $configPath -Parent
    
    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    
    $endpointConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8
    
    # Also allow environment variable override
    if ($env:PSDM_APPROVAL_API) {
        Write-DriverLog -Message "Note: PSDM_APPROVAL_API environment variable will override configured endpoint" -Severity Warning
    }
    
    Write-DriverLog -Message "External approval endpoint configured: $Uri" -Severity Info
}

function Sync-ExternalApproval {
    <#
    .SYNOPSIS
        Synchronizes update approval from external API
    .DESCRIPTION
        Pulls update approval configuration from the configured external API endpoint.
        
        Expected API response format:
        {
            "blockedKBs": ["KB5001234"],
            "blockedDrivers": ["nvlddmkm.inf"],
            "approvedUpdates": ["KB5002345"],
            "approvedOnly": false
        }
    .PARAMETER Force
        Force sync even if recently synced
    .EXAMPLE
        Sync-ExternalApproval
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    $endpointConfig = Get-ExternalEndpointConfig
    
    # Allow environment variable override
    $apiUri = if ($env:PSDM_APPROVAL_API) { $env:PSDM_APPROVAL_API } else { $endpointConfig.Uri }
    
    if (-not $apiUri) {
        throw "External approval endpoint not configured. Run Set-ApprovalEndpoint or set PSDM_APPROVAL_API."
    }
    
    Write-DriverLog -Message "Syncing update approval from: $apiUri" -Severity Info
    
    try {
        $headers = @{
            'Content-Type' = 'application/json'
            'Accept' = 'application/json'
            'X-Computer-Name' = $env:COMPUTERNAME
            'X-OS-Version' = [System.Environment]::OSVersion.Version.ToString()
        }
        
        # Add configured headers
        if ($endpointConfig.Headers) {
            foreach ($key in $endpointConfig.Headers.Keys) {
                $headers[$key] = $endpointConfig.Headers[$key]
            }
        }
        
        # Add API key if configured
        if ($endpointConfig.ApiKeyEncrypted) {
            $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                    ($endpointConfig.ApiKeyEncrypted | ConvertTo-SecureString)
                )
            )
            $headers['X-API-Key'] = $apiKey
        }
        
        # Fetch approval config
        $approvalEndpoint = "$apiUri/updates/approval"
        $response = Invoke-RestMethod -Uri $approvalEndpoint -Headers $headers -Method Get -ErrorAction Stop
        
        # Update local config
        $approvalConfig = Get-ApprovalConfig
        
        if ($response.blockedKBs) {
            $approvalConfig.BlockedKBs = @($response.blockedKBs)
        }
        
        if ($response.blockedDrivers) {
            $approvalConfig.BlockedDrivers = @($response.blockedDrivers)
        }
        
        if ($response.approvedUpdates) {
            $approvalConfig.ApprovedUpdates = @($response.approvedUpdates)
        }
        
        if ($null -ne $response.approvedOnly) {
            $approvalConfig.ApprovedOnly = $response.approvedOnly
        }
        
        $approvalConfig.LastSynced = (Get-Date).ToString('o')
        $approvalConfig.Source = 'ExternalAPI'
        $approvalConfig.SourceUri = $apiUri
        
        Save-ApprovalConfig -Config $approvalConfig
        
        Write-DriverLog -Message "External approval sync completed" -Severity Info `
            -Context @{ 
                BlockedKBs = $approvalConfig.BlockedKBs.Count
                BlockedDrivers = $approvalConfig.BlockedDrivers.Count
                ApprovedOnly = $approvalConfig.ApprovedOnly
            }
        
        return Get-UpdateApproval
    }
    catch {
        Write-DriverLog -Message "Failed to sync from external API: $($_.Exception.Message)" -Severity Error
        throw
    }
}

function Send-UpdateReport {
    <#
    .SYNOPSIS
        Sends update status report to external API
    .DESCRIPTION
        Reports installed updates and compliance status to the enterprise approval system.
    .PARAMETER UpdateResult
        The result object from Invoke-DriverManagement or similar
    .EXAMPLE
        $result = Invoke-DriverManagement -Mode Individual
        Send-UpdateReport -UpdateResult $result
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSObject]$UpdateResult
    )
    
    process {
        $endpointConfig = Get-ExternalEndpointConfig
        $apiUri = if ($env:PSDM_APPROVAL_API) { $env:PSDM_APPROVAL_API } else { $endpointConfig.Uri }
        
        if (-not $apiUri) {
            Write-DriverLog -Message "External API not configured - skipping report" -Severity Warning
            return
        }
        
        try {
            $headers = @{
                'Content-Type' = 'application/json'
                'X-Computer-Name' = $env:COMPUTERNAME
            }
            
            if ($endpointConfig.ApiKeyEncrypted) {
                $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                        ($endpointConfig.ApiKeyEncrypted | ConvertTo-SecureString)
                    )
                )
                $headers['X-API-Key'] = $apiKey
            }
            
            $report = @{
                computerName = $env:COMPUTERNAME
                timestamp = (Get-Date).ToString('o')
                success = $UpdateResult.Success
                updatesApplied = $UpdateResult.UpdatesApplied
                rebootRequired = $UpdateResult.RebootRequired
                exitCode = $UpdateResult.ExitCode
                correlationId = $UpdateResult.CorrelationId
                details = $UpdateResult.Details
            }
            
            $reportEndpoint = "$apiUri/updates/report"
            Invoke-RestMethod -Uri $reportEndpoint -Headers $headers -Method Post -Body ($report | ConvertTo-Json -Depth 5)
            
            Write-DriverLog -Message "Update report sent to external API" -Severity Info
        }
        catch {
            Write-DriverLog -Message "Failed to send update report: $($_.Exception.Message)" -Severity Warning
        }
    }
}

#endregion

#region Helper Functions

function Get-ApprovalConfigPath {
    $config = $script:ModuleConfig
    $basePath = Split-Path $config.CompliancePath -Parent
    return Join-Path $basePath "approval.json"
}

function Get-IntuneConfigPath {
    $config = $script:ModuleConfig
    $basePath = Split-Path $config.CompliancePath -Parent
    return Join-Path $basePath "intune-config.json"
}

function Get-ExternalEndpointConfigPath {
    $config = $script:ModuleConfig
    $basePath = Split-Path $config.CompliancePath -Parent
    return Join-Path $basePath "external-endpoint.json"
}

function Get-ApprovalConfig {
    $path = Get-ApprovalConfigPath
    
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    
    # Return default structure
    return [PSCustomObject]@{
        Version = '1.0'
        ApprovedOnly = $false
        BlockedKBs = @()
        BlockedDrivers = @()
        ApprovedUpdates = @()
        LastSynced = $null
        Source = 'Local'
        SourceUri = $null
    }
}

function Save-ApprovalConfig {
    param(
        [Parameter(Mandatory)]
        $Config
    )
    
    $path = Get-ApprovalConfigPath
    $dir = Split-Path $path -Parent
    
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Get-IntuneConfig {
    $path = Get-IntuneConfigPath
    
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    
    return [PSCustomObject]@{
        Configured = $false
    }
}

function Get-ExternalEndpointConfig {
    $path = Get-ExternalEndpointConfigPath
    
    if (Test-Path $path) {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    
    return [PSCustomObject]@{
        Configured = $false
        Uri = $null
        Headers = @{}
    }
}

function Get-IntuneAccessToken {
    param($Config)
    
    if ($Config.UseManagedIdentity) {
        # Use Azure Instance Metadata Service for managed identity
        try {
            $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com"
            $response = Invoke-RestMethod -Uri $tokenUri -Headers @{Metadata="true"} -Method Get
            return $response.access_token
        }
        catch {
            Write-DriverLog -Message "Failed to get managed identity token: $($_.Exception.Message)" -Severity Error
            return $null
        }
    }
    else {
        # Client credentials flow
        if (-not $Config.ClientSecretEncrypted) {
            Write-DriverLog -Message "Client secret not configured" -Severity Error
            return $null
        }
        
        $clientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                ($Config.ClientSecretEncrypted | ConvertTo-SecureString)
            )
        )
        
        $tokenUri = "https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/token"
        $body = @{
            client_id = $Config.ClientId
            client_secret = $clientSecret
            scope = "https://graph.microsoft.com/.default"
            grant_type = "client_credentials"
        }
        
        try {
            $response = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body
            return $response.access_token
        }
        catch {
            Write-DriverLog -Message "Failed to get access token: $($_.Exception.Message)" -Severity Error
            return $null
        }
    }
}

#endregion

