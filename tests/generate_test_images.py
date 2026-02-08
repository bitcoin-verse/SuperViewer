#!/usr/bin/env python3
"""Generate test images for SuperViewer using only Python stdlib.

Creates BMP and PNG test images in tests/images/ for manual testing.
No external dependencies required (no Pillow/PIL).

Usage:
    python tests/generate_test_images.py
"""

import os
import struct
import zlib

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "images")


def write_bmp(path, width, height, pixels):
    """Write a 24-bit BMP file. pixels is a list of (r, g, b) tuples, row-major top-to-bottom."""
    row_size = (width * 3 + 3) & ~3  # rows padded to 4-byte boundary
    pixel_data_size = row_size * height
    file_size = 54 + pixel_data_size

    with open(path, "wb") as f:
        # BMP header (14 bytes)
        f.write(b"BM")
        f.write(struct.pack("<I", file_size))
        f.write(struct.pack("<HH", 0, 0))
        f.write(struct.pack("<I", 54))

        # DIB header (40 bytes) - BITMAPINFOHEADER
        f.write(struct.pack("<I", 40))
        f.write(struct.pack("<i", width))
        f.write(struct.pack("<i", -height))  # negative = top-down
        f.write(struct.pack("<HH", 1, 24))
        f.write(struct.pack("<I", 0))  # no compression
        f.write(struct.pack("<I", pixel_data_size))
        f.write(struct.pack("<i", 2835))  # ~72 DPI
        f.write(struct.pack("<i", 2835))
        f.write(struct.pack("<II", 0, 0))

        # Pixel data (BGR, padded rows)
        padding = row_size - width * 3
        for y in range(height):
            for x in range(width):
                r, g, b = pixels[y * width + x]
                f.write(struct.pack("BBB", b, g, r))  # BMP uses BGR
            f.write(b"\x00" * padding)


def write_png(path, width, height, pixels):
    """Write a 32-bit RGBA PNG file. pixels is a list of (r, g, b, a) tuples."""

    def make_chunk(chunk_type, data):
        chunk = chunk_type + data
        crc = struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF)
        return struct.pack(">I", len(data)) + chunk + crc

    # PNG signature
    signature = b"\x89PNG\r\n\x1a\n"

    # IHDR
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    # bit depth=8, color type=6 (RGBA), compression=0, filter=0, interlace=0

    # IDAT - raw pixel data with filter byte per row
    raw_data = bytearray()
    for y in range(height):
        raw_data.append(0)  # filter: None
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw_data.extend([r, g, b, a])

    compressed = zlib.compress(bytes(raw_data), 9)

    # IEND
    with open(path, "wb") as f:
        f.write(signature)
        f.write(make_chunk(b"IHDR", ihdr_data))
        f.write(make_chunk(b"IDAT", compressed))
        f.write(make_chunk(b"IEND", b""))


def generate_gradient_bmp(path, width, height):
    """RGB gradient: red increases left-to-right, green increases top-to-bottom."""
    pixels = []
    for y in range(height):
        for x in range(width):
            r = x * 255 // max(width - 1, 1)
            g = y * 255 // max(height - 1, 1)
            b = 128
            pixels.append((r, g, b))
    write_bmp(path, width, height, pixels)
    return width, height


def generate_checkerboard_bmp(path, width, height, cell_size=4):
    """Black-and-white checkerboard pattern."""
    pixels = []
    for y in range(height):
        for x in range(width):
            is_white = ((x // cell_size) + (y // cell_size)) % 2 == 0
            c = 255 if is_white else 0
            pixels.append((c, c, c))
    write_bmp(path, width, height, pixels)
    return width, height


def generate_alpha_png(path, width, height):
    """PNG with transparency: four quadrants with different alpha values,
    colored circles on a checkerboard background to make alpha visible."""
    pixels = []
    cx, cy = width // 2, height // 2
    radius = min(width, height) // 3

    for y in range(height):
        for x in range(width):
            # Distance from center
            dx = x - cx
            dy = y - cy
            dist = (dx * dx + dy * dy) ** 0.5

            if dist < radius:
                # Inside circle: solid color with varying alpha by quadrant
                if x < cx and y < cy:
                    r, g, b, a = 255, 0, 0, 255  # top-left: red, fully opaque
                elif x >= cx and y < cy:
                    r, g, b, a = 0, 255, 0, 192  # top-right: green, 75% opaque
                elif x < cx and y >= cy:
                    r, g, b, a = 0, 0, 255, 128  # bottom-left: blue, 50% opaque
                else:
                    r, g, b, a = 255, 255, 0, 64  # bottom-right: yellow, 25% opaque
            else:
                # Outside circle: transparent
                r, g, b, a = 0, 0, 0, 0

            pixels.append((r, g, b, a))

    write_png(path, width, height, pixels)
    return width, height


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    images = []

    # 1. Standard gradient BMP (256x256)
    path = os.path.join(OUTPUT_DIR, "test_gradient.bmp")
    w, h = generate_gradient_bmp(path, 256, 256)
    images.append((path, w, h))

    # 2. Large gradient BMP (4000x3000)
    path = os.path.join(OUTPUT_DIR, "test_large.bmp")
    w, h = generate_gradient_bmp(path, 4000, 3000)
    images.append((path, w, h))

    # 3. Tiny checkerboard BMP (16x16)
    path = os.path.join(OUTPUT_DIR, "test_tiny.bmp")
    w, h = generate_checkerboard_bmp(path, 16, 16, cell_size=4)
    images.append((path, w, h))

    # 4. Alpha transparency PNG (200x200)
    path = os.path.join(OUTPUT_DIR, "test_alpha.png")
    w, h = generate_alpha_png(path, 200, 200)
    images.append((path, w, h))

    print(f"Generated {len(images)} test images in {OUTPUT_DIR}/")
    for path, w, h in images:
        size_kb = os.path.getsize(path) / 1024
        name = os.path.basename(path)
        print(f"  {name:<24} {w}x{h}  ({size_kb:.1f} KB)")


if __name__ == "__main__":
    main()
