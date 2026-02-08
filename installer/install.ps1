#Requires -Version 5.1
<#
.SYNOPSIS
    Install SuperViewer as a per-user image viewer with Windows file associations.

.DESCRIPTION
    Copies superviewer.exe to %LOCALAPPDATA%\SuperViewer\ and registers file
    associations under HKCU (no admin required). Opens Windows Settings so
    the user can set SuperViewer as the default app.

.PARAMETER ExePath
    Path to superviewer.exe. Defaults to target\release\superviewer.exe relative
    to the repository root (one level up from installer\).

.EXAMPLE
    .\install.ps1
    .\install.ps1 -ExePath "C:\path\to\superviewer.exe"
#>

param(
    [string]$ExePath
)

$ErrorActionPreference = "Stop"

# --- Locate exe ---
if (-not $ExePath) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # If running from within the repo, try the common location
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $ExePath = Join-Path $RepoRoot "target\release\superviewer.exe"
}

if (-not (Test-Path $ExePath)) {
    Write-Host "ERROR: superviewer.exe not found at: $ExePath" -ForegroundColor Red
    Write-Host "Build first:  cargo build --release" -ForegroundColor Yellow
    exit 1
}

$ExePath = (Resolve-Path $ExePath).Path
Write-Host "Source: $ExePath" -ForegroundColor Cyan

# --- Install directory ---
$InstallDir = Join-Path $env:LOCALAPPDATA "SuperViewer"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$InstalledExe = Join-Path $InstallDir "superviewer.exe"
Copy-Item -Path $ExePath -Destination $InstalledExe -Force
Write-Host "Installed: $InstalledExe" -ForegroundColor Green

# --- File extensions to associate ---
$Extensions = @(".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tiff", ".tif", ".gif", ".avif")

# --- Registry helpers ---
function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Value)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value
}

# --- ProgID ---
$ProgID = "SuperViewer.Image"
$ProgIDPath = "HKCU:\Software\Classes\$ProgID"

Set-RegValue -Path $ProgIDPath -Name "(Default)" -Value "SuperViewer Image"
Set-RegValue -Path "$ProgIDPath\DefaultIcon" -Name "(Default)" -Value "`"$InstalledExe`",0"
Set-RegValue -Path "$ProgIDPath\shell\open\command" -Name "(Default)" -Value "`"$InstalledExe`" `"%1`""

Write-Host "Registered ProgID: $ProgID" -ForegroundColor Green

# --- Application registration ---
$AppPath = "HKCU:\Software\Classes\Applications\superviewer.exe"
Set-RegValue -Path $AppPath -Name "FriendlyAppName" -Value "SuperViewer"
Set-RegValue -Path "$AppPath\DefaultIcon" -Name "(Default)" -Value "`"$InstalledExe`",0"
Set-RegValue -Path "$AppPath\shell\open\command" -Name "(Default)" -Value "`"$InstalledExe`" `"%1`""

# --- Supported file types (SupportedTypes) ---
$SupportedTypesPath = "$AppPath\SupportedTypes"
if (-not (Test-Path $SupportedTypesPath)) {
    New-Item -Path $SupportedTypesPath -Force | Out-Null
}
foreach ($ext in $Extensions) {
    Set-ItemProperty -Path $SupportedTypesPath -Name $ext -Value ""
}

# --- Per-extension OpenWithProgids ---
foreach ($ext in $Extensions) {
    $ExtPath = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    if (-not (Test-Path $ExtPath)) {
        New-Item -Path $ExtPath -Force | Out-Null
    }
    Set-ItemProperty -Path $ExtPath -Name $ProgID -Value ([byte[]]@())
}

Write-Host "Registered OpenWithProgids for: $($Extensions -join ', ')" -ForegroundColor Green

# --- Capabilities ---
$CapPath = "HKCU:\Software\SuperViewer\Capabilities"
Set-RegValue -Path $CapPath -Name "ApplicationName" -Value "SuperViewer"
Set-RegValue -Path $CapPath -Name "ApplicationDescription" -Value "Fast, GPU-accelerated image viewer"

foreach ($ext in $Extensions) {
    Set-RegValue -Path "$CapPath\FileAssociations" -Name $ext -Value $ProgID
}

# --- RegisteredApplications ---
Set-RegValue -Path "HKCU:\Software\RegisteredApplications" -Name "SuperViewer" -Value "Software\SuperViewer\Capabilities"

Write-Host "Registered application capabilities" -ForegroundColor Green

# --- Notify Explorer ---
$ShellNotify = @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ShellNotify {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
'@
[ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
"@
Invoke-Expression $ShellNotify
Write-Host "Notified Explorer of association changes" -ForegroundColor Green

# --- Open Settings ---
Write-Host ""
Write-Host "=== Almost done! ===" -ForegroundColor Yellow
Write-Host "Windows Settings will open. To set SuperViewer as your default image viewer:" -ForegroundColor Yellow
Write-Host "  1. Search for 'SuperViewer' or scroll to find it" -ForegroundColor Yellow
Write-Host "  2. Click it and assign your desired file types" -ForegroundColor Yellow
Write-Host ""

Start-Process "ms-settings:defaultapps"

Write-Host "Installation complete!" -ForegroundColor Green
