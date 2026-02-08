#Requires -Version 5.1
<#
.SYNOPSIS
    Run all benchmark scripts and aggregate results.

.DESCRIPTION
    Orchestrates the full benchmark suite:
    1. Validates corpus exists
    2. Runs cold-start benchmarks for each test image
    3. Runs navigation benchmark
    4. Runs memory benchmark
    5. Runs binary size measurement
    6. Aggregates all results into summary tables

.PARAMETER ConfigPath
    Path to viewers.json configuration file.

.PARAMETER CorpusDir
    Path to the test corpus directory.

.PARAMETER OutputDir
    Path to write results. Default: benchmarks/results/

.PARAMETER SkipColdStart
    Skip cold-start benchmarks.

.PARAMETER SkipNavigation
    Skip navigation benchmark.

.PARAMETER SkipMemory
    Skip memory benchmark.

.PARAMETER SkipBinarySize
    Skip binary size measurement.

.PARAMETER ViewerName
    Optional: benchmark only a specific viewer.

.PARAMETER FlushCache
    Flush filesystem cache between cold-start trials.

.EXAMPLE
    .\run-all.ps1
    .\run-all.ps1 -ViewerName "SuperViewer" -SkipNavigation
    .\run-all.ps1 -FlushCache  # (requires admin)
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\viewers.json'),
    [string]$CorpusDir = (Join-Path $PSScriptRoot '..\corpus'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\results'),
    [switch]$SkipColdStart,
    [switch]$SkipNavigation,
    [switch]$SkipMemory,
    [switch]$SkipBinarySize,
    [string]$ViewerName = '',
    [switch]$FlushCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# ---------------------------------------------------------------------------
# Environment info
# ---------------------------------------------------------------------------

function Get-SystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
    $ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)

    return [PSCustomObject]@{
        OS          = "$($os.Caption) $($os.Version) (Build $($os.BuildNumber))"
        CPU         = $cpu.Name.Trim()
        RAM_GB      = $ram
        GPU         = $gpu.Name
        GPUDriver   = $gpu.DriverVersion
        PowerPlan   = (powercfg /getactivescheme 2>$null) -replace '.*:\s*', ''
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$startTime = Get-Date

Write-Host "================================================================"
Write-Host "           SuperViewer Benchmark Suite"
Write-Host "================================================================"
Write-Host "Started: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host ""

# System info
Write-Host "--- System Information ---"
$sysInfo = Get-SystemInfo
Write-Host "  OS         : $($sysInfo.OS)"
Write-Host "  CPU        : $($sysInfo.CPU)"
Write-Host "  RAM        : $($sysInfo.RAM_GB) GB"
Write-Host "  GPU        : $($sysInfo.GPU)"
Write-Host "  GPU Driver : $($sysInfo.GPUDriver)"
Write-Host "  Power Plan : $($sysInfo.PowerPlan)"
Write-Host ""

# Validate corpus
Write-Host "--- Validating Corpus ---"
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$corpusFiles = @(
    $config.corpus.small_jpeg,
    $config.corpus.large_jpeg,
    $config.corpus.large_png,
    $config.corpus.webp_photo
)

$corpusMissing = $false
foreach ($cf in $corpusFiles) {
    $path = Join-Path $CorpusDir $cf
    if (Test-Path $path) {
        $size = [math]::Round((Get-Item $path).Length / 1KB, 1)
        Write-Host "  [OK] $cf ($size KB)"
    } else {
        Write-Host "  [MISSING] $cf"
        $corpusMissing = $true
    }
}

$navFolder = Join-Path $CorpusDir $config.corpus.nav_folder
if (Test-Path $navFolder) {
    $navCount = (Get-ChildItem $navFolder -Filter '*.jpg').Count
    Write-Host "  [OK] nav_folder/ ($navCount images)"
} else {
    Write-Host "  [MISSING] nav_folder/"
    $corpusMissing = $true
}

if ($corpusMissing) {
    Write-Host ""
    Write-Host "  Corpus incomplete! Run generate-corpus.ps1 first:"
    Write-Host "    cd benchmarks\corpus && .\generate-corpus.ps1"
    Write-Host ""
    Write-Host "  Continuing with available files..."
}

# Create output directories
$rawDir = Join-Path $OutputDir 'raw'
if (-not (Test-Path $rawDir)) {
    New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
}

# Common parameters
$viewerParam = @{}
if ($ViewerName) { $viewerParam['ViewerName'] = $ViewerName }

# ---------------------------------------------------------------------------
# 1. Cold Start Benchmarks
# ---------------------------------------------------------------------------

if (-not $SkipColdStart) {
    Write-Host "`n================================================================"
    Write-Host "  PHASE 1: Cold Start Benchmarks"
    Write-Host "================================================================"

    $testImages = @{
        'small_jpeg' = $config.corpus.small_jpeg
        'large_jpeg' = $config.corpus.large_jpeg
        'large_png'  = $config.corpus.large_png
        'webp_photo' = $config.corpus.webp_photo
    }

    foreach ($key in $testImages.Keys) {
        $imagePath = Join-Path $CorpusDir $testImages[$key]
        if (-not (Test-Path $imagePath)) {
            Write-Host "`n  [SKIP] $key - file not found"
            continue
        }

        Write-Host "`n  --- Cold start with $key ---"
        $csvPath = Join-Path $rawDir "coldstart_$key.csv"

        $params = @{
            ConfigPath = $ConfigPath
            ImagePath  = $imagePath
            OutputCsv  = $csvPath
        }
        if ($FlushCache) { $params['FlushCache'] = $true }
        $params += $viewerParam

        & (Join-Path $scriptDir 'Measure-ColdStart.ps1') @params
    }
} else {
    Write-Host "`n  [SKIP] Cold Start benchmarks"
}

# ---------------------------------------------------------------------------
# 2. Navigation Benchmark
# ---------------------------------------------------------------------------

if (-not $SkipNavigation) {
    Write-Host "`n================================================================"
    Write-Host "  PHASE 2: Navigation Benchmark"
    Write-Host "================================================================"

    if (Test-Path $navFolder) {
        $csvPath = Join-Path $rawDir 'navigation.csv'
        $params = @{
            ConfigPath = $ConfigPath
            FolderPath = $navFolder
            OutputCsv  = $csvPath
        }
        $params += $viewerParam

        & (Join-Path $scriptDir 'Measure-Navigation.ps1') @params
    } else {
        Write-Host "  [SKIP] nav_folder not found"
    }
} else {
    Write-Host "`n  [SKIP] Navigation benchmark"
}

# ---------------------------------------------------------------------------
# 3. Memory Benchmark
# ---------------------------------------------------------------------------

if (-not $SkipMemory) {
    Write-Host "`n================================================================"
    Write-Host "  PHASE 3: Memory Benchmark"
    Write-Host "================================================================"

    $largeJpeg = Join-Path $CorpusDir $config.corpus.large_jpeg
    if (Test-Path $largeJpeg) {
        $csvPath = Join-Path $rawDir 'memory.csv'
        $params = @{
            ConfigPath = $ConfigPath
            ImagePath  = $largeJpeg
            OutputCsv  = $csvPath
        }
        if (Test-Path $navFolder) {
            $params['BrowseFolder'] = $navFolder
            $params['BrowseCount'] = 20
        }
        $params += $viewerParam

        & (Join-Path $scriptDir 'Measure-Memory.ps1') @params
    } else {
        Write-Host "  [SKIP] large_jpeg.jpg not found"
    }
} else {
    Write-Host "`n  [SKIP] Memory benchmark"
}

# ---------------------------------------------------------------------------
# 4. Binary Size
# ---------------------------------------------------------------------------

if (-not $SkipBinarySize) {
    Write-Host "`n================================================================"
    Write-Host "  PHASE 4: Binary Size Measurement"
    Write-Host "================================================================"

    $csvPath = Join-Path $rawDir 'binary_size.csv'
    $params = @{
        ConfigPath = $ConfigPath
        OutputCsv  = $csvPath
    }
    $params += $viewerParam

    & (Join-Path $scriptDir 'Measure-BinarySize.ps1') @params
} else {
    Write-Host "`n  [SKIP] Binary Size measurement"
}

# ---------------------------------------------------------------------------
# 5. Aggregate Results
# ---------------------------------------------------------------------------

Write-Host "`n================================================================"
Write-Host "  PHASE 5: Aggregating Results"
Write-Host "================================================================"

$summaryPath = Join-Path $OutputDir 'summary.md'
$summaryLines = @()
$summaryLines += "# SuperViewer Benchmark Results"
$summaryLines += ""
$summaryLines += "**Date**: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
$summaryLines += ""
$summaryLines += "## System"
$summaryLines += "| Property | Value |"
$summaryLines += "|----------|-------|"
$summaryLines += "| OS | $($sysInfo.OS) |"
$summaryLines += "| CPU | $($sysInfo.CPU) |"
$summaryLines += "| RAM | $($sysInfo.RAM_GB) GB |"
$summaryLines += "| GPU | $($sysInfo.GPU) |"
$summaryLines += "| GPU Driver | $($sysInfo.GPUDriver) |"
$summaryLines += "| Power Plan | $($sysInfo.PowerPlan) |"
$summaryLines += ""

# Cold start summary
$coldstartFiles = Get-ChildItem -Path $rawDir -Filter 'coldstart_*.csv' -ErrorAction SilentlyContinue
if ($coldstartFiles) {
    $summaryLines += "## Cold Start (ms)"
    $summaryLines += ""

    # Collect per-viewer per-image medians
    $viewerMedians = @{}

    foreach ($csvFile in $coldstartFiles) {
        $imageType = $csvFile.BaseName -replace '^coldstart_', ''
        $data = Import-Csv $csvFile.FullName

        $grouped = $data | Group-Object -Property Viewer
        foreach ($group in $grouped) {
            $viewer = $group.Name
            $times = $group.Group | ForEach-Object { [double]$_.TimeMs }
            $sorted = $times | Sort-Object
            $count = $sorted.Count
            $median = if ($count % 2 -eq 0) {
                ($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2.0
            } else {
                $sorted[[math]::Floor($count / 2)]
            }

            if (-not $viewerMedians.ContainsKey($viewer)) {
                $viewerMedians[$viewer] = @{}
            }
            $viewerMedians[$viewer][$imageType] = [math]::Round($median, 0)
        }
    }

    # Build table
    $imageTypes = $coldstartFiles | ForEach-Object { $_.BaseName -replace '^coldstart_', '' } | Sort-Object
    $viewerNames = $viewerMedians.Keys | Sort-Object

    $header = "| Metric |"
    $separator = "|--------|"
    foreach ($v in $viewerNames) {
        $header += " $v |"
        $separator += "-------|"
    }
    $summaryLines += $header
    $summaryLines += $separator

    foreach ($img in $imageTypes) {
        $row = "| Open $img |"
        foreach ($v in $viewerNames) {
            $val = $(if ($viewerMedians[$v].ContainsKey($img)) { $viewerMedians[$v][$img] } else { 'N/A' })
            $row += " $val |"
        }
        $summaryLines += $row
    }
    $summaryLines += ""
}

# Navigation summary
$navCsv = Join-Path $rawDir 'navigation.csv'
if (Test-Path $navCsv) {
    $summaryLines += "## Navigation Speed (ms per image)"
    $summaryLines += ""

    $navData = Import-Csv $navCsv
    $grouped = $navData | Group-Object -Property Viewer

    $summaryLines += "| Viewer | Median | Mean | P95 | Min | Max |"
    $summaryLines += "|--------|--------|------|-----|-----|-----|"

    foreach ($group in $grouped) {
        $times = $group.Group | ForEach-Object { [double]$_.TimeMs }
        $sorted = $times | Sort-Object
        $count = $sorted.Count
        $median = if ($count % 2 -eq 0) {
            ($sorted[$count / 2 - 1] + $sorted[$count / 2]) / 2.0
        } else {
            $sorted[[math]::Floor($count / 2)]
        }
        $stats = $times | Measure-Object -Minimum -Maximum -Average
        $p95idx = [math]::Ceiling(0.95 * $count) - 1
        $p95 = $sorted[[math]::Max(0, [math]::Min($p95idx, $count - 1))]

        $summaryLines += "| $($group.Name) | $([math]::Round($median, 0)) | $([math]::Round($stats.Average, 0)) | $([math]::Round($p95, 0)) | $($stats.Minimum) | $($stats.Maximum) |"
    }
    $summaryLines += ""
}

# Memory summary
$memCsv = Join-Path $rawDir 'memory.csv'
if (Test-Path $memCsv) {
    $summaryLines += "## Memory Usage (MB)"
    $summaryLines += ""

    $memData = Import-Csv $memCsv

    $summaryLines += "| Viewer | Single Image WS | After Browse WS | Peak WS | Growth |"
    $summaryLines += "|--------|-----------------|-----------------|---------|--------|"

    $grouped = $memData | Group-Object -Property Viewer
    foreach ($group in $grouped) {
        $single = $group.Group | Where-Object { $_.Phase -eq 'single_image' } | Select-Object -First 1
        $browse = $group.Group | Where-Object { $_.Phase -like 'after_browse*' } | Select-Object -First 1

        $singleWS = $(if ($single) { $single.WorkingSetMB } else { 'N/A' })
        $browseWS = $(if ($browse) { $browse.WorkingSetMB } else { 'N/A' })
        $peakWS = $(if ($browse) { $browse.PeakWorkingSetMB } elseif ($single) { $single.PeakWorkingSetMB } else { 'N/A' })
        $growth = $(if ($single -and $browse) {
            [math]::Round([double]$browse.WorkingSetMB - [double]$single.WorkingSetMB, 1)
        } else { 'N/A' })

        $summaryLines += "| $($group.Name) | $singleWS | $browseWS | $peakWS | $growth |"
    }
    $summaryLines += ""
}

# Binary size summary
$binCsv = Join-Path $rawDir 'binary_size.csv'
if (Test-Path $binCsv) {
    $summaryLines += "## Binary / Install Size"
    $summaryLines += ""

    $binData = Import-Csv $binCsv

    $summaryLines += "| Viewer | Exe (MB) | Install (MB) | Files | DLLs | Notes |"
    $summaryLines += "|--------|----------|--------------|-------|------|-------|"

    foreach ($row in $binData) {
        $exeStr = $(if ([double]$row.ExeSizeMB -ge 0) { $row.ExeSizeMB } else { 'N/A' })
        $installStr = $(if ([double]$row.InstallSizeMB -ge 0) { $row.InstallSizeMB } else { 'N/A' })
        $filesStr = $(if ([int]$row.FileCount -ge 0) { $row.FileCount } else { 'N/A' })
        $dllStr = $(if ([int]$row.DllCount -ge 0) { $row.DllCount } else { 'N/A' })
        $summaryLines += "| $($row.Viewer) | $exeStr | $installStr | $filesStr | $dllStr | $($row.Notes) |"
    }
    $summaryLines += ""
}

# Methodology
$summaryLines += "## Methodology"
$summaryLines += ""
$summaryLines += "### Cold Start"
$summaryLines += "- Measured from ``Start-Process`` to ``MainWindowHandle != 0``"
$summaryLines += "- $($config.settings.trials) trials per viewer per image, reporting median"
$summaryLines += "- $(if ($FlushCache) { 'Filesystem standby list flushed between trials' } else { 'No filesystem cache flush (warm disk cache)' })"
$summaryLines += "- $($config.settings.interTrialMs)ms wait between trials"
$summaryLines += ""
$summaryLines += "### Navigation"
$summaryLines += "- SendKeys Right arrow, detect window title change"
$summaryLines += "- $($config.settings.navImages) sequential images"
$summaryLines += ""
$summaryLines += "### Memory"
$summaryLines += "- WorkingSet64 via .NET Process API"
$summaryLines += "- $($config.settings.stabilizeMs)ms stabilization after image load"
$summaryLines += ""
$summaryLines += "### Binary Size"
$summaryLines += "- Recursive directory scan of install folder"
$summaryLines += ""

$endTime = Get-Date
$duration = $endTime - $startTime
$summaryLines += "---"
$summaryLines += "*Benchmark completed in $([math]::Round($duration.TotalMinutes, 1)) minutes*"

# Write summary
$summaryContent = $summaryLines -join "`n"
Set-Content -Path $summaryPath -Value $summaryContent -Encoding UTF8

Write-Host "`nSummary written to: $summaryPath"
Write-Host ""
Write-Host "================================================================"
Write-Host "  Benchmark suite completed in $([math]::Round($duration.TotalMinutes, 1)) minutes"
Write-Host "  Results: $OutputDir"
Write-Host "================================================================"
