// CS-002: HLG (BT.2100 / ARIB STD-B67) OETF and EOTF — Metal compute kernels.
// Per ITU-R BT.2100-2 Table 4; constants from ARIB STD-B67.
// OETF: scene linear E ∈ [0,1] → non-linear signal E' ∈ [0,1].
// EOTF: non-linear signal E' ∈ [0,1] → display linear E (for reference display).

#include <metal_stdlib>
using namespace metal;

// BT.2100 HLG constants (ARIB STD-B67)
constant float kHLG_a = 0.17883277f;
constant float kHLG_b = 0.28466892f;   // 1 - 4*a
constant float kHLG_c = 0.55991073f;   // 0.5 - a*ln(4*a)
constant float kHLG_one12 = 1.0f / 12.0f;

// OETF: linear channel value E → HLG signal E'. Applied per R, G, B.
static inline float hlg_oetf_channel(float E) {
    if (E <= kHLG_one12)
        return fast::sqrt(3.0f * E);
    return kHLG_a * fast::log(12.0f * E - kHLG_b) + kHLG_c;
}

// EOTF: HLG signal E' → linear display E. Applied per R, G, B.
static inline float hlg_eotf_channel(float Ep) {
    if (Ep <= 0.5f)
        return (Ep * Ep) / 3.0f;
    return (fast::exp((Ep - kHLG_c) / kHLG_a) + kHLG_b) * kHLG_one12;
}

/// CS-002: Linear RGB → HLG-encoded R'G'B' (OETF). texture(0)=input linear, texture(1)=output HLG.
kernel void hlg_linear_to_hlg_signal(
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
    float4 hlg = float4(hlg_oetf_channel(r), hlg_oetf_channel(g), hlg_oetf_channel(b), linear.a);
    outTexture.write(hlg, gid);
}

/// CS-002: HLG-encoded R'G'B' → linear RGB (EOTF). texture(0)=input HLG, texture(1)=output linear.
kernel void hlg_signal_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height())
        return;
    float4 hlg = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, hlg.r));
    float g = fast::max(0.0f, fast::min(1.0f, hlg.g));
    float b = fast::max(0.0f, fast::min(1.0f, hlg.b));
    float4 linear = float4(hlg_eotf_channel(r), hlg_eotf_channel(g), hlg_eotf_channel(b), hlg.a);
    outTexture.write(linear, gid);
}
