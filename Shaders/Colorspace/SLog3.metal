// CS-006: Sony SLog3 OETF and EOTF — Metal compute kernels.
// Per Sony Technical Summary S-Gamut3.Cine/S-Log3; formulae from Colour Science (normalised 0–1).
// OETF: scene linear → SLog3 signal. EOTF: SLog3 signal → linear.

#ifndef SLOG3_METAL
#define SLOG3_METAL

#include <metal_stdlib>
using namespace metal;

// SLog3 constants (0–1 normalised; derived from 10-bit 420/261.5/95/1023)
constant float kSLog3_linearSegmentThreshold = 0.01125000f;   // linear segment cutoff
constant float kSLog3_logThreshold = 171.2102946929f / 1023.0f;  // decoding linear segment cutoff
constant float kSLog3_scale = (171.2102946929f - 95.0f) / 0.01125000f;  // 76.2102946929 / 0.01125
constant float kSLog3_offset = 95.0f / 1023.0f;
constant float kSLog3_denom = 171.2102946929f - 95.0f;
constant float kSLog3_logScale = 261.5f;
constant float kSLog3_logOffset = 420.0f;
constant float kSLog3_ratio = 0.18f + 0.01f;  // (0.18 + 0.01)
constant float kSLog3_in = 0.01f;

// OETF: linear channel value (reflection, 0–1) → SLog3 signal (0–1).
static inline float slog3_oetf_channel(float x) {
    if (x >= kSLog3_linearSegmentThreshold)
        return (kSLog3_logOffset + fast::log10((x + kSLog3_in) / kSLog3_ratio) * kSLog3_logScale) / 1023.0f;
    return (x * kSLog3_scale + 95.0f) / 1023.0f;
}

// EOTF: SLog3 signal (0–1) → linear channel value.
static inline float slog3_eotf_channel(float y) {
    if (y >= kSLog3_logThreshold)
        return fast::pow(10.0f, (y * 1023.0f - kSLog3_logOffset) / kSLog3_logScale) * kSLog3_ratio - kSLog3_in;
    return (y * 1023.0f - 95.0f) * 0.01125000f / kSLog3_denom;
}

/// CS-006: Linear RGB → SLog3-encoded R'G'B' (OETF). texture(0)=input linear, texture(1)=output SLog3.
kernel void slog3_linear_to_slog3_signal(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height())
        return;
    float4 linear = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, linear.r));
    float g = fast::max(0.0f, fast::min(1.0f, linear.g));
    float b = fast::max(0.0f, fast::min(1.0f, linear.b));
    float4 slog3 = float4(slog3_oetf_channel(r), slog3_oetf_channel(g), slog3_oetf_channel(b), linear.a);
    outTexture.write(slog3, gid);
}

/// CS-006: SLog3-encoded R'G'B' → linear RGB (EOTF). texture(0)=input SLog3, texture(1)=output linear.
kernel void slog3_signal_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height())
        return;
    float4 slog3 = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, slog3.r));
    float g = fast::max(0.0f, fast::min(1.0f, slog3.g));
    float b = fast::max(0.0f, fast::min(1.0f, slog3.b));
    float4 linear = float4(slog3_eotf_channel(r), slog3_eotf_channel(g), slog3_eotf_channel(b), slog3.a);
    outTexture.write(linear, gid);
}

#endif
