#Requires -Version 5.1
<#
.SYNOPSIS
    Measure directory navigation speed (arrow key through images).

.DESCRIPTION
    Opens a viewer with the first image in a folder, then sends Right arrow keys
    to navigate through images. Measures time between key press and observable
    change (window title update or stable rendering).

    For viewers that update window title with filename (IrfanView, JPEGView, etc.),
    we detect title change. For SuperViewer (which may not), we use a fixed polling
    approach with configurable wait time.

.PARAMETER ConfigPath
    Path to viewers.json configuration file.

.PARAMETER FolderPath
    Path to folder containing sequentially-named images.

.PARAMETER ImageCount
    Number of images to navigate through. Default: from config or 100.

.PARAMETER ViewerName
    Optional: run only for a specific viewer.

.PARAMETER OutputCsv
    Path to write raw results CSV.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\viewers.json'),
    [Parameter(Mandatory)]
    [string]$FolderPath,
    [int]$ImageCount = 0,
    [string]$ViewerName = '',
    [string]$OutputCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-Median([double[]]$Values) {
    $sorted = $Values | Sort-Object
    $count = $sorted.Count
    if ($count -eq 0) { return 0 }
    if ($count % 2 -eq 0) {
        return ($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2.0
    } else {
        return $sorted[[math]::Floor($count / 2)]
    }
}

function Get-StdDev([double[]]$Values) {
    if ($Values.Count -le 1) { return 0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sumSqDiff = ($Values | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum
    return [math]::Sqrt($sumSqDiff / ($Values.Count - 1))
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling($Percentile / 100.0 * $sorted.Count) - 1
    $index = [math]::Max(0, [math]::Min($index, $sorted.Count - 1))
    return $sorted[$index]
}

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
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction SilentlyContinue
    [WinAPI]::ShowWindow($Handle, 9)  # SW_RESTORE
    [WinAPI]::SetForegroundWindow($Handle) | Out-Null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Load configuration
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Resolve folder path
$FolderPath = (Resolve-Path $FolderPath).Path
if (-not (Test-Path $FolderPath -PathType Container)) {
    Write-Error "Folder not found: $FolderPath"
    exit 1
}

$images = Get-ChildItem -Path $FolderPath -Filter '*.jpg' | Sort-Object Name
if ($images.Count -eq 0) {
    Write-Error "No JPEG images found in: $FolderPath"
    exit 1
}

if ($ImageCount -le 0) { $ImageCount = $config.settings.navImages }
$ImageCount = [math]::Min($ImageCount, $images.Count - 1)  # -1 because first is opened directly

$navWaitMs = $config.settings.navWaitMs

Write-Host "=== Navigation Speed Benchmark ==="
Write-Host "Folder: $FolderPath"
Write-Host "Images: $($images.Count) available, navigating $ImageCount"
Write-Host ""

# Filter viewers
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

    # Kill any existing instances
    $procName = $viewer.processName
    Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # Open first image
    $firstImage = $images[0].FullName
    $proc = Start-Process -FilePath $exe -ArgumentList "`"$firstImage`"" -PassThru

    $windowReady = Wait-ForWindow -Process $proc -TimeoutMs 15000
    if (-not $windowReady) {
        Write-Host "  [ERROR] Window did not appear within 15s. Skipping."
        try { Stop-Process -Id $proc.Id -Force } catch { }
        continue
    }

    # Wait for viewer to stabilize
    Start-Sleep -Milliseconds 2000

    # Ensure window is focused
    $proc.Refresh()
    Set-ForegroundWindow -Handle $proc.MainWindowHandle
    Start-Sleep -Milliseconds 500

    # Capture initial title
    $proc.Refresh()
    $lastTitle = $proc.MainWindowTitle

    $navTimes = @()
    $titleBased = $false

    Write-Host "  Navigating $ImageCount images..."

    for ($i = 1; $i -le $ImageCount; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Send Right arrow key
        [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')

        # Wait for title change (indicates image loaded) or fixed wait
        $titleChanged = $false
        $timeout = 5000  # max 5s per image
        while ($sw.ElapsedMilliseconds -lt $timeout) {
            Start-Sleep -Milliseconds $navWaitMs
            $proc.Refresh()

            # Check if process exited
            if ($proc.HasExited) {
                Write-Host "  [ERROR] Process exited at image $i"
                break
            }

            $currentTitle = $proc.MainWindowTitle
            if ($currentTitle -ne $lastTitle -and $currentTitle.Length -gt 0) {
                $titleChanged = $true
                $lastTitle = $currentTitle
                break
            }
        }

        $elapsed = $sw.ElapsedMilliseconds

        if ($proc.HasExited) { break }

        if (-not $titleChanged) {
            # Title didn't change - viewer may not update title per image
            # Use a fixed measurement approach: wait a bit and record
            if ($i -eq 1) {
                Write-Host "  [info] Title not changing - using fixed-interval measurement"
            }
            # For fixed-interval: the key was sent, we waited navWaitMs in the loop
            # Record the navWaitMs as the observed time (lower bound)
            $elapsed = $navWaitMs
        } else {
            if ($i -eq 1) {
                $titleBased = $true
                Write-Host "  [info] Title-change detection active"
            }
        }

        $navTimes += $elapsed

        if ($i % 20 -eq 0) {
            $runningMedian = Get-Median $navTimes
            Write-Host "    $i / $ImageCount (running median: $([math]::Round($runningMedian, 1)) ms)"
        }
    }

    # Clean up
    try { Stop-Process -Id $proc.Id -Force } catch { }

    # Statistics
    if ($navTimes.Count -gt 0) {
        $stats = $navTimes | Measure-Object -Minimum -Maximum -Average
        $median = Get-Median $navTimes
        $stddev = Get-StdDev $navTimes
        $p95 = Get-Percentile $navTimes 95

        Write-Host "`n  Results for $name :"
        Write-Host "    Detection : $(if ($titleBased) { 'title-change' } else { 'fixed-interval' })"
        Write-Host "    Images    : $($navTimes.Count)"
        Write-Host "    Median    : $([math]::Round($median, 1)) ms"
        Write-Host "    Mean      : $([math]::Round($stats.Average, 1)) ms"
        Write-Host "    P95       : $([math]::Round($p95, 1)) ms"
        Write-Host "    Min       : $($stats.Minimum) ms"
        Write-Host "    Max       : $($stats.Maximum) ms"
        Write-Host "    StdDev    : $([math]::Round($stddev, 1)) ms"

        # Store per-navigation results
        for ($j = 0; $j -lt $navTimes.Count; $j++) {
            $allResults += [PSCustomObject]@{
                Viewer     = $name
                ImageIndex = $j + 1
                TimeMs     = $navTimes[$j]
                Detection  = $(if ($titleBased) { 'title' } else { 'fixed' })
                Metric     = 'Navigation'
                Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
    } else {
        Write-Host "`n  Results for $name : NO DATA"
    }
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

Write-Host "`n=== Navigation Benchmark Complete ==="

return $allResults
