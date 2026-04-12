// FC-001: False Color overlay — professional IRE-range false color visualization.
// Similar to Nobe Omniscope false color; maps luminance to configurable color ranges
// with smooth 1-IRE fade transitions at boundaries for broadcast-quality output.

#ifndef FALSECOLOR_METAL
#define FALSECOLOR_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - Constants

/// Maximum number of configurable false color ranges.
constant uint kFalseColorMaxRanges = 16;

/// Width of the smooth transition zone at range boundaries, expressed in normalized units.
/// 1 IRE = 1/100 of full range, so 0.01 in normalized [0,1] space.
constant float kFalseColorFadeZone = 0.01f;

// BT.709 luminance coefficients (standard for HD/SDR content).
constant float3 kBT709Coefficients = float3(0.2126f, 0.7152f, 0.0722f);

// BT.2020 luminance coefficients (wide colour gamut / HDR content).
constant float3 kBT2020Coefficients = float3(0.2627f, 0.6780f, 0.0593f);

// MARK: - Structs

/// A single false color range mapping a luminance band to an RGBA color.
/// lowerNorm and upperNorm are normalised [0,1] bounds (0 = 0 IRE, 1 = 100 IRE).
struct FalseColorRange {
    float lowerNorm;   // normalised lower bound (inclusive)
    float upperNorm;   // normalised upper bound (inclusive)
    float4 color;      // RGBA overlay color for this range
};

/// Parameters controlling the false color overlay behaviour.
struct FalseColorParams {
    uint rangeCount;   // number of active ranges (0..kFalseColorMaxRanges)
    float opacity;     // blend strength 0 (transparent) .. 1 (full overlay)
    uint mode;         // 0 = BT.709 luminance, 1 = BT.2020 luminance, 2 = max channel
};

// MARK: - Helpers

/// Compute a single luminance value from an RGB pixel according to the selected mode.
static inline float compute_luminance(float3 rgb, uint mode) {
    switch (mode) {
        case 1:  return dot(rgb, kBT2020Coefficients);
        case 2:  return max(rgb.r, max(rgb.g, rgb.b));
        default: return dot(rgb, kBT709Coefficients);
    }
}

/// Look up the false color for a given normalised luminance.
/// Uses smooth (hermite) blending across a 1-IRE fade zone at each boundary
/// so adjacent ranges transition cleanly rather than producing hard edges.
static inline float4 lookup_false_color(float luminance,
                                        constant FalseColorRange* ranges,
                                        uint rangeCount) {
    float4 result = float4(0.0f);
    float totalWeight = 0.0f;

    for (uint i = 0; i < rangeCount; i++) {
        float lower = ranges[i].lowerNorm;
        float upper = ranges[i].upperNorm;
        float4 col  = ranges[i].color;

        // Compute smooth fade-in at lower boundary and fade-out at upper boundary.
        // smoothstep provides a hermite interpolation across the fade zone.
        float fadeIn  = smoothstep(lower - kFalseColorFadeZone, lower + kFalseColorFadeZone, luminance);
        float fadeOut = 1.0f - smoothstep(upper - kFalseColorFadeZone, upper + kFalseColorFadeZone, luminance);

        float weight = fadeIn * fadeOut;
        result += col * weight;
        totalWeight += weight;
    }

    // Normalise accumulated colour if any ranges contributed.
    if (totalWeight > 0.0f) {
        result /= totalWeight;
    }
    return result;
}

// MARK: - Kernel: False Color Overlay

/// FC-001: Apply false color overlay to an image.
/// For each pixel, computes luminance, finds the matching false-color range(s),
/// and blends the overlay colour with the original pixel at the requested opacity.
///
/// texture(0) = input image (read)
/// texture(1) = output image (write)
/// buffer(0)  = FalseColorRange[kFalseColorMaxRanges]
/// buffer(1)  = FalseColorParams
kernel void false_color_overlay(
    texture2d<float, access::read>      inputTexture  [[texture(0)]],
    texture2d<float, access::write>     outputTexture [[texture(1)]],
    constant FalseColorRange*           ranges        [[buffer(0)]],
    constant FalseColorParams&          params        [[buffer(1)]],
    uint2                               gid           [[thread_position_in_grid]])
{
    // Bounds check — threads outside the image are no-ops.
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height())
        return;

    float4 pixel = inputTexture.read(gid);
    float3 rgb = pixel.rgb;

    // Compute luminance according to the selected mode.
    float luminance = compute_luminance(rgb, params.mode);
    luminance = saturate(luminance);  // clamp to [0,1]

    // Look up the false colour for this luminance value.
    float4 falseColor = lookup_false_color(luminance, ranges, min(params.rangeCount, kFalseColorMaxRanges));

    // Blend: mix original pixel with false colour using the overlay opacity
    // and the per-range alpha channel for fine control.
    float blendAlpha = params.opacity * falseColor.a;
    float3 blended = mix(rgb, falseColor.rgb, blendAlpha);

    outputTexture.write(float4(blended, pixel.a), gid);
}

// MARK: - Kernel: False Color Legend

/// FC-001: Generate a horizontal gradient bar visualising the configured IRE ranges.
/// Each column maps to a normalised luminance from 0 (left) to 1 (right).
/// Rows are filled uniformly with the false colour for that luminance value.
/// This produces a colour key / legend strip suitable for on-screen display.
///
/// texture(0) = output legend texture (write)
/// buffer(0)  = FalseColorRange[kFalseColorMaxRanges]
/// buffer(1)  = FalseColorParams
kernel void false_color_legend(
    texture2d<float, access::write>     outputTexture [[texture(0)]],
    constant FalseColorRange*           ranges        [[buffer(0)]],
    constant FalseColorParams&          params        [[buffer(1)]],
    uint2                               gid           [[thread_position_in_grid]])
{
    uint width  = outputTexture.get_width();
    uint height = outputTexture.get_height();

    if (gid.x >= width || gid.y >= height)
        return;

    // Map horizontal position to normalised luminance [0,1].
    float luminance = float(gid.x) / float(max(width - 1u, 1u));

    // Look up the false colour for this luminance value.
    float4 falseColor = lookup_false_color(luminance, ranges, min(params.rangeCount, kFalseColorMaxRanges));

    // Use a dark neutral background where no range is defined so the
    // legend clearly shows gaps between ranges.
    float4 background = float4(0.12f, 0.12f, 0.12f, 1.0f);
    float3 legendColor = mix(background.rgb, falseColor.rgb, falseColor.a);

    // Draw thin border lines at top and bottom for visual separation (1 px each).
    if (gid.y == 0 || gid.y == height - 1) {
        legendColor = float3(0.3f, 0.3f, 0.3f);
    }

    // Draw tick marks at every 10 IRE (10% increments) for easy reading.
    float ireNorm = luminance * 100.0f;
    float modVal = fmod(ireNorm + 0.5f, 10.0f);  // +0.5 centres the tick
    if (modVal < 1.0f && gid.y < height / 4u) {
        legendColor = float3(0.8f, 0.8f, 0.8f);
    }

    outputTexture.write(float4(legendColor, 1.0f), gid);
}

#endif
