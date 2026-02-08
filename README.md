# SuperViewer by Bitcoin.com

A fast image viewer for Windows, built in Rust.

# Quickstart

```bash
# 1. Run the installer (no admin required) 
installer\install.bat

# 2. Set as default application for your preferred image formats

# 3. To uninstall
installer\uninstall.bat
```


# Screenshot

![SuperViewer in action](docs/Animation.gif)

# What problem we solve

Most image viewers today feel heavier than they should.

They often:

- take noticeable time to launch

- stutter when moving through large folders

- consume excessive memory

- depend on large frameworks or runtimes

- feel sluggish with high-resolution photos

SuperViewer exists to do one thing well: **to open images immediately and let you move through them quickly.**


## Why it’s faster 

SuperViewer keeps the stack simple and close to the system:

- Native Windows app: no heavy frameworks or startup cost

- GPU rendering: zoom and transforms handled by your graphics card, not the CPU

- Background decoding:  upcoming images load ahead of time while you view the current one

- In-memory cache: previously viewed images reopen instantly

- Single binary: no external dependencies or runtimes to load

Result: **less waiting, smoother interactions.**


# Benchmarks

Test machine: Windows 11, i7-11600H, RTX 3050 Ti  
Disk cache warm, median of 10 runs.

## Cold start (process launch → window visible)

| Image | SuperViewer | IrfanView | JPEGView | qView |
|--------|-------------|-----------|----------|--------|
| 4K JPEG | **37 ms** | 86 ms | 134 ms | 192 ms |
| 4K PNG | **39 ms** | 97 ms | 389 ms | 190 ms |
| 1080p JPEG | **37 ms** | 84 ms | 86 ms | 192 ms |
| 4K WebP | **48 ms** | 84 ms | 232 ms | 184 ms |

## Folder navigation (100 sequential images)

| Viewer | Median |
|-----------|-----------|
| IrfanView | 61 ms |
| JPEGView | 62 ms |
| qView | 62 ms |
| **SuperViewer** | **63 ms** |

## Binary size

| Viewer | Exe | Total Install | Files | DLLs |
|--------|-----|---------------|-------|------|
| **SuperViewer** | 10 MB | **10 MB** | **1** | **0** |
| IrfanView | 2.4 MB | 8.3 MB | 37 | 12 |
| JPEGView | 2.8 MB | 10.3 MB | 54 | 11 |
| qView | 1.5 MB | 96.8 MB | 108 | 71 |


## Memory

SuperViewer uses a larger cache (default 512 MB) to enable instant back/forward navigation.  
Cache size is configurable.

Benchmark scripts and raw data are available in `benchmarks/`.


### Pipeline

```
CLI arg / drop → decode (rayon pool) → resize → GPU texture upload → render quad
                       ↕                 ↕              ↑
                 LRU cache (512 MB)  DisplayReady   wgpu DX12 surface
                 [full-res RGBA]     [pre-resized]  [texture reuse]
```

On cache hit with matching viewport, navigation skips decode and resize entirely — just uploads cached pixels to the existing GPU texture.

## Performance

Benchmarked against IrfanView, JPEGView, and qView on an i7-11600H / RTX 3050 Ti laptop (Windows 11).

### Cold Start

Time from process launch to window visible (median of 10 trials, warm disk cache):

| Image | SuperViewer | IrfanView | JPEGView | qView |
|-------|-------------|-----------|----------|-------|
| 4K JPEG | **37 ms** | 86 ms | 134 ms | 192 ms |
| 4K PNG | **39 ms** | 97 ms | 389 ms | 190 ms |
| 1080p JPEG | **37 ms** | 84 ms | 86 ms | 192 ms |
| 4K WebP | **48 ms** | 84 ms | 232 ms | 184 ms |

### Navigation Speed

Arrow key through 100 sequential 1080p JPEGs, measured via window title change detection:

| Viewer | Median | Mean | P95 |
|--------|--------|------|-----|
| IrfanView | 61 ms | 61 ms | 64 ms |
| JPEGView | 62 ms | 62 ms | 64 ms |
| qView | 62 ms | 63 ms | 73 ms |
| **SuperViewer** | **63 ms** | 72 ms | 95 ms |

### Binary Size

| Viewer | Exe | Total Install | Files | DLLs |
|--------|-----|---------------|-------|------|
| **SuperViewer** | 10 MB | **10 MB** | **1** | **0** |
| IrfanView | 2.4 MB | 8.3 MB | 37 | 12 |
| JPEGView | 2.8 MB | 10.3 MB | 54 | 11 |
| qView | 1.5 MB | 96.8 MB | 108 | 71 |

### Memory

| Viewer | Single Image | After Browsing 20 | Peak |
|--------|-------------|-------------------|------|
| IrfanView | 46 MB | 19 MB | 46 MB |
| JPEGView | 91 MB | 92 MB | 161 MB |
| qView | 160 MB | 208 MB | 272 MB |
| SuperViewer | 237 MB | 362 MB | 453 MB |

SuperViewer trades higher memory for instant navigation — the 512 MB LRU cache keeps decoded + display-ready images in memory so back-navigation requires zero CPU work.

> Benchmark scripts and raw data in [`benchmarks/`](benchmarks/).

## Features

- Instant startup
- Smooth 60+ FPS pan & zoom
- Folder browsing (← / →)
- Background prefetch of upcoming images
- Drag and drop
- Fullscreen mode
- Rotate and flip (GPU-based, zero CPU cost)
- Status overlay (filename, resolution, zoom)
- Single self-contained executable

## Supported Formats

| Format | Decoder | Notes |
|--------|---------|-------|
| JPEG | turbojpeg (libjpeg-turbo) | Fast path, RGBA output |
| PNG | image crate | |
| WebP | webp crate (libwebp) | |
| BMP | image crate | |
| TIFF | image crate | |
| GIF | image crate | Static (first frame) |
| AVIF | image crate | |

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Esc | Quit |
| F / F11 | Toggle fullscreen |
| 0 / Numpad 0 | Fit to screen |
| 1 / Numpad 1 | Zoom to 100% (1:1 pixels) |
| R | Rotate 90 clockwise |
| H | Flip horizontal |
| V | Flip vertical |
| Left | Previous image |
| Right / Space | Next image |
| Mouse drag | Pan |
| Scroll wheel | Zoom to cursor |

## Architecture

```
crates/
  viewer-core/      Decode, cache, transforms, directory nav, async pipeline
  viewer-render/    wgpu GPU context, texture upload, shader-based renderer, overlay status bar
  viewer-win32/     Raw Win32 window, WndProc, DPI, drag-drop, fullscreen
  viewer-cli/       CLI argument parsing (clap)
  viewer-app/       Composition root: event loop, state machine, keybindings
assets/
  shaders/
    quad.wgsl       Vertex + fragment shader (transform uniforms)
    overlay.wgsl    Status bar overlay shader (rect-positioned textured quad)
```

## Building

### Prerequisites

- Rust (stable toolchain)
- MSVC Build Tools
- CMake (for turbojpeg)

### Build

```bash
# Debug
cargo build

# Release (optimized, ~10 MB)
cargo build --release
```

The release binary is at `target/release/superviewer.exe`.

### Install as Default Image Viewer

```bash
# Run the installer (no admin required)
installer\install.bat
```

This copies `superviewer.exe` to `%LOCALAPPDATA%\SuperViewer\`, registers file associations for JPEG, PNG, BMP, WebP, TIFF, GIF, and AVIF, then opens Windows Settings where you can set SuperViewer as your default app.

To pass a custom exe path (e.g. during development):

```powershell
.\installer\install.ps1 -ExePath "target\release\superviewer.exe"
```

### Uninstall

```bash
installer\uninstall.bat
```

Removes all registry entries and the install directory. Use `-KeepFiles` to only remove associations.

### Run

```bash
# Open an image
cargo run --release -- photo.jpg

# Or run the binary directly
target/release/superviewer.exe C:\path\to\image.png
```

## Testing

See [TESTING.md](TESTING.md) for a full manual test checklist. Quick start:

```bash
# Generate test images (Python 3, no dependencies)
python tests/generate_test_images.py

# Run the viewer against test images
target/release/superviewer.exe tests/images/test_gradient.bmp
```

## Dependencies

| Crate | Version | Purpose |
|-------|---------|---------|
| wgpu | 28 | GPU rendering (DX12/Vulkan) |
| windows | 0.61 | Win32 API |
| turbojpeg | 1.4 | Fast JPEG decode |
| image | 0.25 | PNG, BMP, TIFF, GIF, AVIF decode |
| webp | 0.3 | WebP decode |
| fast_image_resize | 5.1 | Display downsampling |
| rayon | 1.10 | Thread pool for decode |
| crossbeam-channel | 0.5 | Bounded channels for pipeline |
| clap | 4 | CLI parsing |
| bytemuck | 1 | Safe transmute for GPU uniforms |
