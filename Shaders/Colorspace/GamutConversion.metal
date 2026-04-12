// CS-004: 3x3 matrix gamut conversion — Rec.709, Rec.2020, DCI-P3, XYZ.
// Linear RGB in/out; matrices are D65. Use via combined matrix (e.g. RGB_A → XYZ → RGB_B) in pipeline.

#ifndef GAMUT_CONVERSION_METAL
#define GAMUT_CONVERSION_METAL

#include <metal_stdlib>
using namespace metal;

// MARK: - Structs

/// 3x3 gamut conversion matrix (column-major: out = M * rgb).
/// Host fills m[0..8]: col0 = (m[0], m[1], m[2]), col1 = (m[3], m[4], m[5]), col2 = (m[6], m[7], m[8]).
struct GamutMatrix3x3 {
    float m[9];
};

/// Params for gamut_convert kernel: optional clamp (1 = clamp to [0,1], 0 = pass-through for XYZ/analysis).
struct GamutConversionParams {
    uint clampResult;  // 1 = clamp RGB to [0,1], 0 = no clamp
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

// MARK: - Predefined RGB → XYZ matrices (D65, column-major for float3 xyz = M * rgb)

// Rec.709 (BT.709) — rows: (Xr,Xg,Xb), (Yr,Yg,Yb), (Zr,Zg,Zb)
constant float kRec709_RGB_to_XYZ[9] = {
    0.4124564f, 0.2126729f, 0.0193339f,
    0.3575761f, 0.7151522f, 0.1191920f,
    0.1804375f, 0.0721750f, 0.9503041f
};

// Rec.2020 (BT.2020) — D65
constant float kRec2020_RGB_to_XYZ[9] = {
    0.6369581f, 0.2627002f, 0.0000000f,
    0.1446169f, 0.6779981f, 0.0280727f,
    0.1688809f, 0.0570571f, 1.0609851f
};

// DCI-P3 (Display P3, D65)
constant float kDCI_P3_RGB_to_XYZ[9] = {
    0.4865709f, 0.2289746f, 0.0000000f,
    0.2656677f, 0.6917385f, 0.0451134f,
    0.1982173f, 0.0792869f, 1.0439443f
};

// XYZ identity (pass-through)
constant float kXYZ_Identity[9] = {
    1.0f, 0.0f, 0.0f,
    0.0f, 1.0f, 0.0f,
    0.0f, 0.0f, 1.0f
};

// CS-006: SGamut3.Cine (Sony, D65) — RGB → XYZ, column-major. Use with gamut_convert for SGamut3.Cine ↔ 709/2020/P3/XYZ.
constant float kSGamut3Cine_RGB_to_XYZ[9] = {
    0.5990839f, 0.2150758f, -0.03206585f,
    0.2489255f, 0.8850685f, -0.02765839f,
    0.1024465f, -0.1001443f, 1.148782f
};

// CS-007: Cinema Gamut (Canon, D65) — RGB → XYZ, column-major. Use with gamut_convert for Cinema Gamut ↔ 709/2020/P3/XYZ.
constant float kCinemaGamut_RGB_to_XYZ[9] = {
    0.71604965f, 0.26126136f, -0.00967635f,
    0.12968348f, 0.86964215f, -0.23648164f,
    0.1047228f, -0.1309035f, 1.33521573f
};

// CS-008: V-Gamut (Panasonic, D65) — RGB → XYZ, row-major (rows = X,Y,Z from R,G,B). Use with gamut_convert for V-Gamut ↔ 709/2020/P3/XYZ.
constant float kVGamut_RGB_to_XYZ[9] = {
    0.679644f, 0.152211f, 0.1186f,
    0.260686f, 0.774894f, -0.03558f,
    -0.00931f, -0.004612f, 1.10298f
};

// MARK: - Kernel

/// CS-004: Apply 3x3 gamut matrix to linear RGB texture.
/// buffer(0) = GamutMatrix3x3 (9 floats column-major), buffer(1) = optional GamutConversionParams (clampResult).
/// texture(0) = input linear RGB, texture(1) = output linear RGB.
kernel void gamut_convert(
    device const float* matrixPtr [[buffer(0)]],
    device const GamutConversionParams* params [[buffer(1)]],
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 inColor = inTexture.read(gid);
    float3 rgb = inColor.rgb;

    // Build 3x3 from column-major buffer
    float3x3 M = float3x3(
        float3(matrixPtr[0], matrixPtr[1], matrixPtr[2]),
        float3(matrixPtr[3], matrixPtr[4], matrixPtr[5]),
        float3(matrixPtr[6], matrixPtr[7], matrixPtr[8])
    );
    float3 outRgb = M * rgb;

    bool clampResult = (params != nullptr && params->clampResult != 0);
    if (clampResult) {
        outRgb = fast::max(float3(0.0f), fast::min(float3(1.0f), outRgb));
    }

    outTexture.write(float4(outRgb, inColor.a), gid);
}

// QC-002: Gamut violation detector. Count pixels whose RGB (in source gamut) fall outside [0,1] in target gamut.
// buffer(0) = 9 floats (source RGB → target RGB, column-major), buffer(1) = device atomic_uint* (single counter).
kernel void gamut_violation_count(
    device const float* matrixPtr [[buffer(0)]],
    device atomic_uint* outCount [[buffer(1)]],
    texture2d<float, access::read> inTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    float4 inColor = inTexture.read(gid);
    float3 rgb = inColor.rgb;
    float3x3 M = float3x3(
        float3(matrixPtr[0], matrixPtr[1], matrixPtr[2]),
        float3(matrixPtr[3], matrixPtr[4], matrixPtr[5]),
        float3(matrixPtr[6], matrixPtr[7], matrixPtr[8])
    );
    float3 targetRgb = M * rgb;
    bool outOfGamut = (targetRgb.r < 0.0f || targetRgb.r > 1.0f ||
                       targetRgb.g < 0.0f || targetRgb.g > 1.0f ||
                       targetRgb.b < 0.0f || targetRgb.b > 1.0f);
    if (outOfGamut)
        atomic_fetch_add_explicit(outCount, 1, memory_order::memory_order_relaxed);
}

// SC-015: False Color (Gamut Warning mode). Overlay: out-of-gamut pixels → magenta; in-gamut → original.
// buffer(0) = 9 floats (source RGB → target RGB, column-major). texture(0) = input, texture(1) = output.
kernel void false_color_gamut(
    device const float* matrixPtr [[buffer(0)]],
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 inColor = inTexture.read(gid);
    float3 rgb = inColor.rgb;
    float3x3 M = float3x3(
        float3(matrixPtr[0], matrixPtr[1], matrixPtr[2]),
        float3(matrixPtr[3], matrixPtr[4], matrixPtr[5]),
        float3(matrixPtr[6], matrixPtr[7], matrixPtr[8])
    );
    float3 targetRgb = M * rgb;
    bool outOfGamut = (targetRgb.r < 0.0f || targetRgb.r > 1.0f ||
                       targetRgb.g < 0.0f || targetRgb.g > 1.0f ||
                       targetRgb.b < 0.0f || targetRgb.b > 1.0f);
    if (outOfGamut)
        outTexture.write(float4(1.0f, 0.0f, 1.0f, 1.0f), gid);  // magenta = gamut warning
    else
        outTexture.write(inColor, gid);
}

#endif
