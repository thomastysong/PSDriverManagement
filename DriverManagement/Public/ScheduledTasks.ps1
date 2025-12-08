#Requires -Version 5.1

<#
.SYNOPSIS
    Scheduled task management for DriverManagement module
#>

function Register-DriverManagementTask {
    <#
    .SYNOPSIS
        Registers a scheduled task for driver management
    .DESCRIPTION
        Creates scheduled tasks for various trigger types
    .PARAMETER TaskName
        Name of the scheduled task
    .PARAMETER TriggerType
        Type of trigger: Daily, Weekly, AtStartup, EventDriven
    .PARAMETER Time
        Time to run for Daily/Weekly triggers
    .PARAMETER Mode
        Driver management mode: Individual or FullPack
    .PARAMETER UpdateTypes
        Types of updates to apply
    .EXAMPLE
        Register-DriverManagementTask -TriggerType Weekly -Time "03:00"
    .EXAMPLE
        Register-DriverManagementTask -TriggerType EventDriven -TaskName "DriverFailure-Remediation"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$TaskName = "Uber-DriverManagement",
        
        [Parameter()]
        [ValidateSet('Daily', 'Weekly', 'AtStartup', 'EventDriven')]
        [string]$TriggerType = 'Weekly',
        
        [Parameter()]
        [string]$Time = "03:00",
        
        [Parameter()]
        [ValidateSet('Individual', 'FullPack')]
        [string]$Mode = 'Individual',
        
        [Parameter()]
        [ValidateSet('Driver', 'BIOS', 'Firmware', 'All')]
        [string[]]$UpdateTypes = @('Driver')
    )
    
    Assert-Elevation -Operation "Registering scheduled task"
    
    # Build the command
    $modulePath = $script:ModuleRoot
    $updateTypesStr = $UpdateTypes -join ','
    
    $command = @"
Import-Module '$modulePath\DriverManagement.psd1' -Force
Invoke-DriverManagement -Mode $Mode -UpdateTypes $updateTypesStr -Verbose
"@
    
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    
    # Create trigger based on type
    $trigger = switch ($TriggerType) {
        'Daily' {
            $triggerTime = [datetime]::Parse($Time)
            New-ScheduledTaskTrigger -Daily -At $triggerTime -RandomDelay "02:00:00"
        }
        'Weekly' {
            $triggerTime = [datetime]::Parse($Time)
            New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At $triggerTime -RandomDelay "04:00:00"
        }
        'AtStartup' {
            New-ScheduledTaskTrigger -AtStartup -RandomDelay "00:15:00"
        }
        'EventDriven' {
            # Create event-based trigger for driver failures (Kernel-PnP Event 219)
            $eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $eventTrigger = New-CimInstance -CimClass $eventClass -ClientOnly
            $eventTrigger.Subscription = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-PnP'] and EventID=219]]</Select>
  </Query>
</QueryList>
"@
            $eventTrigger.Delay = 'PT10M'  # 10 minute delay
            $eventTrigger.Enabled = $true
            $eventTrigger
        }
    }
    
    # Run as SYSTEM with highest privileges
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" `
        -LogonType ServiceAccount -RunLevel Highest
    
    # Task settings for reliability
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 15) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
        -Hidden
    
    if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task")) {
        # Unregister existing task if present
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        
        # Register new task
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
        
        Write-DriverLog -Message "Registered scheduled task: $TaskName ($TriggerType)" -Severity Info `
            -Context @{ TaskName = $TaskName; TriggerType = $TriggerType; Mode = $Mode }
        
        return Get-ScheduledTask -TaskName $TaskName
    }
}

function Unregister-DriverManagementTask {
    <#
    .SYNOPSIS
        Removes driver management scheduled tasks
    .DESCRIPTION
        Unregisters scheduled tasks created by this module
    .PARAMETER TaskName
        Name of the task to remove, or * for all
    .EXAMPLE
        Unregister-DriverManagementTask
    .EXAMPLE
        Unregister-DriverManagementTask -TaskName "Uber-DriverManagement-EventDriven"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$TaskName = "Uber-DriverManagement"
    )
    
    Assert-Elevation -Operation "Unregistering scheduled task"
    
    if ($TaskName -eq '*') {
        $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -like "Uber-DriverManagement*" }
    }
    else {
        $tasks = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    
    foreach ($task in $tasks) {
        if ($PSCmdlet.ShouldProcess($task.TaskName, "Unregister scheduled task")) {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
            Write-DriverLog -Message "Unregistered scheduled task: $($task.TaskName)" -Severity Info
        }
    }
}

function Get-DriverManagementTask {
    <#
    .SYNOPSIS
        Gets driver management scheduled tasks
    .EXAMPLE
        Get-DriverManagementTask
    #>
    [CmdletBinding()]
    param()
    
    Get-ScheduledTask | Where-Object { $_.TaskName -like "Uber-DriverManagement*" } |
        Select-Object TaskName, State, 
            @{N='NextRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName).NextRunTime}},
            @{N='LastRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName).LastRunTime}},
            @{N='LastResult';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName).LastTaskResult}}
}
