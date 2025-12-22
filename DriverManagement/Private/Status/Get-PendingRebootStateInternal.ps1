#Requires -Version 5.1

function Get-PendingRebootStateInternal {
    [CmdletBinding()]
    param()

    $pending = [ordered]@{}

    $pending.CBSRebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $pending.WURebootRequired = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

    $pfr = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $pending.PendingFileRenameOperationsCount = if ($pfr) { @($pfr).Count } else { 0 }

    $cn = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $acn = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $pending.PendingComputerRename = ($cn -and $acn -and ($cn -ne $acn))

    $pending.IsRebootPending = [bool](
        $pending.CBSRebootPending -or
        $pending.WURebootRequired -or
        $pending.PendingComputerRename -or
        ($pending.PendingFileRenameOperationsCount -gt 0)
    )

    return [pscustomobject]$pending
}


