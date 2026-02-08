# SuperViewer Benchmark Results

**Date**: 2026-02-08 16:20:53

## System
| Property | Value |
|----------|-------|
| OS | Microsoft Windows 11 Home Single Language 10.0.26200 (Build 26200) |
| CPU | 11th Gen Intel(R) Core(TM) i7-11600H @ 2.90GHz |
| RAM | 15.7 GB |
| GPU | NVIDIA GeForce RTX 3050 Ti Laptop GPU |
| GPU Driver | 32.0.15.6614 |
| Power Plan | 64a64f24-65b9-4b56-befd-5ec1eaced9b3  (Silent) |

## Cold Start (ms)

| Metric | SuperViewer |
|--------|-------|
| Open large_jpeg | 37 |
| Open large_png | 39 |
| Open small_jpeg | 37 |
| Open webp_photo | 48 |

## Navigation Speed (ms per image)

| Viewer | Median | Mean | P95 | Min | Max |
|--------|--------|------|-----|-----|-----|
| SuperViewer | 63 | 72 | 95 | 55 | 109 |

## Memory Usage (MB)

| Viewer | Single Image WS | After Browse WS | Peak WS | Growth |
|--------|-----------------|-----------------|---------|--------|
| SuperViewer | 236.8 | 361.9 | 452.8 | 125.1 |

## Binary / Install Size

| Viewer | Exe (MB) | Install (MB) | Files | DLLs | Notes |
|--------|----------|--------------|-------|------|-------|
| SuperViewer | 10.02 | 10.02 | 1 | 0 | Single exe, no runtime deps |
| IrfanView | 2.42 | 8.34 | 37 | 12 | Portable install, libjpeg-turbo |
| JPEGView | 2.81 | 10.33 | 54 | 11 | Portable, C++ native |
| qView | 1.5 | 96.77 | 108 | 71 | Qt-based minimal viewer |

## Methodology

### Cold Start
- Measured from `Start-Process` to `MainWindowHandle != 0`
- 10 trials per viewer per image, reporting median
- No filesystem cache flush (warm disk cache)
- 2000ms wait between trials

### Navigation
- SendKeys Right arrow, detect window title change
- 100 sequential images

### Memory
- WorkingSet64 via .NET Process API
- 3000ms stabilization after image load

### Binary Size
- Recursive directory scan of install folder

---
*Benchmark completed in 2.2 minutes*
