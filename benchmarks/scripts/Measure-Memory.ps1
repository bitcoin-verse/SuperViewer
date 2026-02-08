#Requires -Version 5.1
<#
.SYNOPSIS
    Measure memory usage of image viewers.

.DESCRIPTION
    Opens each viewer with a test image, waits for stabilization, then captures:
    - WorkingSet64 (current physical memory)
    - PeakWorkingSet64 (peak physical memory)
    - PrivateMemorySize64 (committed private memory)

    Optionally browses through additional images to measure memory growth
    (useful for testing cache behavior).

.PARAMETER ConfigPath
    Path to viewers.json configuration file.

.PARAMETER ImagePath
    Path to the image to open initially.

.PARAMETER BrowseFolder
    Optional: folder to browse through after initial open.

.PARAMETER BrowseCount
    Number of images to browse through. Default: 20.

.PARAMETER ViewerName
    Optional: run only for a specific viewer.

.PARAMETER OutputCsv
    Path to write results CSV.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\viewers.json'),
    [Parameter(Mandatory)]
    [string]$ImagePath,
    [string]$BrowseFolder = '',
    [int]$BrowseCount = 20,
    [string]$ViewerName = '',
    [string]$OutputCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Wait-ForWindow([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 30000, [int]$PollMs = 5) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Set-ForegroundWindow {
    param([IntPtr]$Handle)
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinAPI2 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction SilentlyContinue
    [WinAPI2]::ShowWindow($Handle, 9)
    [WinAPI2]::SetForegroundWindow($Handle) | Out-Null
}

function Get-MemorySnapshot([System.Diagnostics.Process]$Process) {
    $Process.Refresh()
    return [PSCustomObject]@{
        WorkingSetMB       = [math]::Round($Process.WorkingSet64 / 1MB, 1)
        PeakWorkingSetMB   = [math]::Round($Process.PeakWorkingSet64 / 1MB, 1)
        PrivateMemoryMB    = [math]::Round($Process.PrivateMemorySize64 / 1MB, 1)
        WorkingSetBytes    = $Process.WorkingSet64
        PeakWorkingSetBytes = $Process.PeakWorkingSet64
        PrivateMemoryBytes = $Process.PrivateMemorySize64
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$ImagePath = (Resolve-Path $ImagePath).Path
if (-not (Test-Path $ImagePath)) {
    Write-Error "Image not found: $ImagePath"
    exit 1
}

$stabilizeMs = $config.settings.stabilizeMs
$imageName = [System.IO.Path]::GetFileName($ImagePath)

Write-Host "=== Memory Usage Benchmark ==="
Write-Host "Image: $imageName"
if ($BrowseFolder) { Write-Host "Browse folder: $BrowseFolder ($BrowseCount images)" }
Write-Host ""

$viewers = $config.viewers
if ($ViewerName) {
    $viewers = $viewers | Where-Object { $_.name -eq $ViewerName }
    if (-not $viewers) {
        Write-Error "Viewer '$ViewerName' not found in config"
        exit 1
    }
}

$allResults = @()

foreach ($viewer in $viewers) {
    $name = $viewer.name
    $exe = $viewer.exe

    if (-not (Test-Path $exe)) {
        Write-Host "`n[$name] SKIPPED - exe not found: $exe"
        continue
    }

    Write-Host "`n--- $name ---"

    # Kill existing instances
    $procName = $viewer.processName
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Launch with image
    $proc = Start-Process -FilePath $exe -ArgumentList "`"$ImagePath`"" -PassThru

    $windowReady = Wait-ForWindow -Process $proc -TimeoutMs 15000
    if (-not $windowReady) {
        Write-Host "  [ERROR] Window did not appear. Skipping."
        try { Stop-Process -Id $proc.Id -Force } catch { }
        continue
    }

    # Wait for stabilization
    Write-Host "  Waiting ${stabilizeMs}ms for stabilization..."
    Start-Sleep -Milliseconds $stabilizeMs

    # Snapshot 1: After opening single image
    $snap1 = Get-MemorySnapshot $proc
    Write-Host "  After single image:"
    Write-Host "    Working Set  : $($snap1.WorkingSetMB) MB"
    Write-Host "    Peak Working : $($snap1.PeakWorkingSetMB) MB"
    Write-Host "    Private      : $($snap1.PrivateMemoryMB) MB"

    $allResults += [PSCustomObject]@{
        Viewer          = $name
        Phase           = 'single_image'
        Image           = $imageName
        WorkingSetMB    = $snap1.WorkingSetMB
        PeakWorkingSetMB = $snap1.PeakWorkingSetMB
        PrivateMemoryMB = $snap1.PrivateMemoryMB
        Metric          = 'Memory'
        Timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # Snapshot 2: After browsing (if folder provided)
    if ($BrowseFolder -and (Test-Path $BrowseFolder)) {
        $proc.Refresh()
        Set-ForegroundWindow -Handle $proc.MainWindowHandle
        Start-Sleep -Milliseconds 500

        Write-Host "  Browsing $BrowseCount images..."
        for ($i = 1; $i -le $BrowseCount; $i++) {
            [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
            Start-Sleep -Milliseconds 200

            if ($proc.HasExited) {
                Write-Host "  [ERROR] Process exited during browsing at image $i"
                break
            }
        }

        if (-not $proc.HasExited) {
            # Wait for stabilization after browsing
            Start-Sleep -Milliseconds $stabilizeMs

            $snap2 = Get-MemorySnapshot $proc
            Write-Host "  After browsing $BrowseCount images:"
            Write-Host "    Working Set  : $($snap2.WorkingSetMB) MB"
            Write-Host "    Peak Working : $($snap2.PeakWorkingSetMB) MB"
            Write-Host "    Private      : $($snap2.PrivateMemoryMB) MB"

            $growth = $snap2.WorkingSetMB - $snap1.WorkingSetMB
            Write-Host "    Growth       : $([math]::Round($growth, 1)) MB"

            $allResults += [PSCustomObject]@{
                Viewer          = $name
                Phase           = "after_browse_$BrowseCount"
                Image           = $imageName
                WorkingSetMB    = $snap2.WorkingSetMB
                PeakWorkingSetMB = $snap2.PeakWorkingSetMB
                PrivateMemoryMB = $snap2.PrivateMemoryMB
                Metric          = 'Memory'
                Timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
    }

    # Clean up
    try { Stop-Process -Id $proc.Id -Force } catch { }
    Start-Sleep -Milliseconds 1000
}

# Write CSV
if ($OutputCsv) {
    $csvDir = Split-Path $OutputCsv -Parent
    if ($csvDir -and -not (Test-Path $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }
    $allResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults written to: $OutputCsv"
}

Write-Host "`n=== Memory Benchmark Complete ==="

return $allResults
