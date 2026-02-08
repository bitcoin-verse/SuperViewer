#Requires -Version 5.1
<#
.SYNOPSIS
    Generate test corpus for SuperViewer benchmarks.

.DESCRIPTION
    Downloads sample images from Unsplash and converts them to the required
    formats and sizes using ImageMagick. Creates:
      - small_jpeg.jpg  (1920x1080, ~500 KB)
      - large_jpeg.jpg  (3840x2160, ~5 MB)
      - large_png.png   (3840x2160, ~15 MB)
      - webp_photo.webp (3840x2160, ~3 MB)
      - nav_folder/     (100 x 1920x1080 JPEGs)

.NOTES
    Prerequisites: ImageMagick (magick.exe) must be on PATH.
    Run from the benchmarks/corpus/ directory.
#>

param(
    [string]$OutputDir = $PSScriptRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-Magick {
    try {
        $null = & magick --version 2>&1
        return $true
    } catch {
        return $false
    }
}

function Get-UnsplashUrl([int]$Width, [int]$Height) {
    # Unsplash source gives random high-quality photos at requested size
    return "https://picsum.photos/$Width/$Height"
}

function Download-Image([string]$Url, [string]$OutPath, [string]$Label) {
    if ((Test-Path $OutPath) -and -not $Force) {
        Write-Host "  [skip] $Label already exists: $OutPath"
        return
    }
    Write-Host "  [download] $Label -> $OutPath"
    # Follow redirects, TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'SuperViewer-Benchmark/1.0')
    $wc.DownloadFile($Url, $OutPath)
    $size = (Get-Item $OutPath).Length / 1KB
    Write-Host "    downloaded $([math]::Round($size, 1)) KB"
}

function Convert-Image([string]$Source, [string]$Target, [string]$Resize, [int]$Quality, [string]$Label) {
    if ((Test-Path $Target) -and -not $Force) {
        Write-Host "  [skip] $Label already exists"
        return
    }
    Write-Host "  [convert] $Label"
    $args = @($Source, '-resize', $Resize, '-quality', $Quality, $Target)
    & magick @args
    if ($LASTEXITCODE -ne 0) { throw "magick convert failed for $Label" }
    $size = (Get-Item $Target).Length / 1KB
    Write-Host "    output: $([math]::Round($size, 1)) KB"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host "=== SuperViewer Benchmark Corpus Generator ==="
Write-Host "Output directory: $OutputDir"
Write-Host ""

if (-not (Test-Magick)) {
    Write-Error "ImageMagick (magick.exe) not found on PATH. Install from https://imagemagick.org/"
    exit 1
}

Push-Location $OutputDir
try {
    # --- Step 1: Download source images ---
    Write-Host "`n--- Step 1: Downloading source images ---"

    $source4k = Join-Path $OutputDir '_source_4k.jpg'
    $source1080 = Join-Path $OutputDir '_source_1080.jpg'

    # Download a 4K source photo
    Download-Image -Url (Get-UnsplashUrl 3840 2160) -OutPath $source4k -Label '4K source'

    # Download a 1080p source photo (different image)
    Download-Image -Url (Get-UnsplashUrl 1920 1080) -OutPath $source1080 -Label '1080p source'

    # --- Step 2: Generate test images ---
    Write-Host "`n--- Step 2: Generating test images ---"

    # small_jpeg.jpg — 1920x1080, JPEG quality 85 (~500 KB)
    $smallJpeg = Join-Path $OutputDir 'small_jpeg.jpg'
    if ((Test-Path $smallJpeg) -and -not $Force) {
        Write-Host "  [skip] small_jpeg.jpg already exists"
    } else {
        Write-Host "  [convert] small_jpeg.jpg (1920x1080, q85)"
        & magick $source1080 -resize '1920x1080!' -quality 85 $smallJpeg
        $size = (Get-Item $smallJpeg).Length / 1KB
        Write-Host "    output: $([math]::Round($size, 1)) KB"
    }

    # large_jpeg.jpg — 3840x2160, JPEG quality 92 (~5 MB)
    $largeJpeg = Join-Path $OutputDir 'large_jpeg.jpg'
    if ((Test-Path $largeJpeg) -and -not $Force) {
        Write-Host "  [skip] large_jpeg.jpg already exists"
    } else {
        Write-Host "  [convert] large_jpeg.jpg (3840x2160, q92)"
        & magick $source4k -resize '3840x2160!' -quality 92 $largeJpeg
        $size = (Get-Item $largeJpeg).Length / 1KB
        Write-Host "    output: $([math]::Round($size, 1)) KB"
    }

    # large_png.png — 3840x2160, PNG (lossless, ~15 MB)
    $largePng = Join-Path $OutputDir 'large_png.png'
    if ((Test-Path $largePng) -and -not $Force) {
        Write-Host "  [skip] large_png.png already exists"
    } else {
        Write-Host "  [convert] large_png.png (3840x2160, lossless)"
        & magick $source4k -resize '3840x2160!' $largePng
        $size = (Get-Item $largePng).Length / 1MB
        Write-Host "    output: $([math]::Round($size, 1)) MB"
    }

    # webp_photo.webp — 3840x2160, WebP quality 85 (~3 MB)
    $webp = Join-Path $OutputDir 'webp_photo.webp'
    if ((Test-Path $webp) -and -not $Force) {
        Write-Host "  [skip] webp_photo.webp already exists"
    } else {
        Write-Host "  [convert] webp_photo.webp (3840x2160, q85)"
        & magick $source4k -resize '3840x2160!' -quality 85 $webp
        $size = (Get-Item $webp).Length / 1KB
        Write-Host "    output: $([math]::Round($size, 1)) KB"
    }

    # --- Step 3: Generate navigation folder ---
    Write-Host "`n--- Step 3: Generating navigation folder (100 images) ---"

    $navDir = Join-Path $OutputDir 'nav_folder'
    if (-not (Test-Path $navDir)) {
        New-Item -ItemType Directory -Path $navDir | Out-Null
    }

    $existingCount = (Get-ChildItem -Path $navDir -Filter '*.jpg' -ErrorAction SilentlyContinue).Count
    if ($existingCount -ge 100 -and -not $Force) {
        Write-Host "  [skip] nav_folder already has $existingCount images"
    } else {
        Write-Host "  Generating 100 varied JPEGs from source..."
        for ($i = 1; $i -le 100; $i++) {
            $outFile = Join-Path $navDir ("img_{0:D3}.jpg" -f $i)
            if ((Test-Path $outFile) -and -not $Force) { continue }

            # Apply slight variations to make each image unique
            # Rotate hue by i*3.6 degrees (full circle over 100 images)
            $hue = [math]::Round($i * 3.6, 1)
            $brightness = 95 + ($i % 11)  # 95-105 range

            & magick $source1080 `
                -resize '1920x1080!' `
                -modulate "$brightness,100,$hue" `
                -quality 85 `
                $outFile

            if ($i % 10 -eq 0) {
                Write-Host "    $i / 100 generated"
            }
        }
        $totalSize = (Get-ChildItem $navDir -Filter '*.jpg' | Measure-Object -Property Length -Sum).Sum / 1MB
        Write-Host "    nav_folder total: $([math]::Round($totalSize, 1)) MB"
    }

    # --- Step 4: Summary ---
    Write-Host "`n--- Corpus Summary ---"
    $files = @('small_jpeg.jpg', 'large_jpeg.jpg', 'large_png.png', 'webp_photo.webp')
    foreach ($f in $files) {
        $path = Join-Path $OutputDir $f
        if (Test-Path $path) {
            $info = Get-Item $path
            $sizeStr = if ($info.Length -gt 1MB) {
                "$([math]::Round($info.Length / 1MB, 1)) MB"
            } else {
                "$([math]::Round($info.Length / 1KB, 1)) KB"
            }
            $dims = & magick identify -format '%wx%h' $path 2>$null
            Write-Host "  $f : $dims, $sizeStr"
        } else {
            Write-Host "  $f : MISSING"
        }
    }
    $navCount = (Get-ChildItem $navDir -Filter '*.jpg' -ErrorAction SilentlyContinue).Count
    Write-Host "  nav_folder/ : $navCount images"

    Write-Host "`n=== Corpus generation complete ==="

} finally {
    Pop-Location
}
