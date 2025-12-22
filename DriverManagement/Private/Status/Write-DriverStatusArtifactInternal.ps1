#Requires -Version 5.1

function Write-DriverStatusArtifactInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Report,

        [Parameter()]
        [string]$OutputPath
    )

    $logDir = $script:ModuleConfig.LogPath
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $cid = if ($script:CorrelationId) { $script:CorrelationId } else { ([guid]::NewGuid().ToString()) }
    $fileName = "DriverStatus_{0}_{1}.json" -f $ts, $cid
    $path = Join-Path $logDir $fileName

    try {
        $Report | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        $written = $true
        $err = $null
    }
    catch {
        $written = $false
        $err = $_.Exception.Message
    }

    # Optional copy to OutputPath
    $copy = $null
    if ($OutputPath) {
        try {
            if (-not (Test-Path $OutputPath)) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }
            $copyPath = Join-Path $OutputPath $fileName
            Copy-Item -Path $path -Destination $copyPath -Force -ErrorAction Stop
            $copy = [pscustomobject]@{ Written = $true; Path = $copyPath; Error = $null }
        }
        catch {
            $copy = [pscustomobject]@{ Written = $false; Path = $null; Error = $_.Exception.Message }
        }
    }

    return [pscustomobject]@{
        Written = $written
        Path = if ($written) { $path } else { $null }
        Error = $err
        Copy = $copy
    }
}


