#include <metal_stdlib>
using namespace metal;

// MT-006: Structs shared with ShaderTypes.metal / Sources/Metal/ShaderTypes.swift (single source when concatenated).
struct V210Params { uint width; uint height; uint rowBytes; };
struct R12LParams { uint width; uint height; uint rowBytes; };
struct FrameParams { uint width; uint height; uint pixelFormat; uint rowBytes; };

// Placeholder so Shaders/Common exists. Phase 2 will add scope and colorspace kernels.
kernel void placeholder_kernel() {}

// MT-004: v210 to RGB placeholder (used when pixel format is not v210).
kernel void convert_v210_to_rgb_placeholder(
    device const uchar* buffer [[buffer(0)]],
    texture2d<float, access::write> outTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    outTexture.write(float4(0.5, 0.5, 0.5, 1.0), gid);
}

// MT-007: v210 (10-bit YCbCr packed) to linear RGB. Input: buffer (v210 layout), output: RGBA.
// v210 layout: 4 pixels in 3 32-bit words (SMPTE-style). Word: [31:22]=Cb [21:12]=Y [11:2]=Cr.
// BT.709 YCbCr -> RGB, 10-bit full range normalized to [0,1], output linear RGB for scopes.
// MT-006: params buffer is V210Params (layout matches ShaderTypes.swift).
kernel void convert_v210_to_rgb(
    device const uchar* buffer [[buffer(0)]],
    device const V210Params* params [[buffer(1)]],
    texture2d<float, access::write> outTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTexture.get_width();
    uint h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;

    uint width = params->width;
    uint height = params->height;
    uint rowBytes = params->rowBytes;
    if (width == 0 || rowBytes == 0) return;

    // v210: 4 pixels per 3 words (12 bytes). Pixel (gid.x) -> word index = (gid.x/4)*3 + (gid.x%4)
    uint group = gid.x / 4u;
    uint sub = gid.x % 4u;
    uint wordIndex = group * 3u + sub;
    size_t byteOffset = size_t(gid.y) * size_t(rowBytes) + size_t(wordIndex) * 4u;

    device const uint* words = (device const uint*)(buffer + byteOffset);
    uint word = words[0];

    // 10-bit extraction: match FFmpeg v210 — Cb [9:0], Y [19:10], Cr [29:20] (fixes green screen from Cb/Cr swap)
    uint cb10 = word & 0x3FFu;
    uint y10 = (word >> 10) & 0x3FFu;
    uint cr10 = (word >> 20) & 0x3FFu;

    // Normalize to [0,1]
    float y = float(y10) / 1023.0;
    float cb = float(cb10) / 1023.0;
    float cr = float(cr10) / 1023.0;

    // BT.709 YCbCr -> R'G'B' (full range, output linear for scopes)
    float cr_ = cr - 0.5;
    float cb_ = cb - 0.5;
    float r = y + 1.5748 * cr_;
    float g = y - 0.1873 * cb_ - 0.4681 * cr_;
    float b = y + 1.8556 * cb_;

    float4 rgba = float4(fast::max(0.0f, fast::min(1.0f, r)),
                         fast::max(0.0f, fast::min(1.0f, g)),
                         fast::max(0.0f, fast::min(1.0f, b)),
                         1.0);
    outTexture.write(rgba, gid);
}

// DL-015: R12L (12-bit RGB 4:4:4 little-endian, full range 0–4095) to linear RGB. 36 bits per pixel; rowBytes from frame.
kernel void convert_r12l_to_rgb(
    device const uchar* buffer [[buffer(0)]],
    device const R12LParams* params [[buffer(1)]],
    texture2d<float, access::write> outTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTexture.get_width();
    uint h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;

    uint width = params->width;
    uint height = params->height;
    uint rowBytes = params->rowBytes;
    if (width == 0 || rowBytes == 0) return;

    // 36 bits per pixel (12+12+12). Byte offset for pixel (gid.x, gid.y).
    size_t byteOffset = size_t(gid.y) * size_t(rowBytes) + (size_t(gid.x) * 36u) / 8u;

    device const uchar* p = buffer + byteOffset;
    uint byte0 = uint(p[0]), byte1 = uint(p[1]), byte2 = uint(p[2]), byte3 = uint(p[3]), byte4 = uint(p[4]);
    uint word0 = byte0 | (byte1 << 8u) | (byte2 << 16u) | (byte3 << 24u);
    uint r12 = word0 & 0xFFFu;
    uint g12 = (word0 >> 12u) & 0xFFFu;
    uint b12 = (word0 >> 24u) | ((byte4 & 0xFu) << 8u);

    float r = float(r12) / 4095.0;
    float g = float(g12) / 4095.0;
    float b = float(b12) / 4095.0;

    float4 rgba = float4(fast::max(0.0f, fast::min(1.0f, r)),
                         fast::max(0.0f, fast::min(1.0f, g)),
                         fast::max(0.0f, fast::min(1.0f, b)),
                         1.0);
    outTexture.write(rgba, gid);
}

// SC-003: Phosphor resolve params (optional buffer(2)).
struct ScopeResolveParams { float gamma; float gain; };

// SC-001/SC-003: Accumulation buffer → texture. buffer(0)=uint counts, buffer(1)=float scale, buffer(2)=ScopeResolveParams (optional).
// Phosphor: normalized = count/scale, then v = pow(normalized, gamma) * gain (gamma/gain from params; default linear if no buffer(2) or gamma<=0).
kernel void scope_accumulation_to_texture(
    device const uint* counts [[buffer(0)]],
    device const float* scalePtr [[buffer(1)]],
    device const ScopeResolveParams* resolveParams [[buffer(2)]],
    texture2d<float, access::write> outTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTexture.get_width(), h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float scale = scalePtr[0] > 0.0f ? scalePtr[0] : 1.0f;
    uint idx = gid.y * w + gid.x;
    float normalized = fast::min(1.0f, (float)counts[idx] / scale);
    float v = normalized;
    if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
        float g = resolveParams->gamma;
        float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
        v = fast::min(1.0f, fast::pow(normalized, g) * gain);
    }
    outTexture.write(float4(v, v, v, 1.0), gid);
}

// SC-002: Point rasterizer (waveform style). For each input pixel, compute (accumX, accumY): column = x, row = luminance bin; atomic add at (accumX, accumY).
// buffer(0) = accumulation (device atomic_uint*), texture(0) = input RGB, buffer(1) = params [accumWidth, accumHeight, inputWidth, inputHeight].
constant float kLumR = 0.2126;
constant float kLumG = 0.7152;
constant float kLumB = 0.0722;
kernel void scope_point_rasterizer_waveform(
    device atomic_uint* accum [[buffer(0)]],
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device const uint* params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint accumW = params[0], accumH = params[1], inputW = params[2], inputH = params[3];
    if (inputW == 0 || accumW == 0 || accumH == 0 || inputH == 0) return;
    uint px = gid.x, py = gid.y;
    if (px >= inputTexture.get_width() || py >= inputTexture.get_height()) return;

    float4 p = inputTexture.read(gid);
    float lum = kLumR * p.r + kLumG * p.g + kLumB * p.b;
    lum = fast::max(0.0f, fast::min(1.0f, lum));

    uint accumX = (px * accumW) / inputW;
    uint accumY = (uint)(lum * (float)(accumH - 1));
    if (accumX >= accumW) accumX = accumW - 1;
    if (accumY >= accumH) accumY = accumH - 1;

    uint idx = accumY * accumW + accumX;
    atomic_fetch_add_explicit(accum + idx, 1, memory_order::memory_order_relaxed);
}

// SC-006: RGB Parade — R, G, B waveforms side-by-side. Accum layout: width = 3*stripWidth, height = accumH.
// For each input pixel: column in strip = (px * stripWidth) / inputW; row = value*(accumH-1). Three atomics per pixel.
kernel void scope_point_rasterizer_rgb_parade(
    device atomic_uint* accum [[buffer(0)]],
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device const uint* params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint accumW = params[0], accumH = params[1], inputW = params[2], inputH = params[3];
    if (inputW == 0 || accumW == 0 || accumH == 0 || inputH == 0) return;
    uint stripWidth = accumW / 3u;
    if (stripWidth == 0) return;
    uint px = gid.x, py = gid.y;
    if (px >= inputTexture.get_width() || py >= inputTexture.get_height()) return;

    float4 p = inputTexture.read(gid);
    float r = fast::max(0.0f, fast::min(1.0f, p.r));
    float g = fast::max(0.0f, fast::min(1.0f, p.g));
    float b = fast::max(0.0f, fast::min(1.0f, p.b));

    uint stripCol = (px * stripWidth) / inputW;
    if (stripCol >= stripWidth) stripCol = stripWidth - 1u;

    uint rY = (uint)(r * (float)(accumH - 1u));
    uint gY = (uint)(g * (float)(accumH - 1u));
    uint bY = (uint)(b * (float)(accumH - 1u));
    if (rY >= accumH) rY = accumH - 1u;
    if (gY >= accumH) gY = accumH - 1u;
    if (bY >= accumH) bY = accumH - 1u;

    uint idxR = rY * accumW + stripCol;
    uint idxG = gY * accumW + (stripWidth + stripCol);
    uint idxB = bY * accumW + (stripWidth * 2u + stripCol);
    atomic_fetch_add_explicit(accum + idxR, 1, memory_order::memory_order_relaxed);
    atomic_fetch_add_explicit(accum + idxG, 1, memory_order::memory_order_relaxed);
    atomic_fetch_add_explicit(accum + idxB, 1, memory_order::memory_order_relaxed);
}

// CS-004: 3x3 gamut conversion (Rec.709, Rec.2020, DCI-P3, XYZ). Linear RGB in/out.
struct GamutMatrix3x3 { float m[9]; };
struct GamutConversionParams { uint clampResult; uint _pad0; uint _pad1; uint _pad2; };
constant float kRec709_RGB_to_XYZ[9] = {
    0.4124564f, 0.2126729f, 0.0193339f,
    0.3575761f, 0.7151522f, 0.1191920f,
    0.1804375f, 0.0721750f, 0.9503041f
};
constant float kRec2020_RGB_to_XYZ[9] = {
    0.6369581f, 0.2627002f, 0.0000000f,
    0.1446169f, 0.6779981f, 0.0280727f,
    0.1688809f, 0.0570571f, 1.0609851f
};
constant float kDCI_P3_RGB_to_XYZ[9] = {
    0.4865709f, 0.2289746f, 0.0000000f,
    0.2656677f, 0.6917385f, 0.0451134f,
    0.1982173f, 0.0792869f, 1.0439443f
};
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
    float3x3 M = float3x3(
        float3(matrixPtr[0], matrixPtr[1], matrixPtr[2]),
        float3(matrixPtr[3], matrixPtr[4], matrixPtr[5]),
        float3(matrixPtr[6], matrixPtr[7], matrixPtr[8])
    );
    float3 outRgb = M * rgb;
    bool clampResult = (params != nullptr && params->clampResult != 0);
    if (clampResult)
        outRgb = fast::max(float3(0.0f), fast::min(float3(1.0f), outRgb));
    outTexture.write(float4(outRgb, inColor.a), gid);
}
// QC-002: Gamut violation count. buffer(0)=9 floats, buffer(1)=atomic_uint*.
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

// CS-016: MaxCLL and MaxFALL real-time calculator (CS-001). From linear RGB (L/10000), compute per-threadgroup max and sum of luminance; CPU does final reduction.
// texture(0) = linear RGB (L/10000); buffer(0) = device float2 per threadgroup: .x = max L, .y = sum L (so 2 floats per group).
// Threadgroup size 256; grid covers all pixels (one thread per pixel, out-of-bounds reads 0).
kernel void maxcll_maxfall_reduce(
    texture2d<float, access::read> inTexture [[texture(0)]],
    device float* outMaxSum [[buffer(0)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint groupId [[threadgroup_position_in_grid]])
{
    uint w = inTexture.get_width();
    uint h = inTexture.get_height();
    float lum = 0.0f;
    if (gid < w * h) {
        uint2 px = uint2(gid % w, gid / w);
        float4 c = inTexture.read(px);
        lum = kLumR * c.r + kLumG * c.g + kLumB * c.b;
        lum = fast::max(0.0f, fast::min(1.0f, lum));
    }
    threadgroup float lums[256];
    lums[tid] = lum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float groupMax = 0.0f;
        float groupSum = 0.0f;
        for (uint i = 0; i < 256; ++i) {
            groupMax = fast::max(groupMax, lums[i]);
            groupSum += lums[i];
        }
        outMaxSum[groupId * 2u + 0u] = groupMax;
        outMaxSum[groupId * 2u + 1u] = groupSum;
    }
}

// QC-003: Luminance compliance (CS-001). Legal range = [0,1] for linear L/10000 (PQ). Count pixels below/above.
// texture(0) = linear RGB (L/10000); buffer(0) = atomic_uint* countBelow, buffer(1) = atomic_uint* countAbove.
kernel void luminance_compliance_count(
    texture2d<float, access::read> inTexture [[texture(0)]],
    device atomic_uint* countBelow [[buffer(0)]],
    device atomic_uint* countAbove [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    float lum = kLumR * c.r + kLumG * c.g + kLumB * c.b;
    if (lum < 0.0f)
        atomic_fetch_add_explicit(countBelow, 1, memory_order::memory_order_relaxed);
    else if (lum > 1.0f)
        atomic_fetch_add_explicit(countAbove, 1, memory_order::memory_order_relaxed);
}

// SC-006: Resolve parade accumulation to RGB-tinted texture. Left third = red, middle = green, right = blue.
// buffer(0)=counts, buffer(1)=scale, buffer(2)=ScopeResolveParams (optional).
kernel void scope_accumulation_to_texture_parade(
    device const uint* counts [[buffer(0)]],
    device const float* scalePtr [[buffer(1)]],
    device const ScopeResolveParams* resolveParams [[buffer(2)]],
    texture2d<float, access::write> outTexture [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = outTexture.get_width(), h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;
    uint stripWidth = w / 3u;
    if (stripWidth == 0) return;
    float scale = scalePtr[0] > 0.0f ? scalePtr[0] : 1.0f;
    uint idx = gid.y * w + gid.x;
    float normalized = fast::min(1.0f, (float)counts[idx] / scale);
    float v = normalized;
    if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
        float g = resolveParams->gamma;
        float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
        v = fast::min(1.0f, fast::pow(normalized, g) * gain);
    }
    float4 outColor;
    if (gid.x < stripWidth)
        outColor = float4(v, 0.0f, 0.0f, 1.0f);
    else if (gid.x < stripWidth * 2u)
        outColor = float4(0.0f, v, 0.0f, 1.0f);
    else
        outColor = float4(0.0f, 0.0f, v, 1.0f);
    outTexture.write(outColor, gid);
}

// CS-001: SMPTE ST 2084 (PQ) EOTF and OETF. Reference: ITU-R BT.2100, ST 2084:2014.
// Constants: m1 = 2610/16384, m2 = 2523*128/4096, c1 = 3424/4096, c2 = 2413*32/4096, c3 = 2392*32/4096.
constant float kPQ_m1 = 2610.0 / 16384.0;   // 0.1593017578125
constant float kPQ_m2 = (2523.0 * 128.0) / 4096.0;  // 78.84375
constant float kPQ_c1 = 3424.0 / 4096.0;   // 0.8359375
constant float kPQ_c2 = (2413.0 * 32.0) / 4096.0;   // 18.8515625
constant float kPQ_c3 = (2392.0 * 32.0) / 4096.0;   // 18.6875
constant float kPQ_Lmax = 10000.0;  // Peak luminance (nits) per ST 2084.

// CS-001: PQ EOTF — encoded N (0–1) → linear light. Output L/10000 in [0,1] for 10000 nits.
// L = 10000 * (max(N^(1/m2) - c1, 0) / (c2 - c3*N^(1/m2)))^(1/m1)
kernel void pq_eotf(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    float4 n = inTexture.read(gid);
    float4 l;
    for (int c = 0; c < 4; ++c) {
        float N = n[c];
        if (c == 3) { l[c] = N; continue; }  // alpha pass-through
        if (N <= 0.0) { l[c] = 0.0; continue; }
        float v = fast::pow(N, 1.0f / kPQ_m2);
        float denom = kPQ_c2 - kPQ_c3 * v;
        if (denom <= 0.0) { l[c] = 1.0; continue; }
        float num = fast::max(v - kPQ_c1, 0.0f);
        float L = kPQ_Lmax * fast::pow(num / denom, 1.0f / kPQ_m1);
        l[c] = fast::min(1.0f, L / kPQ_Lmax);
    }
    outTexture.write(l, gid);
}

// CS-001: PQ OETF (inverse EOTF) — linear light L (0–1 as L/10000) → encoded N (0–1).
// x = (L/10000)^m1; N = ((c1 + x*c2) / (1 + x*c3))^m2
kernel void pq_oetf(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    float4 lin = inTexture.read(gid);
    float4 n;
    for (int c = 0; c < 4; ++c) {
        float Lnorm = lin[c];
        if (c == 3) { n[c] = Lnorm; continue; }
        if (Lnorm <= 0.0) { n[c] = 0.0; continue; }
        float L = Lnorm * kPQ_Lmax;
        float x = fast::pow(L / kPQ_Lmax, kPQ_m1);
        float num = kPQ_c1 + x * kPQ_c2;
        float denom = 1.0f + x * kPQ_c3;
        if (denom <= 0.0) { n[c] = 1.0; continue; }
        float N = fast::pow(num / denom, kPQ_m2);
        n[c] = fast::max(0.0f, fast::min(1.0f, N));
    }
    outTexture.write(n, gid);
}

// CS-003: Rec.709 gamma (BT.1886) — linear ↔ gamma 2.4. Texture-to-texture kernels for pipeline integration.
constant float kRec709Gamma = 2.4;
constant float kRec709GammaInv = 1.0 / 2.4;  // 1/γ for linear → encoded

// Linear RGB [0,1] → Rec.709 / BT.1886 encoded (gamma 2.4). V' = linear^(1/γ). Alpha pass-through.
kernel void rec709_linear_to_gamma(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    float r = fast::pow(fast::max(0.0f, c.r), kRec709GammaInv);
    float g = fast::pow(fast::max(0.0f, c.g), kRec709GammaInv);
    float b = fast::pow(fast::max(0.0f, c.b), kRec709GammaInv);
    outTexture.write(float4(r, g, b, c.a), gid);
}

// Rec.709 / BT.1886 encoded (gamma 2.4) → linear RGB [0,1]. L = V'^γ. Alpha pass-through.
kernel void rec709_gamma_to_linear(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    float r = fast::pow(fast::max(0.0f, c.r), kRec709Gamma);
    float g = fast::pow(fast::max(0.0f, c.g), kRec709Gamma);
    float b = fast::pow(fast::max(0.0f, c.b), kRec709Gamma);
    outTexture.write(float4(r, g, b, c.a), gid);
}

// SC-014: False Color (Brightness mode). Map luminance to color ramp: dark=blue, mid=green, bright=red.
// Input: linear RGB from MT-007 (v210/convert). Output: same size; luminance → ramp for overlay on video/scope.
kernel void false_color_luminance(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    float lum = kLumR * c.r + kLumG * c.g + kLumB * c.b;
    lum = fast::max(0.0f, fast::min(1.0f, lum));
    float r, g, b;
    if (lum <= 0.5f) {
        float t = lum * 2.0f;
        r = 0.0f;
        g = t;
        b = 1.0f - t;
    } else {
        float t = (lum - 0.5f) * 2.0f;
        r = t;
        g = 1.0f - t;
        b = 0.0f;
    }
    outTexture.write(float4(r, g, b, 1.0f), gid);
}

// SC-015: False Color (Gamut Warning mode). Out-of-gamut pixels → magenta; in-gamut → original.
// buffer(0) = 9 floats (source→target, column-major). texture(0)=input, texture(1)=output.
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
        outTexture.write(float4(1.0f, 0.0f, 1.0f, 1.0f), gid);
    else
        outTexture.write(inColor, gid);
}
