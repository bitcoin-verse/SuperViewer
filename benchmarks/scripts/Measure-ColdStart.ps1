#Requires -Version 5.1
<#
.SYNOPSIS
    Measure cold-start time: process launch to window visible.

.DESCRIPTION
    For each viewer in viewers.json, launches the exe with a test image as argument,
    polls until MainWindowHandle is non-zero, records elapsed time. Repeats for the
    configured number of trials and reports median, mean, min, max, and stddev.

    Optionally flushes the filesystem standby list between trials for true cold-start
    measurement (requires admin privileges).

.PARAMETER ConfigPath
    Path to viewers.json configuration file.

.PARAMETER ImagePath
    Path to the image file to open (passed as command-line argument to viewer).

.PARAMETER Trials
    Number of trials per viewer. Default: from config or 10.

.PARAMETER ViewerName
    Optional: run only for a specific viewer name.

.PARAMETER FlushCache
    Attempt to flush filesystem cache between trials (requires admin).

.PARAMETER OutputCsv
    Path to write raw results CSV.

.EXAMPLE
    .\Measure-ColdStart.ps1 -ImagePath "..\corpus\large_jpeg.jpg"
    .\Measure-ColdStart.ps1 -ImagePath "..\corpus\large_jpeg.jpg" -ViewerName "SuperViewer" -Trials 5
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\viewers.json'),
    [Parameter(Mandatory)]
    [string]$ImagePath,
    [int]$Trials = 0,
    [string]$ViewerName = '',
    [switch]$FlushCache,
    [string]$OutputCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Flush-StandbyList {
    # Uses RAMMap-style approach via a small C# snippet
    # Requires admin privileges
    try {
        $code = @'
using System;
using System.Runtime.InteropServices;

public class MemoryPurge {
    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);

    public static bool PurgeStandbyList() {
        // SystemMemoryListInformation = 80
        // MemoryPurgeStandbyList = 4
        int command = 4;
        IntPtr ptr = Marshal.AllocHGlobal(4);
        Marshal.WriteInt32(ptr, command);
        int status = NtSetSystemInformation(80, ptr, 4);
        Marshal.FreeHGlobal(ptr);
        return status == 0;
    }
}
'@
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        $result = [MemoryPurge]::PurgeStandbyList()
        return $result
    } catch {
        return $false
    }
}

function Wait-ForWindow([System.Diagnostics.Process]$Process, [int]$TimeoutMs = 30000, [int]$PollMs = 5) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $sw.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return -1  # timeout
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

# Resolve image path
$ImagePath = (Resolve-Path $ImagePath).Path
if (-not (Test-Path $ImagePath)) {
    Write-Error "Image not found: $ImagePath"
    exit 1
}

$imageName = [System.IO.Path]::GetFileName($ImagePath)
Write-Host "=== Cold Start Benchmark ==="
Write-Host "Image: $imageName ($ImagePath)"

# Determine trial count
if ($Trials -le 0) { $Trials = $config.settings.trials }
Write-Host "Trials: $Trials"
Write-Host "Flush cache: $FlushCache"

$interTrialMs = $config.settings.interTrialMs
$pollMs = $config.settings.pollIntervalMs

# Filter viewers
$viewers = $config.viewers
if ($ViewerName) {
    $viewers = $viewers | Where-Object { $_.name -eq $ViewerName }
    if (-not $viewers) {
        Write-Error "Viewer '$ViewerName' not found in config"
        exit 1
    }
}

# Results collection
$allResults = @()

foreach ($viewer in $viewers) {
    $name = $viewer.name
    $exe = $viewer.exe

    # Check if exe exists
    if (-not (Test-Path $exe)) {
        Write-Host "`n[$name] SKIPPED - exe not found: $exe"
        continue
    }

    Write-Host "`n--- $name ---"
    Write-Host "  Exe: $exe"

    $times = @()

    for ($trial = 1; $trial -le $Trials; $trial++) {
        # Kill any existing instances
        $procName = $viewer.processName
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        # Flush filesystem cache if requested
        if ($FlushCache) {
            $flushed = Flush-StandbyList
            if (-not $flushed -and $trial -eq 1) {
                Write-Host "  [warn] Cache flush failed (need admin?). Continuing without flush."
            }
        }

        # Measure startup
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $exe -ArgumentList "`"$ImagePath`"" -PassThru

        $elapsed = Wait-ForWindow -Process $proc -TimeoutMs 30000 -PollMs $pollMs
        $sw.Stop()

        if ($elapsed -lt 0) {
            Write-Host "  Trial $trial : TIMEOUT (30s)"
            $elapsed = -1
        } else {
            Write-Host "  Trial $trial : ${elapsed} ms"
            $times += $elapsed
        }

        # Clean up
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        } catch { }

        Start-Sleep -Milliseconds $interTrialMs
    }

    # Statistics
    if ($times.Count -gt 0) {
        $stats = $times | Measure-Object -Minimum -Maximum -Average
        $median = Get-Median $times
        $stddev = Get-StdDev $times

        Write-Host "`n  Results for $name :"
        Write-Host "    Median : $([math]::Round($median, 1)) ms"
        Write-Host "    Mean   : $([math]::Round($stats.Average, 1)) ms"
        Write-Host "    Min    : $($stats.Minimum) ms"
        Write-Host "    Max    : $($stats.Maximum) ms"
        Write-Host "    StdDev : $([math]::Round($stddev, 1)) ms"
        Write-Host "    Valid  : $($times.Count) / $Trials"

        $relStdDev = if ($median -gt 0) { $stddev / $median * 100 } else { 0 }
        if ($relStdDev -gt 30) {
            Write-Host "    [WARN] High variance ($([math]::Round($relStdDev, 1))% of median) - consider re-running"
        }

        # Store per-trial results
        for ($i = 0; $i -lt $times.Count; $i++) {
            $allResults += [PSCustomObject]@{
                Viewer    = $name
                Image     = $imageName
                Trial     = $i + 1
                TimeMs    = $times[$i]
                Metric    = 'ColdStart'
                Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }
        }
    } else {
        Write-Host "`n  Results for $name : ALL TRIALS FAILED"
    }
}

# Write CSV if requested
if ($OutputCsv) {
    $csvDir = Split-Path $OutputCsv -Parent
    if ($csvDir -and -not (Test-Path $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }
    $allResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults written to: $OutputCsv"
}

Write-Host "`n=== Cold Start Benchmark Complete ==="

# Return results for pipeline use
return $allResults
