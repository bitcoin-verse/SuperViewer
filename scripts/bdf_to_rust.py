#!/usr/bin/env python3
"""Convert a BDF bitmap font file to a Rust const byte array indexed by CP437.

Usage: python bdf_to_rust.py <input.bdf> [--output <output.rs>]

Reads a BDF font file (Unicode-encoded glyphs), remaps to CP437 byte order,
and outputs a Rust `pub const FONT_8X16: [u8; 4096]` array.
"""

import sys
import argparse
from pathlib import Path

# CP437 byte -> Unicode codepoint mapping (256 entries)
# Positions 0x20-0x7E are identity. 0x00-0x1F and 0x7F-0xFF need remapping.
CP437_TO_UNICODE = [
    # 0x00-0x0F
    0x0000, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022,
    0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
    # 0x10-0x1F
    0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8,
    0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC,
    # 0x20-0x7E: ASCII (identity mapping)
    *range(0x20, 0x7F),
    # 0x7F
    0x2302,
    # 0x80-0x8F
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
    0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    # 0x90-0x9F
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
    # 0xA0-0xAF
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
    0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    # 0xB0-0xBF
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
    0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    # 0xC0-0xCF
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    # 0xD0-0xDF
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
    0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    # 0xE0-0xEF
    0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
    0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
    # 0xF0-0xFF
    0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
    0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
]

assert len(CP437_TO_UNICODE) == 256


def parse_bdf(path: Path) -> dict[int, list[int]]:
    """Parse a BDF file and return {unicode_codepoint: [16 bytes]}."""
    glyphs = {}
    encoding = None
    in_bitmap = False
    rows = []

    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("ENCODING "):
                encoding = int(line.split()[1])
            elif line == "BITMAP":
                in_bitmap = True
                rows = []
            elif line == "ENDCHAR":
                if encoding is not None and in_bitmap:
                    # Pad or truncate to exactly 16 rows
                    while len(rows) < 16:
                        rows.append(0)
                    glyphs[encoding] = rows[:16]
                encoding = None
                in_bitmap = False
                rows = []
            elif in_bitmap:
                rows.append(int(line, 16))

    return glyphs


def generate_rust_array(glyphs: dict[int, list[int]]) -> str:
    """Generate Rust const array string from CP437-remapped glyphs."""
    lines = []
    lines.append("// Spleen 8x16 2.2.0 by Frederic Cambus (BSD 2-Clause)")
    lines.append("// https://github.com/fcambus/spleen")
    lines.append("// Converted from BDF to CP437-indexed byte array")
    lines.append("#[rustfmt::skip]")
    lines.append("pub const FONT_8X16: [u8; 4096] = [")

    for cp437_byte in range(256):
        unicode_cp = CP437_TO_UNICODE[cp437_byte]
        glyph_rows = glyphs.get(unicode_cp, [0] * 16)

        if cp437_byte < 0x20:
            label = f"0x{cp437_byte:02X}"
        elif cp437_byte < 0x7F:
            label = f"0x{cp437_byte:02X}: {chr(cp437_byte)}"
        elif cp437_byte == 0x7F:
            label = "0x7F: DEL"
        else:
            label = f"0x{cp437_byte:02X} (U+{unicode_cp:04X})"

        hex_bytes = ", ".join(f"0x{b:02X}" for b in glyph_rows)
        lines.append(f"    // {label}")
        lines.append(f"    {hex_bytes},")

    lines.append("];")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Convert BDF font to Rust CP437 array")
    parser.add_argument("input", help="Input BDF file path")
    parser.add_argument("--output", "-o", help="Output file (default: stdout)")
    args = parser.parse_args()

    bdf_path = Path(args.input)
    if not bdf_path.exists():
        print(f"Error: {bdf_path} not found", file=sys.stderr)
        sys.exit(1)

    glyphs = parse_bdf(bdf_path)
    print(f"Parsed {len(glyphs)} glyphs from {bdf_path.name}", file=sys.stderr)

    # Check coverage
    missing = []
    for i in range(0x20, 0x7F):
        if CP437_TO_UNICODE[i] not in glyphs:
            missing.append(i)
    if missing:
        print(f"Warning: missing ASCII glyphs: {missing}", file=sys.stderr)

    rust_code = generate_rust_array(glyphs)

    if args.output:
        Path(args.output).write_text(rust_code)
        print(f"Wrote to {args.output}", file=sys.stderr)
    else:
        print(rust_code)


if __name__ == "__main__":
    main()
