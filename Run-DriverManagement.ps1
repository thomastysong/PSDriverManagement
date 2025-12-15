#Requires -Version 5.1
<#
.SYNOPSIS
  Simple bootstrapper: install/update DriverManagement and run updates.

.DESCRIPTION
  Intended for non-technical users.

  - Prompts for UAC (admin) if needed
  - Installs/updates DriverManagement from PowerShell Gallery
  - Runs Invoke-DriverManagement with Windows Updates included
  - Fully non-interactive (no Y/N prompts), and does not reboot by default

.EXAMPLE
  irm https://raw.githubusercontent.com/thomastysong/PSDriverManagement/main/Run-DriverManagement.ps1 | iex
#>

[CmdletBinding()]
param(
  [Parameter()]
  [switch]$IncludeWindowsUpdates = $true,

  [Parameter()]
  [switch]$NoReboot = $true,

  [Parameter()]
  [switch]$Force,

  [Parameter()]
  [switch]$NoElevate,

  # Used for self-elevation when running via "irm | iex"
  [Parameter()]
  [string]$SelfUrl = 'https://raw.githubusercontent.com/thomastysong/PSDriverManagement/main/Run-DriverManagement.ps1'
)

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch { return $false }
}

if (-not $NoElevate -and -not (Test-IsAdmin)) {
  Write-Host "Admin rights are required. A UAC prompt will appear..." -ForegroundColor Yellow

  $cmd = "irm '$SelfUrl' | iex"
  Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-Command", $cmd
  ) | Out-Null
  return
}

try {
  # TLS 1.2 for older Windows / PS 5.1
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  # Avoid PSGallery trust prompt (best-effort)
  try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}

  # Ensure NuGet provider exists (best-effort)
  try { Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null } catch {}

  if ($Force) {
    Install-Module DriverManagement -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
  }
  else {
    if (-not (Get-Module -ListAvailable -Name DriverManagement)) {
      Install-Module DriverManagement -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
    }
    else {
      try { Update-Module DriverManagement -Force -ErrorAction Stop } catch { }
    }
  }

  Remove-Module DriverManagement -Force -ErrorAction SilentlyContinue
  Import-Module DriverManagement -Force -ErrorAction Stop

  $idmParams = @{}
  if ($IncludeWindowsUpdates) { $idmParams.IncludeWindowsUpdates = $true }
  if ($NoReboot) { $idmParams.NoReboot = $true }

  Write-Host "Running updates (this may take a while)..." -ForegroundColor Cyan
  Invoke-DriverManagement @idmParams
}
catch {
  Write-Host ("Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
  throw
}


