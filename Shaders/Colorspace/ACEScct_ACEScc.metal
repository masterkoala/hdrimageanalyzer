// CS-010: ACEScct and ACEScc transfer functions — Metal compute kernels.
// References: S-2014-003 (ACEScc), S-2016-001 (ACEScct); colour-science. 0–1 normalised.

#ifndef ACESCCT_ACESCC_METAL
#define ACESCCT_ACESCC_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - ACEScc constants (S-2014-003)

constant float kACEScc_logScale = 17.52f;
constant float kACEScc_logOffset = 9.72f;
constant float kACEScc_linearUpper = 0.000030517578125f;  // 2^-15
constant float kACEScc_minCV = -0.3584474886f;   // (log2(2^-16)+9.72)/17.52
constant float kACEScc_logStart = -0.3014292603f; // (log2(2^-15)+9.72)/17.52

static inline float acescc_oetf_channel(float x) {
    x = fast::max(0.0f, fast::min(1.0f, x));
    if (x <= 0.0f) return kACEScc_minCV;
    if (x < kACEScc_linearUpper)
        return (log2(1.0f / 65536.0f + x * 0.5f) + kACEScc_logOffset) / kACEScc_logScale;
    return (log2(x) + kACEScc_logOffset) / kACEScc_logScale;
}

static inline float acescc_eotf_channel(float cv) {
    cv = fast::max(kACEScc_minCV, fast::min(1.0f, cv));
    if (cv < kACEScc_logStart)
        return (pow(2.0f, cv * kACEScc_logScale - kACEScc_logOffset) - 1.0f / 65536.0f) * 2.0f;
    return fast::min(1.0f, pow(2.0f, cv * kACEScc_logScale - kACEScc_logOffset));
}

// MARK: - ACEScct constants (S-2016-001)

constant float kACEScct_XBrk = 0.0078125f;
constant float kACEScct_YBrk = 0.155251141552511f;
constant float kACEScct_A = 10.5402377416545f;
constant float kACEScct_B = 0.0729055341958355f;

static inline float acescct_oetf_channel(float x) {
    x = fast::max(0.0f, fast::min(1.0f, x));
    if (x <= kACEScct_XBrk)
        return kACEScct_A * x + kACEScct_B;
    return (log2(x) + kACEScc_logOffset) / kACEScc_logScale;
}

static inline float acescct_eotf_channel(float cv) {
    cv = fast::max(-0.36f, fast::min(1.468f, cv));  // ACEScct valid code-value range per SMPTE S-2016-001
    if (cv > kACEScct_YBrk)
        return pow(2.0f, cv * kACEScc_logScale - kACEScc_logOffset);
    return fast::max(0.0f, (cv - kACEScct_B) / kACEScct_A);
}

// MARK: - Kernels

/// CS-010: Linear RGB → ACEScc (OETF). texture(0)=input linear, texture(1)=output ACEScc.
kernel void acescc_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float4 acescc = float4(
        acescc_oetf_channel(linear.r),
        acescc_oetf_channel(linear.g),
        acescc_oetf_channel(linear.b),
        linear.a);
    outTexture.write(acescc, gid);
}

/// CS-010: ACEScc → linear RGB (EOTF).
kernel void acescc_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 acescc = inputTexture.read(gid);
    float4 linear = float4(
        acescc_eotf_channel(acescc.r),
        acescc_eotf_channel(acescc.g),
        acescc_eotf_channel(acescc.b),
        acescc.a);
    outTexture.write(linear, gid);
}

/// CS-010: Linear RGB → ACEScct (OETF).
kernel void acescct_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float4 acescct = float4(
        acescct_oetf_channel(linear.r),
        acescct_oetf_channel(linear.g),
        acescct_oetf_channel(linear.b),
        linear.a);
    outTexture.write(acescct, gid);
}

/// CS-010: ACEScct → linear RGB (EOTF).
kernel void acescct_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 acescct = inputTexture.read(gid);
    float4 linear = float4(
        acescct_eotf_channel(acescct.r),
        acescct_eotf_channel(acescct.g),
        acescct_eotf_channel(acescct.b),
        acescct.a);
    outTexture.write(linear, gid);
}

#endif
