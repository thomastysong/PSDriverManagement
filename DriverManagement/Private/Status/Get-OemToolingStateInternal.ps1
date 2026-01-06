#Requires -Version 5.1

function Get-OemToolingStateInternal {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $mfr = ($cs.Manufacturer | ForEach-Object { $_.Trim() })

    $detected = if ($mfr -match 'Dell') { 'Dell' } elseif ($mfr -match 'Lenovo') { 'Lenovo' } else { 'Other' }

    # Dell DCU detection
    $dcuPaths = @(
        Join-Path $env:ProgramFiles 'Dell\CommandUpdate\dcu-cli.exe'
        Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }

    $dcuRegPaths = @(
        'HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate'
        'HKLM:\SOFTWARE\DELL\CommandUpdate'
    )
    $dcuVersion = $null
    foreach ($rp in $dcuRegPaths) {
        if (Test-Path $rp) {
            try {
                $r = Get-ItemProperty -Path $rp -ErrorAction Stop
                $dcuVersion = if ($r.Version) { $r.Version } elseif ($r.ProductVersion) { $r.ProductVersion } else { $null }
                if ($dcuVersion) { break }
            }
            catch { }
        }
    }

    $dcuLogDirs = @(
        Join-Path $env:ProgramData 'Dell\CommandUpdate\Log'
        Join-Path $env:ProgramData 'Dell\UpdateService\Log'
        Join-Path $env:ProgramData 'Dell\Logs'
    ) | Where-Object { try { Test-Path $_ -ErrorAction Stop } catch { $false } }

    # Lenovo tooling detection (enhanced to match Dell's detail level)
    $lenovoThinInstaller = Join-Path ${env:ProgramFiles(x86)} 'Lenovo\ThinInstaller\ThinInstaller.exe'
    $lenovoSystemUpdate = Join-Path ${env:ProgramFiles(x86)} 'Lenovo\System Update\tvsu.exe'

    # LSUClient module - get version info if present
    $lsuClientModule = Get-Module -ListAvailable -Name LSUClient -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    $lsuClientPresent = [bool]$lsuClientModule
    $lsuClientVersion = $null
    $lsuClientPath = $null
    if ($lsuClientModule) {
        try { $lsuClientVersion = $lsuClientModule.Version.ToString() } catch { }
        try { $lsuClientPath = $lsuClientModule.ModuleBase } catch { }
    }

    # Thin Installer - get version if present
    $thinInstallerPresent = Test-Path $lenovoThinInstaller -ErrorAction SilentlyContinue
    $thinInstallerVersion = $null
    if ($thinInstallerPresent) {
        try { $thinInstallerVersion = (Get-Item $lenovoThinInstaller -ErrorAction SilentlyContinue).VersionInfo.FileVersion } catch { }
    }

    # System Update - get version if present
    $systemUpdatePresent = Test-Path $lenovoSystemUpdate -ErrorAction SilentlyContinue
    $systemUpdateVersion = $null
    if ($systemUpdatePresent) {
        try { $systemUpdateVersion = (Get-Item $lenovoSystemUpdate -ErrorAction SilentlyContinue).VersionInfo.FileVersion } catch { }
    }

    $lenovoLogDirs = @(
        Join-Path $env:ProgramData 'Lenovo\SystemUpdate\logs'
        Join-Path $env:ProgramData 'Lenovo\System Update\logs'
        Join-Path $env:ProgramData 'Lenovo\Vantage\Logs'
        Join-Path $env:ProgramData 'Lenovo\ThinInstaller\logs'
    ) | Where-Object { try { Test-Path $_ -ErrorAction Stop } catch { $false } }

    return [pscustomobject]@{
        Detected = $detected
        Dell = [pscustomobject]@{
            DCU = [pscustomobject]@{
                Present = ((@($dcuPaths).Count -gt 0) -or [bool]$dcuVersion)
                Version = $dcuVersion
                CliPath = ($dcuPaths | Select-Object -First 1)
                LogDirs = @($dcuLogDirs)
            }
        }
        Lenovo = [pscustomobject]@{
            # Backward compatible booleans
            LSUClientModulePresent = $lsuClientPresent
            ThinInstallerPresent = $thinInstallerPresent
            SystemUpdatePresent = $systemUpdatePresent
            # Enhanced: detailed tool info (matches Dell's DCU structure)
            LSUClient = [pscustomobject]@{
                Present = $lsuClientPresent
                Version = $lsuClientVersion
                ModulePath = $lsuClientPath
            }
            ThinInstaller = [pscustomobject]@{
                Present = $thinInstallerPresent
                Version = $thinInstallerVersion
                ExePath = if ($thinInstallerPresent) { $lenovoThinInstaller } else { $null }
            }
            SystemUpdate = [pscustomobject]@{
                Present = $systemUpdatePresent
                Version = $systemUpdateVersion
                ExePath = if ($systemUpdatePresent) { $lenovoSystemUpdate } else { $null }
            }
            LogDirs = @($lenovoLogDirs)
        }
    }
}


