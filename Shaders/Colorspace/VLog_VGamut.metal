// CS-008: Panasonic V-Log OETF/EOTF — Metal compute kernels.
// Formulae from Panasonic VARICAM V-Log/V-Gamut whitepaper; antlerpost.com (0–1 normalised).
// V-Gamut matrix in GamutConversion.metal (kVGamut_RGB_to_XYZ). OETF: scene linear → log; EOTF: log → linear.

#ifndef VLOG_VGAMUT_METAL
#define VLOG_VGAMUT_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - V-Log constants (Panasonic; 0–1)

constant float kVLog_cut1 = 0.01f;
constant float kVLog_cut2 = 0.181f;
constant float kVLog_b = 0.00873f;
constant float kVLog_c = 0.241514f;
constant float kVLog_d = 0.598206f;
constant float kVLog_linearSlope = 5.6f;
constant float kVLog_linearOffset = 0.125f;

static inline float vlog_oetf_channel(float L) {
    L = fast::max(0.0f, fast::min(1.0f, L));
    if (L < kVLog_cut1)
        return kVLog_linearSlope * L + kVLog_linearOffset;
    return kVLog_c * fast::log10(L + kVLog_b) + kVLog_d;
}

static inline float vlog_eotf_channel(float V) {
    V = fast::max(0.0f, fast::min(1.0f, V));
    if (V < kVLog_cut2)
        return (V - kVLog_linearOffset) / kVLog_linearSlope;
    return fast::pow(10.0f, (V - kVLog_d) / kVLog_c) - kVLog_b;
}

// MARK: - Kernels

/// CS-008: Linear RGB → V-Log R'G'B' (OETF). texture(0)=input linear, texture(1)=output V-Log.
kernel void vlog_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float4 vlog = float4(
        vlog_oetf_channel(linear.r),
        vlog_oetf_channel(linear.g),
        vlog_oetf_channel(linear.b),
        linear.a);
    outTexture.write(vlog, gid);
}

/// CS-008: V-Log R'G'B' → linear RGB (EOTF). texture(0)=input V-Log, texture(1)=output linear.
kernel void vlog_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 vlog = inputTexture.read(gid);
    float4 linear = float4(
        vlog_eotf_channel(vlog.r),
        vlog_eotf_channel(vlog.g),
        vlog_eotf_channel(vlog.b),
        vlog.a);
    outTexture.write(linear, gid);
}

#endif
