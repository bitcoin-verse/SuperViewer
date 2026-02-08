#!/usr/bin/env python3
"""Generate SuperViewer app icon (assets/superviewer.ico) using only Python stdlib.

Creates a multi-size ICO file with 16x16, 32x32, 48x48, and 256x256 images.
Each size is embedded as a PNG payload inside the ICO container.

Design: bold yellow lightning bolt on a blue-to-purple gradient background
with rounded corners (transparent outside).

Usage:
    python assets/generate_icon.py
"""

import os
import struct
import zlib
import math

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
SIZES = [16, 32, 48, 256]


def write_png_bytes(width, height, pixels):
    """Create a PNG file in memory. pixels is a list of (r, g, b, a) tuples."""

    def make_chunk(chunk_type, data):
        chunk = chunk_type + data
        crc = struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF)
        return struct.pack(">I", len(data)) + chunk + crc

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)

    raw_data = bytearray()
    for y in range(height):
        raw_data.append(0)  # filter: None
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw_data.extend([r, g, b, a])

    compressed = zlib.compress(bytes(raw_data), 9)

    buf = bytearray()
    buf.extend(signature)
    buf.extend(make_chunk(b"IHDR", ihdr_data))
    buf.extend(make_chunk(b"IDAT", compressed))
    buf.extend(make_chunk(b"IEND", b""))
    return bytes(buf)


def lerp_color(c1, c2, t):
    """Linearly interpolate between two (r, g, b) colors."""
    return (
        int(c1[0] + (c2[0] - c1[0]) * t),
        int(c1[1] + (c2[1] - c1[1]) * t),
        int(c1[2] + (c2[2] - c1[2]) * t),
    )


def point_in_polygon(px, py, polygon):
    """Ray-casting point-in-polygon test."""
    n = len(polygon)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = polygon[i]
        xj, yj = polygon[j]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def generate_icon_image(size):
    """Generate a single icon image at the given size.

    Design: lightning bolt on a gradient background with rounded corners.
    """
    pixels = []

    # Colors
    bg_top = (41, 98, 255)       # bright blue
    bg_bottom = (120, 40, 200)   # purple
    bolt_color = (255, 220, 40)  # golden yellow
    bolt_shadow = (200, 160, 0)  # darker yellow for depth

    # Corner radius (proportional to size)
    corner_radius = size * 0.18

    # Lightning bolt polygon (normalized 0-1 coordinates)
    # A bold, slightly stylized lightning bolt
    bolt_points = [
        (0.55, 0.08),   # top
        (0.28, 0.48),   # left mid-upper
        (0.45, 0.48),   # inner left
        (0.35, 0.92),   # bottom
        (0.72, 0.42),   # right mid-lower
        (0.55, 0.42),   # inner right
    ]

    # Shadow offset (normalized)
    shadow_dx = 0.02
    shadow_dy = 0.03

    for y in range(size):
        for x in range(size):
            # Normalized coordinates
            nx = (x + 0.5) / size
            ny = (y + 0.5) / size

            # Rounded rectangle mask
            # Check if point is inside the rounded rect
            alpha = 255
            margin = 0.5 / size  # half-pixel margin for antialiasing

            # Distance from edges
            dx_left = x
            dx_right = size - 1 - x
            dy_top = y
            dy_bottom = size - 1 - y

            # Check corners
            in_rect = True
            if dx_left < corner_radius and dy_top < corner_radius:
                dist = math.sqrt((corner_radius - dx_left) ** 2 + (corner_radius - dy_top) ** 2)
                if dist > corner_radius + 0.5:
                    in_rect = False
                    alpha = 0
                elif dist > corner_radius - 0.5:
                    alpha = int(255 * (corner_radius + 0.5 - dist))
            elif dx_right < corner_radius and dy_top < corner_radius:
                dist = math.sqrt((corner_radius - dx_right) ** 2 + (corner_radius - dy_top) ** 2)
                if dist > corner_radius + 0.5:
                    in_rect = False
                    alpha = 0
                elif dist > corner_radius - 0.5:
                    alpha = int(255 * (corner_radius + 0.5 - dist))
            elif dx_left < corner_radius and dy_bottom < corner_radius:
                dist = math.sqrt((corner_radius - dx_left) ** 2 + (corner_radius - dy_bottom) ** 2)
                if dist > corner_radius + 0.5:
                    in_rect = False
                    alpha = 0
                elif dist > corner_radius - 0.5:
                    alpha = int(255 * (corner_radius + 0.5 - dist))
            elif dx_right < corner_radius and dy_bottom < corner_radius:
                dist = math.sqrt((corner_radius - dx_right) ** 2 + (corner_radius - dy_bottom) ** 2)
                if dist > corner_radius + 0.5:
                    in_rect = False
                    alpha = 0
                elif dist > corner_radius - 0.5:
                    alpha = int(255 * (corner_radius + 0.5 - dist))

            if not in_rect:
                pixels.append((0, 0, 0, 0))
                continue

            # Background gradient (top-to-bottom)
            bg = lerp_color(bg_top, bg_bottom, ny)

            # Check if in shadow
            shadow_points = [(px + shadow_dx, py + shadow_dy) for px, py in bolt_points]
            if point_in_polygon(nx, ny, shadow_points):
                r, g, b = bolt_shadow
                pixels.append((r, g, b, alpha))
                continue

            # Check if in bolt
            if point_in_polygon(nx, ny, bolt_points):
                r, g, b = bolt_color
                pixels.append((r, g, b, alpha))
                continue

            # Background
            r, g, b = bg
            pixels.append((r, g, b, alpha))

    return pixels


def write_ico(path, sizes):
    """Write a multi-size ICO file with PNG payloads."""
    # Generate PNG data for each size
    png_data = []
    for size in sizes:
        pixels = generate_icon_image(size)
        png_bytes = write_png_bytes(size, size, pixels)
        png_data.append(png_bytes)

    num_images = len(sizes)

    # ICO header: 6 bytes
    header = struct.pack("<HHH", 0, 1, num_images)

    # Directory entries: 16 bytes each
    # Data starts after header + directory
    data_offset = 6 + 16 * num_images

    directory = bytearray()
    for i, size in enumerate(sizes):
        # Width/height: 0 means 256
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size
        data_size = len(png_data[i])

        entry = struct.pack(
            "<BBBBHHII",
            w,              # width
            h,              # height
            0,              # color palette count
            0,              # reserved
            1,              # color planes
            32,             # bits per pixel
            data_size,      # data size
            data_offset,    # data offset
        )
        directory.extend(entry)
        data_offset += data_size

    with open(path, "wb") as f:
        f.write(header)
        f.write(bytes(directory))
        for data in png_data:
            f.write(data)


def main():
    ico_path = os.path.join(OUTPUT_DIR, "superviewer.ico")
    write_ico(ico_path, SIZES)

    size_kb = os.path.getsize(ico_path) / 1024
    print(f"Generated {ico_path}")
    print(f"  Sizes: {', '.join(f'{s}x{s}' for s in SIZES)}")
    print(f"  File size: {size_kb:.1f} KB")


if __name__ == "__main__":
    main()
