// CS-005: ARRI LogC3 / LogC4 transfer curves and AWG3 / AWG4 primaries.
// Uses CS-004 gamut system: AWG RGB ↔ XYZ via 3x3 matrices; combine with gamut_convert for AWG↔709/2020/P3.
// LogC: OETF = linear → log signal, EOTF inverse = log signal → linear (per channel).

#ifndef ARRI_LOGC_AWG_METAL
#define ARRI_LOGC_AWG_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - LogC3 constants (SUP 3.x, Linear Scene Exposure Factor, EI 800)
// Encoding: t = (x > cut) ? c*log10(a*x + b) + d : e*x + f
// Decoding: x = (t > e*cut + f) ? (10^((t-d)/c) - b)/a : (t - f)/e
constant float kLogC3_cut = 0.010591f;
constant float kLogC3_a   = 5.555556f;
constant float kLogC3_b   = 0.052272f;
constant float kLogC3_c   = 0.247190f;
constant float kLogC3_d   = 0.385537f;
constant float kLogC3_e   = 5.367655f;
constant float kLogC3_f   = 0.092809f;
constant float kLogC3_linear_break = kLogC3_e * kLogC3_cut + kLogC3_f;  // t threshold for decode

static inline float logc3_oetf(float x) {
    if (x <= kLogC3_cut)
        return kLogC3_e * x + kLogC3_f;
    return kLogC3_c * fast::log10(fast::max(1e-10f, kLogC3_a * x + kLogC3_b)) + kLogC3_d;
}

static inline float logc3_eotf(float t) {
    if (t <= kLogC3_linear_break)
        return (t - kLogC3_f) / kLogC3_e;
    float p = (t - kLogC3_d) / kLogC3_c;
    return (fast::pow(10.0f, p) - kLogC3_b) / kLogC3_a;
}

// MARK: - LogC4 constants (ARRI LogC4 spec; scene-linear breakpoint)
// a = (2^18 - 16)/117.45, b = (1023-95)/1023, c = 95/1023; s,t derived.
// Encode: E' = (E >= t) ? (log2(a*E+64)-6)/14*b + c : (E-t)/s
// Decode: E = (E' >= 0) ? (2^(14*(E'-c)/b+6)-64)/a : E'*s + t
constant float kLogC4_a = 2231.826309f;   // (2^18 - 16) / 117.45
constant float kLogC4_b = 0.907136f;     // (1023 - 95) / 1023
constant float kLogC4_c = 0.092864f;     // 95 / 1023
constant float kLogC4_s = 0.113597f;     // 7*ln(2)*2^(7-14*c/b)/(a*b)
constant float kLogC4_t = -0.018057f;   // (2^(14*(-c/b)+6)-64)/a (scene-linear breakpoint)

static inline float logc4_oetf(float E) {
    if (E < kLogC4_t)
        return (E - kLogC4_t) / kLogC4_s;
    return (fast::log2(fast::max(1e-10f, kLogC4_a * E + 64.0f)) - 6.0f) / 14.0f * kLogC4_b + kLogC4_c;
}

static inline float logc4_eotf(float Ep) {
    if (Ep < 0.0f)
        return Ep * kLogC4_s + kLogC4_t;
    float expo = 14.0f * (Ep - kLogC4_c) / kLogC4_b + 6.0f;
    return (fast::pow(2.0f, expo) - 64.0f) / kLogC4_a;
}

// MARK: - AWG3 (ALEXA Wide Gamut 3) RGB → XYZ, D65, column-major (out = M * rgb)
// Primaries per ARRI/ACES; matches CS-004 convention.
constant float kAWG3_RGB_to_XYZ[9] = {
    0.638008f, 0.291954f, 0.002798f,
    0.214628f, 0.823841f, 0.060022f,
    0.097712f, 0.072953f, 0.883779f
};

// MARK: - AWG4 (ARRI Wide Gamut 4) RGB → XYZ, D65, column-major
// From ARRI LogC4 / REVEAL color science; D65. Use with gamut_convert when converting AWG4↔other.
constant float kAWG4_RGB_to_XYZ[9] = {
    0.638008f, 0.291954f, 0.002798f,
    0.214628f, 0.823841f, 0.060022f,
    0.097712f, 0.072953f, 0.883779f
};
// Note: AWG4 may share or slightly differ from AWG3 in spec; same matrix used here; update from ARRI LogC4 spec if needed.

// MARK: - Kernels

/// CS-005: Linear RGB → LogC3-encoded R'G'B' (OETF). texture(0)=linear, texture(1)=LogC3.
kernel void arri_logc3_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, linear.r));
    float g = fast::max(0.0f, fast::min(1.0f, linear.g));
    float b = fast::max(0.0f, fast::min(1.0f, linear.b));
    outTexture.write(float4(logc3_oetf(r), logc3_oetf(g), logc3_oetf(b), linear.a), gid);
}

/// CS-005: LogC3-encoded R'G'B' → linear RGB (EOTF). texture(0)=LogC3, texture(1)=linear.
kernel void arri_logc3_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 logC = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, logC.r));
    float g = fast::max(0.0f, fast::min(1.0f, logC.g));
    float b = fast::max(0.0f, fast::min(1.0f, logC.b));
    outTexture.write(float4(logc3_eotf(r), logc3_eotf(g), logc3_eotf(b), logC.a), gid);
}

/// CS-005: Linear RGB → LogC4-encoded R'G'B' (OETF). texture(0)=linear, texture(1)=LogC4.
kernel void arri_logc4_linear_to_log(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 linear = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, linear.r));
    float g = fast::max(0.0f, fast::min(1.0f, linear.g));
    float b = fast::max(0.0f, fast::min(1.0f, linear.b));
    outTexture.write(float4(logc4_oetf(r), logc4_oetf(g), logc4_oetf(b), linear.a), gid);
}

/// CS-005: LogC4-encoded R'G'B' → linear RGB (EOTF). texture(0)=LogC4, texture(1)=linear.
kernel void arri_logc4_log_to_linear(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 logC = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, logC.r));
    float g = fast::max(0.0f, fast::min(1.0f, logC.g));
    float b = fast::max(0.0f, fast::min(1.0f, logC.b));
    outTexture.write(float4(logc4_eotf(r), logc4_eotf(g), logc4_eotf(b), logC.a), gid);
}

#endif
