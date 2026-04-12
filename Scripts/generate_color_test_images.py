#!/usr/bin/env python3
"""
CS-018: Generate comprehensive color transform test images for HDR Image Analyzer Pro.
Output: Tests/ColorTests/Resources/*.png
Values match Sources/Color/ReferenceTestPatterns.swift (BT.709 linear RGB → sRGB for PNG).
Run from repo root: python3 Scripts/generate_color_test_images.py
"""

import zlib
import struct
import os
import sys

# BT.709 linear RGB [0,1] → sRGB 8-bit (for PNG display)
def linear_to_srgb(c: float) -> int:
    if c <= 0.0031308:
        s = 12.92 * c
    else:
        s = 1.055 * (c ** (1.0 / 2.4)) - 0.055
    return max(0, min(255, int(round(s * 255))))

def write_png_rgb(path: str, width: int, height: int, rgb_rows: list) -> None:
    """Write a PNG file (Truecolor 8-bit, no alpha). rgb_rows: list of (r,g,b) tuples per pixel, row-major."""
    def png_pack(tag: bytes, data: bytes) -> bytes:
        chunk = tag + data
        return struct.pack("!I", len(data)) + chunk + struct.pack("!I", 0xFFFFFFFF & zlib.crc32(chunk))
    # Build raw scanlines: filter byte 0 then R,G,B per pixel. PNG rows top-to-bottom.
    raw = b""
    for y in range(height):
        raw += b"\x00"
        for x in range(width):
            idx = y * width + x
            r, g, b = rgb_rows[idx]
            raw += bytes([r, g, b])
    # PNG expects first row = top; our rgb_rows is row 0 = top.
    row_bytes = width * 3
    raw_data = b"".join(b"\x00" + raw[1 + i * row_bytes : 1 + (i + 1) * row_bytes]
                        for i in range(height))
    compressed = zlib.compress(raw_data, 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(png_pack(b"IHDR", struct.pack("!2I5B", width, height, 8, 2, 0, 0, 0)))
        f.write(png_pack(b"IDAT", compressed))
        f.write(png_pack(b"IEND", b""))
    print("Wrote", path)

# Reference patches: linear RGB [0,1] (from ReferenceTestPatterns / BT.709 YCbCr→RGB)
GRAYSCALE_RAMP = [
    (0.0, 0.0, 0.0), (0.25, 0.25, 0.25), (0.5, 0.5, 0.5), (0.75, 0.75, 0.75), (1.0, 1.0, 1.0)
]
REC709_COLOR_BARS = [
    (1.0, 1.0, 1.0),      # White
    (1.0, 0.630, 0.0),    # Yellow
    (0.0, 0.782, 0.738),  # Cyan
    (0.0, 0.771, 0.0),    # Green
    (0.526, 0.35, 0.549), # Magenta
    (0.437, 0.276, 0.46), # Red (75% bar)
    (0.0, 0.361, 0.316),  # Blue
    (0.0, 0.0, 0.0),      # Black
]

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    out_dir = os.path.join(repo_root, "Tests", "ColorTests", "Resources")
    os.makedirs(out_dir, exist_ok=True)

    # 1) grayscale_ramp.png — horizontal 5-patch ramp (each patch 64px wide, 48px tall)
    patch_w, patch_h = 64, 48
    w, h = 5 * patch_w, patch_h
    pixels = []
    for py in range(h):
        for px in range(w):
            patch_idx = min(px // patch_w, 4)
            r, g, b = GRAYSCALE_RAMP[patch_idx]
            pixels.append((linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)))
    write_png_rgb(os.path.join(out_dir, "grayscale_ramp.png"), w, h, pixels)

    # 2) rec709_color_bars.png — 8 vertical bars (each bar 80px wide, 480px tall)
    bar_w, bar_h = 80, 480
    w, h = 8 * bar_w, bar_h
    pixels = []
    for py in range(h):
        for px in range(w):
            bar_idx = min(px // bar_w, 7)
            r, g, b = REC709_COLOR_BARS[bar_idx]
            pixels.append((linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)))
    write_png_rgb(os.path.join(out_dir, "rec709_color_bars.png"), w, h, pixels)

    # 3) Single-patch images (16x16) for load/sample tests
    def single_patch(filename: str, r: float, g: float, b: float) -> None:
        pix = [(linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b))] * (16 * 16)
        write_png_rgb(os.path.join(out_dir, filename), 16, 16, pix)

    single_patch("black.png", 0.0, 0.0, 0.0)
    single_patch("neutral_grey.png", 0.5, 0.5, 0.5)
    single_patch("white.png", 1.0, 1.0, 1.0)
    single_patch("red_709.png", 1.0, 0.0, 0.0)
    single_patch("green_709.png", 0.0, 1.0, 0.0)
    single_patch("blue_709.png", 0.0, 0.0, 1.0)

    # 4) verification_grid.png — 4x4 grid of verification patches (grayscale + key bars)
    # Patches: Black, 25% Grey, 50% Grey, 75% Grey, White, Yellow, Cyan, Green, Magenta, Red, Blue (11 unique)
    grid_patches = [
        (0.0, 0.0, 0.0), (0.25, 0.25, 0.25), (0.5, 0.5, 0.5), (0.75, 0.75, 0.75), (1.0, 1.0, 1.0),
        (1.0, 0.630, 0.0), (0.0, 0.782, 0.738), (0.0, 0.771, 0.0), (0.526, 0.35, 0.549),
        (0.437, 0.276, 0.46), (0.0, 0.361, 0.316),
    ]
    cell = 64
    cols, rows = 4, 3
    w, h = cols * cell, rows * cell
    pixels = []
    for py in range(h):
        for px in range(w):
            cy, cx = py // cell, px // cell
            idx = cy * cols + cx
            if idx < len(grid_patches):
                r, g, b = grid_patches[idx]
            else:
                r, g, b = 0.2, 0.2, 0.2  # fill
            pixels.append((linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(b)))
    write_png_rgb(os.path.join(out_dir, "verification_grid.png"), w, h, pixels)

    # 5) linear_ramp_11.png — 11-step horizontal ramp (0%, 10%, ..., 100%) for finer transform tests
    steps = 11
    ramp_w, ramp_h = steps * 32, 32
    w, h = ramp_w, ramp_h
    pixels = []
    for py in range(h):
        for px in range(w):
            step = min(px // 32, steps - 1)
            v = step / (steps - 1)
            pixels.append((linear_to_srgb(v), linear_to_srgb(v), linear_to_srgb(v)))
    write_png_rgb(os.path.join(out_dir, "linear_ramp_11.png"), w, h, pixels)

    print("Done. Test images in", out_dir)
    return 0

if __name__ == "__main__":
    sys.exit(main() or 0)
