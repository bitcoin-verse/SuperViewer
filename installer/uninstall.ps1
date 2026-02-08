#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall SuperViewer file associations and optionally remove the binary.

.DESCRIPTION
    Removes all registry keys created by install.ps1 and optionally deletes
    the SuperViewer install directory from %LOCALAPPDATA%.

.PARAMETER KeepFiles
    If specified, keeps the superviewer.exe binary and only removes registry entries.

.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -KeepFiles
#>

param(
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"

$Extensions = @(".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tiff", ".tif", ".gif", ".avif")
$ProgID = "SuperViewer.Image"

# --- Remove ProgID ---
$ProgIDPath = "HKCU:\Software\Classes\$ProgID"
if (Test-Path $ProgIDPath) {
    Remove-Item -Path $ProgIDPath -Recurse -Force
    Write-Host "Removed ProgID: $ProgID" -ForegroundColor Green
}

# --- Remove Application registration ---
$AppPath = "HKCU:\Software\Classes\Applications\superviewer.exe"
if (Test-Path $AppPath) {
    Remove-Item -Path $AppPath -Recurse -Force
    Write-Host "Removed application registration" -ForegroundColor Green
}

# --- Remove per-extension OpenWithProgids entries ---
foreach ($ext in $Extensions) {
    $ExtPath = "HKCU:\Software\Classes\$ext\OpenWithProgids"
    if (Test-Path $ExtPath) {
        $props = Get-ItemProperty -Path $ExtPath -Name $ProgID -ErrorAction SilentlyContinue
        if ($props) {
            Remove-ItemProperty -Path $ExtPath -Name $ProgID -Force
            Write-Host "Removed OpenWithProgids for $ext" -ForegroundColor Green
        }
        # Clean up empty key
        $remaining = Get-ItemProperty -Path $ExtPath -ErrorAction SilentlyContinue
        if ($remaining -and ($remaining.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count -eq 0) {
            Remove-Item -Path $ExtPath -Force -ErrorAction SilentlyContinue
            $parentPath = "HKCU:\Software\Classes\$ext"
            $children = Get-ChildItem -Path $parentPath -ErrorAction SilentlyContinue
            if (-not $children) {
                Remove-Item -Path $parentPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# --- Remove Capabilities ---
$CapPath = "HKCU:\Software\SuperViewer"
if (Test-Path $CapPath) {
    Remove-Item -Path $CapPath -Recurse -Force
    Write-Host "Removed capabilities" -ForegroundColor Green
}

# --- Remove RegisteredApplications entry ---
$RegAppsPath = "HKCU:\Software\RegisteredApplications"
if (Test-Path $RegAppsPath) {
    $props = Get-ItemProperty -Path $RegAppsPath -Name "SuperViewer" -ErrorAction SilentlyContinue
    if ($props) {
        Remove-ItemProperty -Path $RegAppsPath -Name "SuperViewer" -Force
        Write-Host "Removed RegisteredApplications entry" -ForegroundColor Green
    }
}

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

# --- Remove files ---
if (-not $KeepFiles) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "SuperViewer"
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Host "Removed install directory: $InstallDir" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "SuperViewer uninstalled successfully." -ForegroundColor Green
