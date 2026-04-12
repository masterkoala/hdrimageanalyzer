# Color Transform Test Images (CS-018)

Comprehensive test images for color transform and pipeline validation. Values align with `Sources/Color/ReferenceTestPatterns.swift` (BT.709 linear RGB; stored as sRGB in PNG).

## Regenerating

From repo root:

```bash
python3 Scripts/generate_color_test_images.py
```

## Files

| File | Description |
|------|-------------|
| `grayscale_ramp.png` | 5-patch horizontal ramp (0%, 25%, 50%, 75%, 100%) — 320×48 |
| `rec709_color_bars.png` | 8 vertical Rec.709/SMPTE-style bars — 640×480 |
| `black.png`, `neutral_grey.png`, `white.png` | 16×16 single-patch (black, 50% grey, white) |
| `red_709.png`, `green_709.png`, `blue_709.png` | 16×16 Rec.709 primaries |
| `verification_grid.png` | 4×3 grid of verification patches — 256×192 |
| `linear_ramp_11.png` | 11-step horizontal ramp (0–100%) — 352×32 |

Used by ColorTests and pipeline tests to validate YCbCr→RGB, gamut, and display transforms.
