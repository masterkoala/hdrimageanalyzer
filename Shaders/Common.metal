//
// Common.shady — Shared constants, types, and helper functions for all shaders
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Pixel Formats

constexpr sampler rgbaSampler(
    min_filter::linear,
    mag_filter::linear,
    address::repeat
);

// MARK: - Math Helpers

/// Linear interpolate between two values
template<typename T>
inline T lerp(T a, T b, float t) {
    return a + (b - a) * t;
}

/// Clamp value to range [min, max]
template<typename T>
inline T clamp(T val, T minVal, T maxVal) {
    return min(max(val, minVal), maxVal);
}

/// Convert RGB to luminance (BT.709)
inline float rgbToLuminance(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}