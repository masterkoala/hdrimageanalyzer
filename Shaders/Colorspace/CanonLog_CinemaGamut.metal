// CS-007: Canon Log2 and Log3 OETF/EOTF — Metal compute kernels.
// Formulae from Canon white papers / Colour Science (normalised 0–1). Cinema Gamut primaries in GamutConversion.metal (kCinemaGamut_RGB_to_XYZ).
// OETF: scene linear → log signal. EOTF: log signal → linear.

#ifndef CANON_LOG_CINEMA_GAMUT_METAL
#define CANON_LOG_CINEMA_GAMUT_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - Canon Log2 constants (v1.2 style; 0–1 normalised. Canon2020 / Colour Science)
// OETF: y = 0.24136077 * log10(x * 87.09937546 + 1) + 0.092864125
// EOTF: x = (10^((y - 0.092864125) / 0.24136077) - 1) / 87.09937546
constant float kCanonLog2_scale = 87.09937546f;
constant float kCanonLog2_logCoeff = 0.24136077f;
constant float kCanonLog2_offset = 0.092864125f;

static inline float canon_log2_oetf_channel(float x) {
    x = fast::max(0.0f, fast::min(1.0f, x));
    return kCanonLog2_logCoeff * fast::log10(x * kCanonLog2_scale + 1.0f) + kCanonLog2_offset;
}

static inline float canon_log2_eotf_channel(float y) {
    y = fast::max(0.0f, fast::min(1.0f, y));
    if (y <= kCanonLog2_offset)
        return 0.0f;
    return (fast::pow(10.0f, (y - kCanonLog2_offset) / kCanonLog2_logCoeff) - 1.0f) / kCanonLog2_scale;
}

// MARK: - Canon Log3 constants (v1.2 style; three segments. Canon2020 / Colour Science)
// Linear segment: clog3 = 1.9754798 * x + 0.12512219  ↔  x = (clog3 - 0.12512219) / 1.9754798
// High (log): clog3 = 0.36726845 * log10(x * 14.98325 + 1) + 0.12240537
// Low (negative): clog3 = -0.36726845 * log10(-x * 14.98325 + 1) + 0.12783901
constant float kCanonLog3_linearSlope = 1.9754798f;
constant float kCanonLog3_linearOffset = 0.12512219f;
constant float kCanonLog3_logScale = 14.98325f;
constant float kCanonLog3_logCoeff = 0.36726845f;
constant float kCanonLog3_logOffset = 0.12240537f;
constant float kCanonLog3_lowOffset = 0.12783901f;
constant float kCanonLog3_linearLow = 0.097465473f;   // code value at linear segment start
constant float kCanonLog3_linearHigh = 0.15277891f;  // code value at linear segment end
constant float kCanonLog3_linearBreak = (kCanonLog3_linearHigh - kCanonLog3_linearOffset) / kCanonLog3_linearSlope;  // ~0.01401

static inline float canon_log3_oetf_channel(float x) {
    x = fast::max(0.0f, fast::min(1.0f, x));
    if (x > kCanonLog3_linearBreak)
        return kCanonLog3_logCoeff * fast::log10(x * kCanonLog3_logScale + 1.0f) + kCanonLog3_logOffset;
    return kCanonLog3_linearSlope * x + kCanonLog3_linearOffset;
}

static inline float canon_log3_eotf_channel(float y) {
    y = fast::max(0.0f, fast::min(1.0f, y));
    if (y <= kCanonLog3_linearLow)
        return 0.0f;  // below linear segment; extended range would use negative branch
    if (y <= kCanonLog3_linearHigh)
        return (y - kCanonLog3_linearOffset) / kCanonLog3_linearSlope;
    return (fast::pow(10.0f, (y - kCanonLog3_logOffset) / kCanonLog3_logCoeff) - 1.0f) / kCanonLog3_logScale;
}

// MARK: - Kernels

/// CS-007: Linear RGB → Canon Log2-encoded R'G'B' (OETF). texture(0)=input linear, texture(1)=output Canon Log2.
kernel void canon_log2_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float4 log2 = float4(
        canon_log2_oetf_channel(linear.r),
        canon_log2_oetf_channel(linear.g),
        canon_log2_oetf_channel(linear.b),
        linear.a);
    outTexture.write(log2, gid);
}

/// CS-007: Canon Log2-encoded R'G'B' → linear RGB (EOTF). texture(0)=input Canon Log2, texture(1)=output linear.
kernel void canon_log2_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 log2 = inputTexture.read(gid);
    float4 linear = float4(
        canon_log2_eotf_channel(log2.r),
        canon_log2_eotf_channel(log2.g),
        canon_log2_eotf_channel(log2.b),
        log2.a);
    outTexture.write(linear, gid);
}

/// CS-007: Linear RGB → Canon Log3-encoded R'G'B' (OETF). texture(0)=input linear, texture(1)=output Canon Log3.
kernel void canon_log3_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float4 log3 = float4(
        canon_log3_oetf_channel(linear.r),
        canon_log3_oetf_channel(linear.g),
        canon_log3_oetf_channel(linear.b),
        linear.a);
    outTexture.write(log3, gid);
}

/// CS-007: Canon Log3-encoded R'G'B' → linear RGB (EOTF). texture(0)=input Canon Log3, texture(1)=output linear.
kernel void canon_log3_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 log3 = inputTexture.read(gid);
    float4 linear = float4(
        canon_log3_eotf_channel(log3.r),
        canon_log3_eotf_channel(log3.g),
        canon_log3_eotf_channel(log3.b),
        log3.a);
    outTexture.write(linear, gid);
}

#endif
