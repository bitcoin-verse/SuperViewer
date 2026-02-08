#Requires -Version 5.1
<#
.SYNOPSIS
    Measure binary/install size of image viewers.

.DESCRIPTION
    For each viewer in viewers.json, measures:
    - Executable file size
    - Total install directory size (recursive)
    - File count in install directory
    - Notable runtime dependencies

.PARAMETER ConfigPath
    Path to viewers.json configuration file.

.PARAMETER ViewerName
    Optional: measure only a specific viewer.

.PARAMETER OutputCsv
    Path to write results CSV.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\viewers.json'),
    [string]$ViewerName = '',
    [string]$OutputCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Host "=== Binary / Install Size Benchmark ==="
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
    $installDir = $viewer.installDir

    Write-Host "--- $name ---"

    # Exe size
    if (Test-Path $exe) {
        $exeInfo = Get-Item $exe
        $exeSizeMB = [math]::Round($exeInfo.Length / 1MB, 2)
        Write-Host "  Exe path     : $exe"
        Write-Host "  Exe size     : $exeSizeMB MB ($($exeInfo.Length) bytes)"
    } else {
        Write-Host "  Exe path     : $exe (NOT FOUND)"
        $exeSizeMB = -1
    }

    # Install directory size
    $installSizeMB = -1
    $fileCount = -1
    $dllCount = -1

    if ($installDir -and (Test-Path $installDir)) {
        $allFiles = Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue
        $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
        $installSizeMB = [math]::Round($totalSize / 1MB, 2)
        $fileCount = $allFiles.Count
        $dllCount = ($allFiles | Where-Object { $_.Extension -eq '.dll' }).Count

        Write-Host "  Install dir  : $installDir"
        Write-Host "  Install size : $installSizeMB MB"
        Write-Host "  File count   : $fileCount"
        Write-Host "  DLL count    : $dllCount"

        # List largest files (top 5)
        $topFiles = $allFiles | Sort-Object Length -Descending | Select-Object -First 5
        Write-Host "  Largest files:"
        foreach ($f in $topFiles) {
            $sizeMB = [math]::Round($f.Length / 1MB, 2)
            $relPath = $f.FullName.Substring($installDir.Length + 1)
            Write-Host "    $relPath : $sizeMB MB"
        }
    } elseif ($exeSizeMB -ge 0) {
        # No install dir (single-file deployment) - use exe size as install size
        $installSizeMB = $exeSizeMB
        $fileCount = 1
        $dllCount = 0
        Write-Host "  Install dir  : (single file)"
        Write-Host "  Install size : $installSizeMB MB"
        Write-Host "  File count   : 1"
        Write-Host "  DLL count    : 0"
    } else {
        Write-Host "  Install dir  : ${installDir} (NOT FOUND)"
    }

    Write-Host "  Notes        : $($viewer.notes)"
    Write-Host ""

    $allResults += [PSCustomObject]@{
        Viewer        = $name
        ExeSizeMB     = $exeSizeMB
        InstallSizeMB = $installSizeMB
        FileCount     = $fileCount
        DllCount      = $dllCount
        Notes         = $viewer.notes
        Metric        = 'BinarySize'
        Timestamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
}

# Summary table
Write-Host "--- Summary ---"
Write-Host ("{0,-15} {1,10} {2,12} {3,8} {4,8}" -f 'Viewer', 'Exe (MB)', 'Install (MB)', 'Files', 'DLLs')
Write-Host ("{0,-15} {1,10} {2,12} {3,8} {4,8}" -f '------', '--------', '------------', '-----', '----')
foreach ($r in $allResults) {
    $exeStr = if ($r.ExeSizeMB -ge 0) { $r.ExeSizeMB.ToString('F2') } else { 'N/A' }
    $installStr = if ($r.InstallSizeMB -ge 0) { $r.InstallSizeMB.ToString('F2') } else { 'N/A' }
    $filesStr = if ($r.FileCount -ge 0) { $r.FileCount.ToString() } else { 'N/A' }
    $dllStr = if ($r.DllCount -ge 0) { $r.DllCount.ToString() } else { 'N/A' }
    Write-Host ("{0,-15} {1,10} {2,12} {3,8} {4,8}" -f $r.Viewer, $exeStr, $installStr, $filesStr, $dllStr)
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

Write-Host "`n=== Binary Size Benchmark Complete ==="

return $allResults
