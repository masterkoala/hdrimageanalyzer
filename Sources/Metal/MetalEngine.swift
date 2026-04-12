import Foundation
import Metal
import CoreGraphics
import Logging
import Common

/// Metal engine: device, command queue, shader library (Phase 2 pipeline).
/// MT-001: Shader library. MT-002: Frame manager. MT-003: Texture pool.
public final class MetalEngine {
    public static let shared = MetalEngine()
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    /// MT-012: Dedicated queue for scope compute; runs in parallel with main queue / next frame capture. Sync when presenting scope.
    public let scopeComputeQueue: MTLCommandQueue?
    /// Shader library (Common + placeholder kernels). Loaded at init from file or embedded source.
    public private(set) var library: MTLLibrary?
    /// MT-002: Triple-buffered frame manager for capture handoff.
    public let frameManager: TripleBufferedFrameManager
    /// MT-003: Texture pool for reuse by width/height/format.
    public let texturePool: TexturePool
    private let logCategory = "Metal"
    /// MT-011: Memory pressure source; reduces TexturePool/triple-buffer when elevated, restores when normal.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let memoryPressureQueue = DispatchQueue(label: "com.hdranalyzer.metal.memorypressure")

    private static let embeddedLibrarySource = """
    #include <metal_stdlib>
    using namespace metal;
    struct V210Params { uint width; uint height; uint rowBytes; };
    struct FrameParams { uint width; uint height; uint pixelFormat; uint rowBytes; };
    kernel void placeholder_kernel() {}
    kernel void convert_v210_to_rgb_placeholder(
        device const uchar* buffer [[buffer(0)]],
        texture2d<float, access::write> outTexture [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        outTexture.write(float4(0.5, 0.5, 0.5, 1.0), gid);
    }
    kernel void convert_v210_to_rgb(
        device const uchar* buffer [[buffer(0)]],
        device const V210Params* params [[buffer(1)]],
        constant uint* signalRangePtr [[buffer(2)]],
        texture2d<float, access::write> outTexture [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outTexture.get_width(), h = outTexture.get_height();
        if (gid.x >= w || gid.y >= h) return;
        uint width = params->width, rowBytes = params->rowBytes;
        if (width == 0 || rowBytes == 0) return;
        // v210: 6 pixels packed into 4 x uint32 words (16 bytes per group).
        // Each word: bits[9:0]=A, bits[19:10]=B, bits[29:20]=C, bits[31:30]=unused.
        // Word 0: Cb0, Y0, Cr0  |  Word 1: Y1, Cb2, Y2
        // Word 2: Cr2, Y3, Cb4  |  Word 3: Y4, Cr4, Y5
        uint group6 = gid.x / 6u;
        uint pixInGroup = gid.x % 6u;
        size_t groupByteOffset = (size_t)gid.y * (size_t)rowBytes + (size_t)group6 * 16u;
        device const uint* words = (device const uint*)(buffer + groupByteOffset);
        uint w0 = words[0], w1 = words[1], w2 = words[2], w3 = words[3];
        uint y10, cb10, cr10;
        if (pixInGroup == 0u) {
            y10  = (w0 >> 10) & 0x3FFu;   // Y0
            cb10 = w0 & 0x3FFu;           // Cb0
            cr10 = (w0 >> 20) & 0x3FFu;   // Cr0
        } else if (pixInGroup == 1u) {
            y10  = w1 & 0x3FFu;           // Y1
            cb10 = w0 & 0x3FFu;           // Cb0 (shared with pixel 0)
            cr10 = (w0 >> 20) & 0x3FFu;   // Cr0 (shared with pixel 0)
        } else if (pixInGroup == 2u) {
            y10  = (w1 >> 20) & 0x3FFu;   // Y2  from W1[29:20]
            cb10 = (w1 >> 10) & 0x3FFu;   // Cb2 from W1[19:10]
            cr10 = w2 & 0x3FFu;           // Cr2 from W2[9:0]
        } else if (pixInGroup == 3u) {
            y10  = (w2 >> 10) & 0x3FFu;   // Y3  from W2[19:10]
            cb10 = (w1 >> 10) & 0x3FFu;   // Cb2 from W1[19:10] (shared with pixel 2)
            cr10 = w2 & 0x3FFu;           // Cr2 from W2[9:0]   (shared with pixel 2)
        } else if (pixInGroup == 4u) {
            y10  = w3 & 0x3FFu;           // Y4  from W3[9:0]
            cb10 = (w2 >> 20) & 0x3FFu;   // Cb4 from W2[29:20]
            cr10 = (w3 >> 10) & 0x3FFu;   // Cr4 from W3[19:10]
        } else {
            y10  = (w3 >> 20) & 0x3FFu;   // Y5  from W3[29:20]
            cb10 = (w2 >> 20) & 0x3FFu;   // Cb4 from W2[29:20] (shared with pixel 4)
            cr10 = (w3 >> 10) & 0x3FFu;   // Cr4 from W3[19:10] (shared with pixel 4)
        }
        // BT.709 YCbCr -> RGB. signalRange: 0=full, 1=legal (SMPTE 274M).
        uint signalRange = (signalRangePtr != nullptr) ? signalRangePtr[0] : 0u;
        float y, cb, cr;
        if (signalRange != 0u) {
            // Legal range: Y 64-940, CbCr 64-960 (10-bit)
            y  = ((float)y10  - 64.0f) / 876.0f;
            cb = ((float)cb10 - 512.0f) / 896.0f;
            cr = ((float)cr10 - 512.0f) / 896.0f;
        } else {
            // Full range
            y  = (float)y10 / 1023.0f;
            cb = (float)cb10 / 1023.0f - 0.5f;
            cr = (float)cr10 / 1023.0f - 0.5f;
        }
        float r = y + 1.5748f * cr;
        float g = y - 0.1873f * cb - 0.4681f * cr;
        float b = y + 1.8556f * cb;
        outTexture.write(float4(clamp(r, 0.0f, 1.0f), clamp(g, 0.0f, 1.0f), clamp(b, 0.0f, 1.0f), 1.0f), gid);
    }
    kernel void convert_bgra_to_rgb(
        device const uchar* buffer [[buffer(0)]],
        device const V210Params* params [[buffer(1)]],
        constant uint* signalRangePtr [[buffer(2)]],
        texture2d<float, access::write> outTexture [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outTexture.get_width(), h = outTexture.get_height();
        if (gid.x >= w || gid.y >= h) return;
        uint rowBytes = params->rowBytes;
        if (rowBytes == 0) return;
        size_t byteOffset = (size_t)gid.y * (size_t)rowBytes + (size_t)gid.x * 4;
        device const uchar* p = buffer + byteOffset;
        float b = float(p[0]) / 255.0, g = float(p[1]) / 255.0, r = float(p[2]) / 255.0;
        // signalRange: 0=full (0-255 → 0.0-1.0), 1=legal (16-235 → 0.0-1.0)
        uint signalRange = (signalRangePtr != nullptr) ? signalRangePtr[0] : 0u;
        if (signalRange != 0u) {
            r = clamp((r * 255.0f - 16.0f) / 219.0f, 0.0f, 1.0f);
            g = clamp((g * 255.0f - 16.0f) / 219.0f, 0.0f, 1.0f);
            b = clamp((b * 255.0f - 16.0f) / 219.0f, 0.0f, 1.0f);
        }
        outTexture.write(float4(r, g, b, 1.0), gid);
    }
    // Display: fullscreen quad to blit texture to drawable.
    struct CopyVertexOut { float4 position [[position]]; float2 uv; };
    vertex CopyVertexOut copy_vertex(uint id [[vertex_id]]) {
        float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uvs[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
        CopyVertexOut o;
        o.position = float4(positions[id], 0, 1);
        o.uv = uvs[id];
        return o;
    }
    fragment float4 copy_fragment(CopyVertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::linear);
        return tex.sample(s, in.uv);
    }
    /// Aspect-correct blit: scale fits texture into view (letterbox/pillarbox). buffer(0)=float2(scaleX,scaleY).
    vertex CopyVertexOut copy_vertex_aspect(uint id [[vertex_id]], constant float2* scale [[buffer(0)]]) {
        float2 s = *scale;
        float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uvs[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
        CopyVertexOut o;
        o.position = float4(positions[id].x * s.x, positions[id].y * s.y, 0, 1);
        o.uv = uvs[id];
        return o;
    }
    // SC-003: Phosphor resolve params (optional buffer(2)). SC-019: useLogScale for waveform luminance axis.
    struct ScopeResolveParams { float gamma; float gain; uint useLogScale; };
    // SC-001/SC-003: Accumulation → texture with colorized phosphor ramp. buffer(0)=counts, buffer(1)=scale, buffer(2)=ScopeResolveParams (optional).
    // SC-019: When useLogScale=1, output row gid.y (0=bottom) maps to linear source row via log10(1+nits)/log10(10001).
    // Color ramp: transparent→deep blue→cyan→green→yellow→white (professional waveform monitor style).
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
        // Flip Y: accumulation y=0 is 0 IRE (bottom), texture y=0 is top → invert
        uint readRow = (h - 1u) - gid.y;
        if (resolveParams != nullptr && resolveParams->useLogScale != 0u && h > 1u) {
            float displayY = 1.0f - (float)gid.y / (float)(h - 1u);  // 1.0 at top (100 IRE), 0.0 at bottom
            float nits = pow(10.0f, displayY * log10(10001.0f)) - 1.0f;
            float linearNorm = min(1.0f, nits / 10000.0f);
            readRow = (uint)(linearNorm * (float)(h - 1u) + 0.5f);
            if (readRow >= h) readRow = h - 1u;
        }
        uint idx = readRow * w + gid.x;
        float normalized = min(1.0f, (float)counts[idx] / scale);
        float v = normalized;
        if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
            float g = resolveParams->gamma;
            float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
            v = min(1.0f, pow(normalized, g) * gain);
        }
        // Colorized phosphor ramp: professional waveform monitor look
        float3 color;
        if (v < 0.005f) {
            color = float3(0.0f);
        } else if (v < 0.15f) {
            float t = v / 0.15f;
            color = mix(float3(0.0f, 0.0f, 0.08f), float3(0.0f, 0.15f, 0.45f), t);
        } else if (v < 0.35f) {
            float t = (v - 0.15f) / 0.20f;
            color = mix(float3(0.0f, 0.15f, 0.45f), float3(0.0f, 0.65f, 0.55f), t);
        } else if (v < 0.55f) {
            float t = (v - 0.35f) / 0.20f;
            color = mix(float3(0.0f, 0.65f, 0.55f), float3(0.4f, 0.85f, 0.2f), t);
        } else if (v < 0.75f) {
            float t = (v - 0.55f) / 0.20f;
            color = mix(float3(0.4f, 0.85f, 0.2f), float3(0.95f, 0.9f, 0.15f), t);
        } else {
            float t = (v - 0.75f) / 0.25f;
            color = mix(float3(0.95f, 0.9f, 0.15f), float3(1.0f, 1.0f, 1.0f), t);
        }
        outTexture.write(float4(color, 1.0f), gid);
    }
    // SC-002/SC-005: Point rasterizer (waveform). buffer(0)=atomic_uint* accum, texture(0)=input, buffer(1)=params [accumW,accumH,inputW,inputH,mode,maxNits,inputIsPQ].
    // SC-019: maxNits 100 (SDR) or 10000 (HDR); inputIsPQ 1 = decode PQ to nits then bin 0..10000.
    constant float kLumR = 0.2126;
    constant float kLumG = 0.7152;
    constant float kLumB = 0.0722;
    constant float kCbScale = 1.8556;
    constant float kCrScale = 1.5748;
    constant float kPQ_m1 = 2610.0 / 16384.0;
    constant float kPQ_m2 = (2523.0 * 128.0) / 4096.0;
    constant float kPQ_c1 = 3424.0 / 4096.0;
    constant float kPQ_c2 = (2413.0 * 32.0) / 4096.0;
    constant float kPQ_c3 = (2392.0 * 32.0) / 4096.0;
    constant float kPQ_Lmax = 10000.0;
    static inline float pq_eotf_to_nits(float N) {
        if (N <= 0.0f) return 0.0f;
        float v = pow(N, 1.0f / kPQ_m2);
        float denom = kPQ_c2 - kPQ_c3 * v;
        if (denom <= 0.0f) return kPQ_Lmax;
        float num = max(v - kPQ_c1, 0.0f);
        return kPQ_Lmax * pow(num / denom, 1.0f / kPQ_m1);
    }
    kernel void scope_point_rasterizer_waveform(
        device atomic_uint* accum [[buffer(0)]],
        texture2d<float, access::read> inputTexture [[texture(0)]],
        device const uint* params [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint accumW = params[0], accumH = params[1], inputW = params[2], inputH = params[3];
        uint mode = params[4];
        float maxNits = (float)(params[5] > 0u ? params[5] : 100u);
        uint inputIsPQ = params[6];
        uint singleLineMode = (params[7] != 0u) ? 1u : 0u;
        uint singleLineRow = params[8];
        if (inputW == 0 || accumW == 0 || accumH == 0 || inputH == 0) return;
        uint px = gid.x;
        uint py = (singleLineMode != 0u) ? singleLineRow : gid.y;
        if (py >= inputH || px >= inputW) return;
        if (px >= inputTexture.get_width() || py >= inputTexture.get_height()) return;
        float4 p = inputTexture.read(uint2(px, py));
        float v = 0.0f;
        if (mode == 0) {
            v = kLumR * p.r + kLumG * p.g + kLumB * p.b;
        } else if (mode == 1) { v = p.r; }
        else if (mode == 2) { v = p.g; }
        else if (mode == 3) { v = p.b; }
        else if (mode >= 4 && mode <= 6) {
            float y = kLumR * p.r + kLumG * p.g + kLumB * p.b;
            float cb = 0.5f + (p.b - y) / kCbScale;
            float cr = 0.5f + (p.r - y) / kCrScale;
            if (mode == 4) v = y;
            else if (mode == 5) v = cb;
            else v = cr;
        }
        else if (mode >= 7 && mode <= 9) {
            // Color mode: plot at luminance Y position, accumulate color channel intensity.
            v = kLumR * p.r + kLumG * p.g + kLumB * p.b;
        }
        v = max(0.0f, min(1.0f, v));
        float normalised = v;
        if (inputIsPQ != 0u && maxNits >= 1000.0f) {
            float nits = pq_eotf_to_nits(v);
            normalised = min(1.0f, nits / 10000.0f);
        }
        uint accumX = (px * accumW) / inputW;
        uint accumY = (uint)(normalised * (float)(accumH - 1));
        if (accumX >= accumW) accumX = accumW - 1;
        if (accumY >= accumH) accumY = accumH - 1;
        uint idx = accumY * accumW + accumX;
        // Color mode: accumulate scaled channel intensity (not just count)
        uint weight = 1u;
        if (mode == 7) { weight = max(1u, (uint)(p.r * 16.0f + 0.5f)); }
        else if (mode == 8) { weight = max(1u, (uint)(p.g * 16.0f + 0.5f)); }
        else if (mode == 9) { weight = max(1u, (uint)(p.b * 16.0f + 0.5f)); }
        atomic_fetch_add_explicit(accum + idx, weight, memory_order::memory_order_relaxed);
    }
    // SC-005: Resolve 3 accumulation buffers to RGB texture (R from buf0, G from buf1, B from buf2). Same gamma/gain as single-channel.
    kernel void scope_accumulation_to_texture_rgb(
        device const uint* countsR [[buffer(0)]],
        device const uint* countsG [[buffer(1)]],
        device const uint* countsB [[buffer(2)]],
        device const float* scalePtr [[buffer(3)]],
        device const ScopeResolveParams* resolveParams [[buffer(4)]],
        texture2d<float, access::write> outTexture [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outTexture.get_width(), h = outTexture.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float scale = scalePtr[0] > 0.0f ? scalePtr[0] : 1.0f;
        // Flip Y + SC-019 log scale row remapping for RGB overlay
        uint readRow = (h - 1u) - gid.y;
        if (resolveParams != nullptr && resolveParams->useLogScale != 0u && h > 1u) {
            float displayY = 1.0f - (float)gid.y / (float)(h - 1u);
            float nits = pow(10.0f, displayY * log10(10001.0f)) - 1.0f;
            float linearNorm = min(1.0f, nits / 10000.0f);
            readRow = (uint)(linearNorm * (float)(h - 1u) + 0.5f);
            if (readRow >= h) readRow = h - 1u;
        }
        uint idx = readRow * w + gid.x;
        float nr = min(1.0f, (float)countsR[idx] / scale);
        float ng = min(1.0f, (float)countsG[idx] / scale);
        float nb = min(1.0f, (float)countsB[idx] / scale);
        if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
            float g = resolveParams->gamma;
            float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
            nr = min(1.0f, pow(nr, g) * gain);
            ng = min(1.0f, pow(ng, g) * gain);
            nb = min(1.0f, pow(nb, g) * gain);
        }
        outTexture.write(float4(nr, ng, nb, 1.0), gid);
    }
    // SC-007: Vectorscope resolve: accumulation -> colorized texture. Maps (x,y) position back to CbCr color.
    kernel void scope_accumulation_to_texture_vectorscope(
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
        float normalized = min(1.0f, (float)counts[idx] / scale);
        float v = normalized;
        if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
            float gm = resolveParams->gamma;
            float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
            v = min(1.0f, pow(normalized, gm) * gain);
        }
        if (v < 0.003f) {
            outTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
            return;
        }
        // Map pixel position back to Cb/Cr values to derive color at this position
        float u = ((float)gid.x / (float)(w - 1u)) - 0.5f;  // Cb: -0.5..+0.5
        float vv = 0.5f - ((float)gid.y / (float)(h - 1u));  // Cr: -0.5..+0.5 (y-flipped)
        // Approximate the color at this CbCr position (assuming mid luminance Y=0.5)
        float Y = 0.5f;
        float Cb = u * kCbScale;
        float Cr = vv * kCrScale;
        float rr = Y + 1.5748f * Cr;
        float gg = Y - 0.1873f * Cb - 0.4681f * Cr;
        float bb = Y + 1.8556f * Cb;
        // Saturate to valid range and boost saturation for visibility
        float satBoost = 1.4f;
        rr = clamp((rr - 0.5f) * satBoost + 0.5f, 0.0f, 1.0f);
        gg = clamp((gg - 0.5f) * satBoost + 0.5f, 0.0f, 1.0f);
        bb = clamp((bb - 0.5f) * satBoost + 0.5f, 0.0f, 1.0f);
        // Blend with white based on intensity for phosphor glow at high counts
        float whiteBlend = v * v;
        float3 hueColor = float3(rr, gg, bb);
        float3 finalColor = mix(hueColor * v, float3(1.0f), whiteBlend * 0.4f) * v;
        outTexture.write(float4(finalColor, 1.0f), gid);
    }
    // SC-007: Vectorscope point rasterizer. Map (Cb,Cr) to 2D: center = neutral, radius = saturation.
    // RGB -> BT.709 YCbCr; kCbScale/kCrScale defined above with waveform.
    kernel void scope_point_rasterizer_vectorscope(
        device atomic_uint* accum [[buffer(0)]],
        texture2d<float, access::read> inputTexture [[texture(0)]],
        device const uint* params [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint accumW = params[0], accumH = params[1];
        if (accumW == 0 || accumH == 0) return;
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 p = inputTexture.read(gid);
        float y = kLumR * p.r + kLumG * p.g + kLumB * p.b;
        float cb = 0.5f + (p.b - y) / kCbScale;
        float cr = 0.5f + (p.r - y) / kCrScale;
        cb = max(0.0f, min(1.0f, cb));
        cr = max(0.0f, min(1.0f, cr));
        float u = cb - 0.5f;
        float v = cr - 0.5f;
        float centerX = (float)(accumW - 1) * 0.5f;
        float centerY = (float)(accumH - 1) * 0.5f;
        float scale = min((float)(accumW - 1), (float)(accumH - 1)) * 0.5f;
        int accumX = (int)(centerX + u * scale * 2.0f);
        int accumY = (int)(centerY - v * scale * 2.0f);
        if (accumX < 0) accumX = 0;
        if (accumY < 0) accumY = 0;
        uint ux = (uint)accumX;
        uint uy = (uint)accumY;
        if (ux >= accumW) ux = accumW - 1;
        if (uy >= accumH) uy = accumH - 1;
        uint idx = uy * accumW + ux;
        atomic_fetch_add_explicit(accum + idx, 1, memory_order::memory_order_relaxed);
    }
    // SC-006: RGB Parade — R/G/B side-by-side. Accum width = 3*stripWidth.
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
        float r = max(0.0f, min(1.0f, p.r));
        float g = max(0.0f, min(1.0f, p.g));
        float b = max(0.0f, min(1.0f, p.b));
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
    // SC-006: Resolve parade to R/G/B tinted texture with phosphor glow.
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
        // Flip Y: accumulation y=0 is 0 IRE (bottom), texture y=0 is top
        uint readRow = (h - 1u) - gid.y;
        uint idx = readRow * w + gid.x;
        float normalized = min(1.0f, (float)counts[idx] / scale);
        float v = normalized;
        if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
            float g = resolveParams->gamma;
            float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
            v = min(1.0f, pow(normalized, g) * gain);
        }
        // Tinted channels with white glow at high intensity for professional phosphor look
        float whiteBlend = v * v * 0.3f;
        float4 outColor;
        if (gid.x < stripWidth) {
            outColor = float4(v + whiteBlend, whiteBlend * 0.5f, whiteBlend * 0.3f, 1.0f);
        } else if (gid.x < stripWidth * 2u) {
            outColor = float4(whiteBlend * 0.3f, v + whiteBlend, whiteBlend * 0.3f, 1.0f);
        } else {
            outColor = float4(whiteBlend * 0.3f, whiteBlend * 0.5f, v + whiteBlend, 1.0f);
        }
        outColor = min(outColor, float4(1.0f));
        outTexture.write(outColor, gid);
    }
    // SC-010/SC-013: CIE xy measured pixel chromaticity distribution — RGB (gamma) -> linear -> XYZ -> xy, bin to 2D. Params same as other scopes.
    constant float kRec709GammaForCIE = 2.4;
    constant float kCIE_Xr = 0.4124564, kCIE_Xg = 0.3575761, kCIE_Xb = 0.1804375;
    constant float kCIE_Yr = 0.2126729, kCIE_Yg = 0.7151522, kCIE_Yb = 0.0721750;
    constant float kCIE_Zr = 0.0193339, kCIE_Zg = 0.1191920, kCIE_Zb = 0.9503041;
    constant float kCIE_xyMax = 0.85;
    kernel void scope_point_rasterizer_cie_xy(
        device atomic_uint* accum [[buffer(0)]],
        texture2d<float, access::read> inputTexture [[texture(0)]],
        device const uint* params [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint accumW = params[0], accumH = params[1];
        if (accumW == 0 || accumH == 0) return;
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 p = inputTexture.read(gid);
        float r = pow(max(0.0f, p.r), kRec709GammaForCIE);
        float g = pow(max(0.0f, p.g), kRec709GammaForCIE);
        float b = pow(max(0.0f, p.b), kRec709GammaForCIE);
        float X = kCIE_Xr*r + kCIE_Xg*g + kCIE_Xb*b;
        float Y = kCIE_Yr*r + kCIE_Yg*g + kCIE_Yb*b;
        float Z = kCIE_Zr*r + kCIE_Zg*g + kCIE_Zb*b;
        float sum = X + Y + Z;
        if (sum < 1e-6) return;
        float x = X / sum;
        float y = Y / sum;
        if (x < 0.0f || x > kCIE_xyMax || y < 0.0f || y > kCIE_xyMax) return;
        float xNorm = x / kCIE_xyMax;
        float yNorm = y / kCIE_xyMax;
        int accumX = (int)(xNorm * (float)(accumW - 1));
        int accumY = (int)((1.0f - yNorm) * (float)(accumH - 1));
        if (accumX < 0) accumX = 0;
        if (accumY < 0) accumY = 0;
        uint ux = (uint)accumX; if (ux >= accumW) ux = accumW - 1;
        uint uy = (uint)accumY; if (uy >= accumH) uy = accumH - 1;
        uint idx = uy * accumW + ux;
        atomic_fetch_add_explicit(accum + idx, 1, memory_order::memory_order_relaxed);
    }
    // SC-010: CIE xy resolve — neutral white phosphor ramp (not waveform blue→green→yellow color ramp).
    // Shows chromaticity distribution as white intensity heat map so it doesn't look like false color.
    kernel void scope_accumulation_to_texture_cie(
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
        float normalized = min(1.0f, (float)counts[idx] / scale);
        float v = normalized;
        if (resolveParams != nullptr && resolveParams->gamma > 0.0f) {
            float gm = resolveParams->gamma;
            float gain = resolveParams->gain > 0.0f ? resolveParams->gain : 1.0f;
            v = min(1.0f, pow(normalized, gm) * gain);
        }
        // White phosphor ramp: transparent → dim cool white → bright white
        float3 color;
        if (v < 0.005f) {
            color = float3(0.0f);
        } else if (v < 0.2f) {
            float t = v / 0.2f;
            color = mix(float3(0.02f, 0.02f, 0.04f), float3(0.15f, 0.18f, 0.25f), t);
        } else if (v < 0.5f) {
            float t = (v - 0.2f) / 0.3f;
            color = mix(float3(0.15f, 0.18f, 0.25f), float3(0.5f, 0.55f, 0.65f), t);
        } else {
            float t = (v - 0.5f) / 0.5f;
            color = mix(float3(0.5f, 0.55f, 0.65f), float3(1.0f, 1.0f, 1.0f), t);
        }
        outTexture.write(float4(color, v > 0.005f ? 1.0f : 0.0f), gid);
    }
    // PERF-002: Temporal accumulation decay — multiply all counts by decay factor (e.g. 0.90).
    // Replaces clear-to-zero; retains density from previous frames for smooth scope output.
    kernel void scope_accumulation_decay(
        device uint* accum [[buffer(0)]],
        constant float* decayPtr [[buffer(1)]],
        constant uint* countPtr [[buffer(2)]],
        uint tid [[thread_position_in_grid]])
    {
        if (tid >= countPtr[0]) return;
        float decayed = float(accum[tid]) * decayPtr[0];
        accum[tid] = uint(decayed);
    }
    // PERF-002: 5x5 Gaussian blur on resolved scope textures for professional phosphor glow.
    kernel void scope_texture_blur_5x5(
        texture2d<float, access::read> inTex [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outTex.get_width(), h = outTex.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float4 sum = float4(0.0);
        const int kW[5] = {1, 4, 6, 4, 1};
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int sx = clamp(int(gid.x) + dx, 0, int(w) - 1);
                int sy = clamp(int(gid.y) + dy, 0, int(h) - 1);
                float weight = float(kW[dy + 2] * kW[dx + 2]);
                sum += inTex.read(uint2(sx, sy)) * weight;
            }
        }
        outTex.write(sum / 256.0, gid);
    }
    // SC-026: 2x bilinear downsample for scope path at 4K — reduces pixel count 4x to meet 4ms budget.
    kernel void scope_downsample_2x(
        texture2d<float, access::read> inTex [[texture(0)]],
        texture2d<float, access::write> outTex [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint outW = outTex.get_width(), outH = outTex.get_height();
        if (gid.x >= outW || gid.y >= outH) return;
        uint inW = inTex.get_width(), inH = inTex.get_height();
        uint ix = gid.x * 2u, iy = gid.y * 2u;
        uint ix1 = min(ix + 1u, inW - 1u), iy1 = min(iy + 1u, inH - 1u);
        float4 a = inTex.read(uint2(ix, iy));
        float4 b = inTex.read(uint2(ix1, iy));
        float4 c = inTex.read(uint2(ix, iy1));
        float4 d = inTex.read(uint2(ix1, iy1));
        outTex.write((a + b + c + d) * 0.25f, gid);
    }
    // CS-003: Rec.709 gamma (BT.1886) — linear ↔ gamma 2.4. texture(0)=in, texture(1)=out.
    constant float kRec709Gamma = 2.4;
    constant float kRec709GammaInv = 1.0 / 2.4;
    kernel void rec709_linear_to_gamma(
        texture2d<float, access::read> inTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        float4 c = inTexture.read(gid);
        float r = pow(max(0.0f, c.r), kRec709GammaInv);
        float g = pow(max(0.0f, c.g), kRec709GammaInv);
        float b = pow(max(0.0f, c.b), kRec709GammaInv);
        outTexture.write(float4(r, g, b, c.a), gid);
    }
    kernel void rec709_gamma_to_linear(
        texture2d<float, access::read> inTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        float4 c = inTexture.read(gid);
        float r = pow(max(0.0f, c.r), kRec709Gamma);
        float g = pow(max(0.0f, c.g), kRec709Gamma);
        float b = pow(max(0.0f, c.b), kRec709Gamma);
        outTexture.write(float4(r, g, b, c.a), gid);
    }
    // CS-001: PQ (ST 2084) EOTF and OETF. kPQ_* defined above with waveform.
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
            if (c == 3) { l[c] = N; continue; }
            if (N <= 0.0) { l[c] = 0.0; continue; }
            float v = pow(N, 1.0f / kPQ_m2);
            float denom = kPQ_c2 - kPQ_c3 * v;
            if (denom <= 0.0) { l[c] = 1.0; continue; }
            float num = max(v - kPQ_c1, 0.0f);
            float L = kPQ_Lmax * pow(num / denom, 1.0f / kPQ_m1);
            l[c] = min(1.0f, L / kPQ_Lmax);
        }
        outTexture.write(l, gid);
    }
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
            float x = pow(L / kPQ_Lmax, kPQ_m1);
            float num = kPQ_c1 + x * kPQ_c2;
            float denom = 1.0f + x * kPQ_c3;
            if (denom <= 0.0) { n[c] = 1.0; continue; }
            float N = pow(num / denom, kPQ_m2);
            n[c] = max(0.0f, min(1.0f, N));
        }
        outTexture.write(n, gid);
    }
    // CS-002: HLG (BT.2100) OETF/EOTF. a=0.17883277, b=0.28466892, c=0.55991073.
    constant float kHLG_a = 0.17883277f;
    constant float kHLG_b = 0.28466892f;
    constant float kHLG_c = 0.55991073f;
    constant float kHLG_one12 = 1.0f / 12.0f;
    static inline float hlg_oetf_channel(float E) {
        if (E <= kHLG_one12) return sqrt(3.0f * E);
        return kHLG_a * log(12.0f * E - kHLG_b) + kHLG_c;
    }
    static inline float hlg_eotf_channel(float Ep) {
        if (Ep <= 0.5f) return (Ep * Ep) / 3.0f;
        return (exp((Ep - kHLG_c) / kHLG_a) + kHLG_b) * kHLG_one12;
    }
    kernel void hlg_linear_to_hlg_signal(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 linear = inputTexture.read(gid);
        float r = max(0.0f, min(1.0f, linear.r));
        float g = max(0.0f, min(1.0f, linear.g));
        float b = max(0.0f, min(1.0f, linear.b));
        float4 hlg = float4(hlg_oetf_channel(r), hlg_oetf_channel(g), hlg_oetf_channel(b), linear.a);
        outTexture.write(hlg, gid);
    }
    kernel void hlg_signal_to_linear(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 hlg = inputTexture.read(gid);
        float r = max(0.0f, min(1.0f, hlg.r));
        float g = max(0.0f, min(1.0f, hlg.g));
        float b = max(0.0f, min(1.0f, hlg.b));
        float4 linear = float4(hlg_eotf_channel(r), hlg_eotf_channel(g), hlg_eotf_channel(b), hlg.a);
        outTexture.write(linear, gid);
    }
    // CS-006: Sony SLog3 OETF/EOTF (0–1 normalised; Sony Technical Summary / Colour Science).
    constant float kSLog3_linearSegmentThreshold = 0.01125000f;
    constant float kSLog3_logThreshold = 171.2102946929f / 1023.0f;
    constant float kSLog3_denom = 171.2102946929f - 95.0f;
    constant float kSLog3_logScale = 261.5f;
    constant float kSLog3_logOffset = 420.0f;
    constant float kSLog3_ratio = 0.19f;
    constant float kSLog3_in = 0.01f;
    static inline float slog3_oetf_channel(float x) {
        if (x >= kSLog3_linearSegmentThreshold)
            return (kSLog3_logOffset + log10((x + kSLog3_in) / kSLog3_ratio) * kSLog3_logScale) / 1023.0f;
        return (x * kSLog3_denom / 0.01125000f + 95.0f) / 1023.0f;
    }
    static inline float slog3_eotf_channel(float y) {
        if (y >= kSLog3_logThreshold)
            return pow(10.0f, (y * 1023.0f - kSLog3_logOffset) / kSLog3_logScale) * kSLog3_ratio - kSLog3_in;
        return (y * 1023.0f - 95.0f) * 0.01125000f / kSLog3_denom;
    }
    kernel void slog3_linear_to_slog3_signal(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 linear = inputTexture.read(gid);
        float r = max(0.0f, min(1.0f, linear.r));
        float g = max(0.0f, min(1.0f, linear.g));
        float b = max(0.0f, min(1.0f, linear.b));
        float4 slog3 = float4(slog3_oetf_channel(r), slog3_oetf_channel(g), slog3_oetf_channel(b), linear.a);
        outTexture.write(slog3, gid);
    }
    kernel void slog3_signal_to_linear(
        texture2d<float, access::read> inputTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
        float4 slog3 = inputTexture.read(gid);
        float r = max(0.0f, min(1.0f, slog3.r));
        float g = max(0.0f, min(1.0f, slog3.g));
        float b = max(0.0f, min(1.0f, slog3.b));
        float4 linear = float4(slog3_eotf_channel(r), slog3_eotf_channel(g), slog3_eotf_channel(b), slog3.a);
        outTexture.write(linear, gid);
    }
    // CS-004: 3x3 gamut conversion (Rec.709, Rec.2020, DCI-P3, XYZ). CS-006: SGamut3.Cine. Linear RGB in/out.
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
    constant float kSGamut3Cine_RGB_to_XYZ[9] = {
        0.5990839f, 0.2150758f, -0.03206585f,
        0.2489255f, 0.8850685f, -0.02765839f,
        0.1024465f, -0.1001443f, 1.148782f
    };
    // CS-007: Cinema Gamut (Canon, D65) — RGB → XYZ, column-major.
    constant float kCinemaGamut_RGB_to_XYZ[9] = {
        0.71604965f, 0.26126136f, -0.00967635f,
        0.12968348f, 0.86964215f, -0.23648164f,
        0.1047228f, -0.1309035f, 1.33521573f
    };
    // CS-008: V-Gamut (Panasonic, D65) — RGB → XYZ, row-major. Use with gamut_convert for V-Gamut ↔ 709/2020/P3/XYZ.
    constant float kVGamut_RGB_to_XYZ[9] = {
        0.679644f, 0.152211f, 0.1186f,
        0.260686f, 0.774894f, -0.03558f,
        -0.00931f, -0.004612f, 1.10298f
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
            outRgb = max(float3(0.0f), min(float3(1.0f), outRgb));
        outTexture.write(float4(outRgb, inColor.a), gid);
    }
    // QC-002: Gamut violation count (pixels outside [0,1] in target gamut). buffer(0)=9 floats, buffer(1)=atomic_uint*.
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
    // QC-003: Luminance compliance (CS-001). Legal [0,1] for linear L/10000. texture(0)=linear RGB; buffer(0)=countBelow, buffer(1)=countAbove.
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
    // CS-005: ARRI LogC3/LogC4 curves (OETF/EOTF) and AWG3/AWG4 primaries; use gamut_convert with kAWG3/kAWG4 matrices.
    constant float kLogC3_cut = 0.010591f, kLogC3_a = 5.555556f, kLogC3_b = 0.052272f, kLogC3_c = 0.247190f, kLogC3_d = 0.385537f, kLogC3_e = 5.367655f, kLogC3_f = 0.092809f;
    constant float kLogC3_linear_break = kLogC3_e * kLogC3_cut + kLogC3_f;
    static inline float logc3_oetf(float x) { if (x <= kLogC3_cut) return kLogC3_e * x + kLogC3_f; return kLogC3_c * log10(max(1e-10f, kLogC3_a * x + kLogC3_b)) + kLogC3_d; }
    static inline float logc3_eotf(float t) { if (t <= kLogC3_linear_break) return (t - kLogC3_f) / kLogC3_e; return (pow(10.0f, (t - kLogC3_d) / kLogC3_c) - kLogC3_b) / kLogC3_a; }
    constant float kLogC4_a = 2231.826309f, kLogC4_b = 0.907136f, kLogC4_c = 0.092864f, kLogC4_s = 0.113597f, kLogC4_t = -0.018057f;
    static inline float logc4_oetf(float E) { if (E < kLogC4_t) return (E - kLogC4_t) / kLogC4_s; return (log2(max(1e-10f, kLogC4_a * E + 64.0f)) - 6.0f) / 14.0f * kLogC4_b + kLogC4_c; }
    static inline float logc4_eotf(float Ep) { if (Ep < 0.0f) return Ep * kLogC4_s + kLogC4_t; return (pow(2.0f, 14.0f * (Ep - kLogC4_c) / kLogC4_b + 6.0f) - 64.0f) / kLogC4_a; }
    kernel void arri_logc3_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); float r = max(0.0f, min(1.0f, L.r)), g = max(0.0f, min(1.0f, L.g)), b = max(0.0f, min(1.0f, L.b));
        o.write(float4(logc3_oetf(r), logc3_oetf(g), logc3_oetf(b), L.a), gid);
    }
    kernel void arri_logc3_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); float r = max(0.0f, min(1.0f, C.r)), g = max(0.0f, min(1.0f, C.g)), b = max(0.0f, min(1.0f, C.b));
        o.write(float4(logc3_eotf(r), logc3_eotf(g), logc3_eotf(b), C.a), gid);
    }
    kernel void arri_logc4_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); float r = max(0.0f, min(1.0f, L.r)), g = max(0.0f, min(1.0f, L.g)), b = max(0.0f, min(1.0f, L.b));
        o.write(float4(logc4_oetf(r), logc4_oetf(g), logc4_oetf(b), L.a), gid);
    }
    kernel void arri_logc4_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); float r = max(0.0f, min(1.0f, C.r)), g = max(0.0f, min(1.0f, C.g)), b = max(0.0f, min(1.0f, C.b));
        o.write(float4(logc4_eotf(r), logc4_eotf(g), logc4_eotf(b), C.a), gid);
    }
    // CS-007: Canon Log2/Log3 OETF/EOTF (0–1 normalised; Canon2020 / Colour Science).
    constant float kCanonLog2_scale = 87.09937546f, kCanonLog2_logCoeff = 0.24136077f, kCanonLog2_offset = 0.092864125f;
    static inline float canon_log2_oetf_channel(float x) { x = max(0.0f, min(1.0f, x)); return kCanonLog2_logCoeff * log10(x * kCanonLog2_scale + 1.0f) + kCanonLog2_offset; }
    static inline float canon_log2_eotf_channel(float y) { y = max(0.0f, min(1.0f, y)); if (y <= kCanonLog2_offset) return 0.0f; return (pow(10.0f, (y - kCanonLog2_offset) / kCanonLog2_logCoeff) - 1.0f) / kCanonLog2_scale; }
    constant float kCanonLog3_linearSlope = 1.9754798f, kCanonLog3_linearOffset = 0.12512219f, kCanonLog3_logScale = 14.98325f, kCanonLog3_logCoeff = 0.36726845f, kCanonLog3_logOffset = 0.12240537f;
    constant float kCanonLog3_linearBreak = (0.15277891f - 0.12512219f) / 1.9754798f;
    static inline float canon_log3_oetf_channel(float x) { x = max(0.0f, min(1.0f, x)); if (x > kCanonLog3_linearBreak) return kCanonLog3_logCoeff * log10(x * kCanonLog3_logScale + 1.0f) + kCanonLog3_logOffset; return kCanonLog3_linearSlope * x + kCanonLog3_linearOffset; }
    constant float kCanonLog3_linearLow = 0.097465473f, kCanonLog3_linearHigh = 0.15277891f;
    static inline float canon_log3_eotf_channel(float y) { y = max(0.0f, min(1.0f, y)); if (y <= kCanonLog3_linearLow) return 0.0f; if (y <= kCanonLog3_linearHigh) return (y - kCanonLog3_linearOffset) / kCanonLog3_linearSlope; return (pow(10.0f, (y - kCanonLog3_logOffset) / kCanonLog3_logCoeff) - 1.0f) / kCanonLog3_logScale; }
    kernel void canon_log2_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(canon_log2_oetf_channel(L.r), canon_log2_oetf_channel(L.g), canon_log2_oetf_channel(L.b), L.a), gid);
    }
    kernel void canon_log2_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(canon_log2_eotf_channel(C.r), canon_log2_eotf_channel(C.g), canon_log2_eotf_channel(C.b), C.a), gid);
    }
    kernel void canon_log3_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(canon_log3_oetf_channel(L.r), canon_log3_oetf_channel(L.g), canon_log3_oetf_channel(L.b), L.a), gid);
    }
    kernel void canon_log3_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(canon_log3_eotf_channel(C.r), canon_log3_eotf_channel(C.g), canon_log3_eotf_channel(C.b), C.a), gid);
    }
    // CS-008: Panasonic VLog OETF/EOTF (0–1 normalised; Panasonic VARICAM V-Log/V-Gamut).
    constant float kVLog_cut1 = 0.01f, kVLog_cut2 = 0.181f, kVLog_b = 0.00873f, kVLog_c = 0.241514f, kVLog_d = 0.598206f, kVLog_linearSlope = 5.6f, kVLog_linearOffset = 0.125f;
    static inline float vlog_oetf_channel(float L) { L = max(0.0f, min(1.0f, L)); if (L < kVLog_cut1) return kVLog_linearSlope * L + kVLog_linearOffset; return kVLog_c * log10(L + kVLog_b) + kVLog_d; }
    static inline float vlog_eotf_channel(float V) { V = max(0.0f, min(1.0f, V)); if (V < kVLog_cut2) return (V - kVLog_linearOffset) / kVLog_linearSlope; return pow(10.0f, (V - kVLog_d) / kVLog_c) - kVLog_b; }
    kernel void vlog_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(vlog_oetf_channel(L.r), vlog_oetf_channel(L.g), vlog_oetf_channel(L.b), L.a), gid);
    }
    kernel void vlog_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(vlog_eotf_channel(C.r), vlog_eotf_channel(C.g), vlog_eotf_channel(C.b), C.a), gid);
    }
    // CS-009: RED Log3G10 OETF/EOTF (0–1 normalised; RED IPP2 / RED white paper). V = log10(1+9*L); L = (10^V-1)/9.
    constant float kLog3G10_scale = 9.0f;
    static inline float log3g10_oetf_channel(float L) { L = max(0.0f, min(1.0f, L)); return log10(1.0f + kLog3G10_scale * L); }
    static inline float log3g10_eotf_channel(float V) { V = max(0.0f, min(1.0f, V)); return (pow(10.0f, V) - 1.0f) / kLog3G10_scale; }
    kernel void red_log3g10_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(log3g10_oetf_channel(L.r), log3g10_oetf_channel(L.g), log3g10_oetf_channel(L.b), L.a), gid);
    }
    kernel void red_log3g10_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(log3g10_eotf_channel(C.r), log3g10_eotf_channel(C.g), log3g10_eotf_channel(C.b), C.a), gid);
    }
    // CS-010: ACEScc and ACEScct OETF/EOTF (0–1 normalised; S-2014-003, S-2016-001; colour-science).
    constant float kACEScc_logScale = 17.52f, kACEScc_logOffset = 9.72f, kACEScc_linearUpper = 0.000030517578125f;
    constant float kACEScc_minCV = -0.3584474886f, kACEScc_logStart = -0.3014292603f;
    static inline float acescc_oetf_channel(float x) { x = max(0.0f, min(1.0f, x)); if (x <= 0.0f) return kACEScc_minCV; if (x < kACEScc_linearUpper) return (log2(1.0f/65536.0f + x*0.5f) + kACEScc_logOffset) / kACEScc_logScale; return (log2(x) + kACEScc_logOffset) / kACEScc_logScale; }
    static inline float acescc_eotf_channel(float cv) { cv = max(kACEScc_minCV, min(1.0f, cv)); if (cv < kACEScc_logStart) return (pow(2.0f, cv*kACEScc_logScale - kACEScc_logOffset) - 1.0f/65536.0f)*2.0f; return min(1.0f, pow(2.0f, cv*kACEScc_logScale - kACEScc_logOffset)); }
    constant float kACEScct_XBrk = 0.0078125f, kACEScct_YBrk = 0.155251141552511f, kACEScct_A = 10.5402377416545f, kACEScct_B = 0.0729055341958355f;
    static inline float acescct_oetf_channel(float x) { x = max(0.0f, min(1.0f, x)); if (x <= kACEScct_XBrk) return kACEScct_A*x + kACEScct_B; return (log2(x) + kACEScc_logOffset) / kACEScc_logScale; }
    static inline float acescct_eotf_channel(float cv) { cv = max(0.0f, min(1.0f, cv)); if (cv > kACEScct_YBrk) return min(1.0f, pow(2.0f, cv*kACEScc_logScale - kACEScc_logOffset)); return max(0.0f, (cv - kACEScct_B) / kACEScct_A); }
    kernel void acescc_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(acescc_oetf_channel(L.r), acescc_oetf_channel(L.g), acescc_oetf_channel(L.b), L.a), gid);
    }
    kernel void acescc_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(acescc_eotf_channel(C.r), acescc_eotf_channel(C.g), acescc_eotf_channel(C.b), C.a), gid);
    }
    kernel void acescct_linear_to_log(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 L = i.read(gid); o.write(float4(acescct_oetf_channel(L.r), acescct_oetf_channel(L.g), acescct_oetf_channel(L.b), L.a), gid);
    }
    kernel void acescct_log_to_linear(texture2d<float, access::read> i [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= i.get_width() || gid.y >= i.get_height()) return;
        float4 C = i.read(gid); o.write(float4(acescct_eotf_channel(C.r), acescct_eotf_channel(C.g), acescct_eotf_channel(C.b), C.a), gid);
    }
    // CS-009: REDWideGamutRGB (D65) — RGB → XYZ, row-major. Use with gamut_convert for REDWideGamut ↔ 709/2020/P3/XYZ.
    constant float kREDWideGamut_RGB_to_XYZ[9] = {
        0.735275f, 0.264725f, 0.0f,
        0.299340f, 0.674897f, 0.025763f,
        0.156396f, 0.050701f, 0.792903f
    };
    // SC-014: False Color (Brightness mode). Luminance → ramp: dark=blue, mid=green, bright=red. Input: linear RGB (MT-007).
    kernel void false_color_luminance(
        texture2d<float, access::read> inTexture [[texture(0)]],
        texture2d<float, access::write> outTexture [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        float4 c = inTexture.read(gid);
        float lum = kLumR * c.r + kLumG * c.g + kLumB * c.b;
        lum = max(0.0f, min(1.0f, lum));
        float r, g, b;
        if (lum <= 0.5f) {
            float t = lum * 2.0f;
            r = 0.0f; g = t; b = 1.0f - t;
        } else {
            float t = (lum - 0.5f) * 2.0f;
            r = t; g = 1.0f - t; b = 0.0f;
        }
        outTexture.write(float4(r, g, b, 1.0f), gid);
    }
    // SC-015: False Color (Gamut Warning mode). Out-of-gamut → magenta; in-gamut → original. buffer(0)=9 floats.
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
    // SC-009: Histogram pipeline — clear bins, count from texture (atomic), render to output texture.
    // histogram_clear_bins: zeros 256*4 = 1024 uint32 bins.
    kernel void histogram_clear_bins(
        device uint* bins [[buffer(0)]],
        uint tid [[thread_position_in_grid]])
    {
        if (tid < 1024u) bins[tid] = 0u;
    }
    // histogram_count_bins: reads input texture, atomically increments R/G/B/Luma bins (256 each).
    kernel void histogram_count_bins(
        texture2d<float, access::read> src [[texture(0)]],
        device atomic_uint* bins [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = src.get_width(), h = src.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float4 p = src.read(gid);
        float r = saturate(p.r), g = saturate(p.g), b = saturate(p.b);
        float lum = kLumR * r + kLumG * g + kLumB * b;
        uint n = 256u;
        atomic_fetch_add_explicit(&bins[min(uint(r * 255.0f), n - 1u)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[n + min(uint(g * 255.0f), n - 1u)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[2u * n + min(uint(b * 255.0f), n - 1u)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[3u * n + min(uint(lum * 255.0f), n - 1u)], 1u, memory_order_relaxed);
    }
    // histogram_render_to_texture: reads bin counts, normalizes (log2), renders colored filled histogram.
    // mode: 0=overlay (all channels on one graph), 1=RGB split (3 vertical sections), 2=RGBY split (4 vertical sections with luma).
    kernel void histogram_render_to_texture(
        device const uint* bins [[buffer(0)]],
        constant uint* modePtr [[buffer(1)]],
        texture2d<float, access::write> outTex [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outTex.get_width(), h = outTex.get_height();
        if (gid.x >= w || gid.y >= h) return;
        uint mode = (modePtr != nullptr) ? modePtr[0] : 0u;
        uint numBins = 256u;
        // Find max across all 4 channels for normalization
        uint maxVal = 1u;
        for (uint i = 0u; i < numBins * 4u; i++) {
            maxVal = max(maxVal, bins[i]);
        }
        float logMax = log2(float(maxVal) + 1.0f);
        uint binIdx = min(gid.x * numBins / w, numBins - 1u);
        // 7-tap weighted smoothing to eliminate banding from legal range 8-bit quantization gaps.
        // Weights: 1-2-3-4-3-2-1 (sum=16). Wider kernel fills gaps where some uint8 bins have zero counts.
        uint b0 = (binIdx > 2u) ? binIdx - 3u : 0u;
        uint b1 = (binIdx > 1u) ? binIdx - 2u : 0u;
        uint b2 = (binIdx > 0u) ? binIdx - 1u : 0u;
        uint b3 = binIdx;
        uint b4 = min(binIdx + 1u, numBins - 1u);
        uint b5 = min(binIdx + 2u, numBins - 1u);
        uint b6 = min(binIdx + 3u, numBins - 1u);
        float rV = (float(bins[b0]) + 2.0f*float(bins[b1]) + 3.0f*float(bins[b2]) + 4.0f*float(bins[b3]) + 3.0f*float(bins[b4]) + 2.0f*float(bins[b5]) + float(bins[b6])) / 16.0f;
        float gV = (float(bins[numBins+b0]) + 2.0f*float(bins[numBins+b1]) + 3.0f*float(bins[numBins+b2]) + 4.0f*float(bins[numBins+b3]) + 3.0f*float(bins[numBins+b4]) + 2.0f*float(bins[numBins+b5]) + float(bins[numBins+b6])) / 16.0f;
        float bV = (float(bins[numBins*2u+b0]) + 2.0f*float(bins[numBins*2u+b1]) + 3.0f*float(bins[numBins*2u+b2]) + 4.0f*float(bins[numBins*2u+b3]) + 3.0f*float(bins[numBins*2u+b4]) + 2.0f*float(bins[numBins*2u+b5]) + float(bins[numBins*2u+b6])) / 16.0f;
        float lV = (float(bins[numBins*3u+b0]) + 2.0f*float(bins[numBins*3u+b1]) + 3.0f*float(bins[numBins*3u+b2]) + 4.0f*float(bins[numBins*3u+b3]) + 3.0f*float(bins[numBins*3u+b4]) + 2.0f*float(bins[numBins*3u+b5]) + float(bins[numBins*3u+b6])) / 16.0f;
        float rH = logMax > 0.0f ? log2(rV + 1.0f) / logMax : 0.0f;
        float gH = logMax > 0.0f ? log2(gV + 1.0f) / logMax : 0.0f;
        float bH = logMax > 0.0f ? log2(bV + 1.0f) / logMax : 0.0f;
        float lH = logMax > 0.0f ? log2(lV + 1.0f) / logMax : 0.0f;

        if (mode == 0u) {
            // Overlay: all channels on one graph
            float yFrac = 1.0f - float(gid.y) / float(max(1u, h - 1u));
            float3 color = float3(0.06f, 0.06f, 0.08f);
            if (yFrac <= lH) color = mix(color, float3(0.5f, 0.5f, 0.5f), 0.35f);
            if (yFrac <= rH) color = mix(color, float3(0.9f, 0.15f, 0.15f), 0.55f);
            if (yFrac <= gH) color = mix(color, float3(0.15f, 0.85f, 0.15f), 0.55f);
            if (yFrac <= bH) color = mix(color, float3(0.2f, 0.35f, 0.95f), 0.55f);
            outTex.write(float4(color, 1.0f), gid);
        } else if (mode == 1u) {
            // RGB Split: 3 vertical sections (R top, G middle, B bottom)
            uint sectionH = h / 3u;
            uint section = gid.y / max(1u, sectionH);
            if (section > 2u) section = 2u;
            float localY = float(gid.y - section * sectionH) / float(max(1u, sectionH - 1u));
            float yFrac = 1.0f - localY;
            float3 bg = float3(0.06f, 0.06f, 0.08f);
            float3 color = bg;
            if (section == 0u && yFrac <= rH) color = mix(bg, float3(0.9f, 0.15f, 0.15f), 0.75f);
            else if (section == 1u && yFrac <= gH) color = mix(bg, float3(0.15f, 0.85f, 0.15f), 0.75f);
            else if (section == 2u && yFrac <= bH) color = mix(bg, float3(0.2f, 0.35f, 0.95f), 0.75f);
            // Thin separator line between sections
            if (gid.y == sectionH || gid.y == sectionH * 2u) color = float3(0.2f, 0.2f, 0.25f);
            outTex.write(float4(color, 1.0f), gid);
        } else {
            // RGBY Split: 4 vertical sections (R, G, B, Y)
            uint sectionH = h / 4u;
            uint section = gid.y / max(1u, sectionH);
            if (section > 3u) section = 3u;
            float localY = float(gid.y - section * sectionH) / float(max(1u, sectionH - 1u));
            float yFrac = 1.0f - localY;
            float3 bg = float3(0.06f, 0.06f, 0.08f);
            float3 color = bg;
            if (section == 0u && yFrac <= rH) color = mix(bg, float3(0.9f, 0.15f, 0.15f), 0.75f);
            else if (section == 1u && yFrac <= gH) color = mix(bg, float3(0.15f, 0.85f, 0.15f), 0.75f);
            else if (section == 2u && yFrac <= bH) color = mix(bg, float3(0.2f, 0.35f, 0.95f), 0.75f);
            else if (section == 3u && yFrac <= lH) color = mix(bg, float3(0.7f, 0.7f, 0.7f), 0.75f);
            // Thin separator lines
            if (gid.y == sectionH || gid.y == sectionH * 2u || gid.y == sectionH * 3u) color = float3(0.2f, 0.2f, 0.25f);
            outTex.write(float4(color, 1.0f), gid);
        }
    }
    // QC-012: Signal continuity — sample 64x64 grid for avg luminance and frame signature.
    kernel void signal_continuity_sample(
        texture2d<float, access::read> inTexture [[texture(0)]],
        device float* outLuminance [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = inTexture.get_width(), h = inTexture.get_height();
        if (gid.x >= 64u || gid.y >= 64u) return;
        uint sx = (w > 1u) ? (gid.x * (w - 1u) / 63u) : 0u;
        uint sy = (h > 1u) ? (gid.y * (h - 1u) / 63u) : 0u;
        float4 c = inTexture.read(uint2(sx, sy));
        float lum = kLumR * c.r + kLumG * c.g + kLumB * c.b;
        outLuminance[gid.y * 64u + gid.x] = max(0.0f, min(1.0f, lum));
    }
    """

    /// Minimal Metal source: placeholder convert + copy_vertex/copy_fragment for display blit. Used when full embedded fails to compile.
    private static let minimalPlaceholderSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void convert_v210_to_rgb_placeholder(
        device const uchar* buffer [[buffer(0)]],
        texture2d<float, access::write> outTexture [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        outTexture.write(float4(0.5, 0.5, 0.5, 1.0), gid);
    }
    struct CopyVertexOut { float4 position [[position]]; float2 uv; };
    vertex CopyVertexOut copy_vertex(uint id [[vertex_id]]) {
        float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uvs[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
        CopyVertexOut o;
        o.position = float4(positions[id], 0, 1);
        o.uv = uvs[id];
        return o;
    }
    fragment float4 copy_fragment(CopyVertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::normalized, filter::linear);
        return tex.sample(s, in.uv);
    }
    """

    private init?() {
        // MT-014: Enable Metal validation in dev builds (DEBUG or MTL_VALIDATION_LAYER).
        var validationEnabled = false
        #if DEBUG
        setenv("MTL_DEBUG_LAYER", "1", 1)
        setenv("MTL_SHADER_VALIDATION", "1", 1)
        validationEnabled = true
        #else
        if ProcessInfo.processInfo.environment["MTL_VALIDATION_LAYER"] != nil {
            setenv("MTL_DEBUG_LAYER", "1", 1)
            setenv("MTL_SHADER_VALIDATION", "1", 1)
            validationEnabled = true
        }
        #endif

        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            // #region agent log
            debugSessionLog(location: "MetalEngine.init", message: "MetalEngine init failed", data: ["deviceNil": MTLCreateSystemDefaultDevice() == nil], hypothesisId: "H1")
            // #endregion
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        if validationEnabled {
            HDRLogger.info(category: "Metal", "Metal validation layer enabled (DEBUG or MTL_VALIDATION_LAYER)")
        }
        self.scopeComputeQueue = dev.makeCommandQueue()
        self.library = MetalEngine.loadShaderLibrary(device: dev)
        self.frameManager = TripleBufferedFrameManager(device: dev)
        self.texturePool = TexturePool(device: dev)
        self.memoryPressureSource = Self.installMemoryPressureHandler(
            texturePool: texturePool,
            frameManager: frameManager,
            logCategory: logCategory,
            queue: memoryPressureQueue
        )
        memoryPressureSource?.activate()
        // #region agent log
        debugSessionLog(location: "MetalEngine.init", message: "MetalEngine init success", data: ["libraryLoaded": library != nil], hypothesisId: "H1")
        // #endregion
        HDRLogger.info(category: logCategory, "MetalEngine initialized; library: \(library != nil ? "loaded" : "nil"); scopeComputeQueue: \(scopeComputeQueue != nil ? "yes" : "no")")
    }

    /// MT-011: Subscribe to system memory pressure; on warning/critical reduce pool and triple-buffer; on normal restore.
    private static func installMemoryPressureHandler(
        texturePool: TexturePool,
        frameManager: TripleBufferedFrameManager,
        logCategory: String,
        queue: DispatchQueue
    ) -> DispatchSourceMemoryPressure? {
        let mask: DispatchSource.MemoryPressureEvent = [.warning, .critical, .normal]
        let source = DispatchSource.makeMemoryPressureSource(eventMask: mask, queue: queue)
        source.setEventHandler { [weak texturePool, weak frameManager] in
            let event = source.data
            switch event {
            case .normal:
                texturePool?.setMaxCachedPerKey(TexturePool.defaultMaxCachedPerKey)
                HDRLogger.info(category: logCategory, "Memory pressure normal: restored TexturePool max cached per key")
            case .warning:
                texturePool?.setMaxCachedPerKey(2)
                texturePool?.trimToMax()
                frameManager?.releaseUnusedSlots()
                HDRLogger.info(category: logCategory, "Memory pressure warning: reduced TexturePool and released unused triple-buffer slots")
            case .critical:
                texturePool?.setMaxCachedPerKey(0)
                texturePool?.trimToMax()
                frameManager?.releaseUnusedSlots()
                HDRLogger.info(category: logCategory, "Memory pressure critical: disabled texture caching and released unused triple-buffer slots")
            default:
                break
            }
        }
        return source
    }

    /// Load shader library: embedded source first (guarantees convert_v210_to_rgb_placeholder), then minimal fallback, default, file.
    /// SPM apps often have no default .metallib; embedded ensures the capture pipeline can create MasterPipeline.
    private static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        do {
            let lib = try device.makeLibrary(source: embeddedLibrarySource, options: nil)
            HDRLogger.info(category: "Metal", "Shader library loaded from embedded source")
            return lib
        } catch {
            // #region agent log
            debugSessionLog(location: "MetalEngine.loadShaderLibrary", message: "embedded source compile failed", data: ["error": "\(error)"], hypothesisId: "H2b")
            // #endregion
            HDRLogger.error(category: "Metal", "Shader library embedded source failed: \(error)")
        }
        do {
            let lib = try device.makeLibrary(source: minimalPlaceholderSource, options: nil)
            HDRLogger.info(category: "Metal", "Shader library loaded from minimal placeholder source")
            return lib
        } catch {
            // #region agent log
            debugSessionLog(location: "MetalEngine.loadShaderLibrary", message: "minimal placeholder compile failed", data: ["error": "\(error)"], hypothesisId: "H2b")
            // #endregion
            HDRLogger.error(category: "Metal", "Shader library minimal placeholder failed: \(error)")
        }
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        let searchPaths: [String] = [
            "Shaders/Common/Placeholder.metal",
            "../Shaders/Common/Placeholder.metal",
            "Sources/../Shaders/Common/Placeholder.metal"
        ]
        let cwd = FileManager.default.currentDirectoryPath
        for rel in searchPaths {
            let path = (cwd as NSString).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: path),
               let mainSource = try? String(contentsOfFile: path, encoding: .utf8) {
                var source = mainSource
                // Append Shaders/Colorspace/*.metal (e.g. HLG.metal) when present.
                let relDir = (rel as NSString).deletingLastPathComponent
                let commonDir = (cwd as NSString).appendingPathComponent(relDir)
                let colorspaceDir = (commonDir as NSString).deletingLastPathComponent + "/Colorspace"
                if let files = try? FileManager.default.contentsOfDirectory(atPath: colorspaceDir),
                   !files.isEmpty {
                    for name in files.sorted() where name.hasSuffix(".metal") {
                        let metalPath = (colorspaceDir as NSString).appendingPathComponent(name)
                        if let extra = try? String(contentsOfFile: metalPath, encoding: .utf8) {
                            source += "\n" + extra
                        }
                    }
                }
                if let lib = try? device.makeLibrary(source: source, options: nil) {
                    return lib
                }
            }
        }
        HDRLogger.error(category: "Metal", "Shader library failed to load (embedded, default, and file)")
        return nil
    }

    /// Returns a compute/raster function from the shared library, or nil if not found.
    public func makeFunction(name: String) -> MTLFunction? {
        library?.makeFunction(name: name)
    }

    // MARK: - CS-012 / CS-013: GPU 3D LUT application (trilinear or tetrahedral)

    private var lut3DApplyPipelineState: MTLComputePipelineState?
    private var lut3DTetrahedralApplyPipelineState: MTLComputePipelineState?

    /// Encodes the 3D LUT apply kernel onto the given command buffer.
    /// Input and output must be 2D textures (e.g. rgba32Float); lut must be a 3D texture from CubeLUT (CS-011).
    /// When useTetrahedral is true (CS-013), uses tetrahedral interpolation for highest quality; otherwise trilinear.
    /// Caller commits the command buffer.
    public func encodeApply3DLUT(
        input: MTLTexture,
        lut: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        useTetrahedral: Bool = false
    ) -> Bool {
        if useTetrahedral {
            if lut3DTetrahedralApplyPipelineState == nil {
                guard let fn = makeFunction(name: "apply_3d_lut_tetrahedral") else {
                    HDRLogger.error(category: logCategory, "apply_3d_lut_tetrahedral function not found")
                    return false
                }
                do {
                    lut3DTetrahedralApplyPipelineState = try device.makeComputePipelineState(function: fn)
                    HDRLogger.info(category: logCategory, "CS-013: 3D LUT tetrahedral apply pipeline created")
                } catch {
                    HDRLogger.error(category: logCategory, "3D LUT tetrahedral apply pipeline failed: \(error)")
                    return false
                }
            }
            guard let pipeline = lut3DTetrahedralApplyPipelineState else { return false }
            let w = input.width
            let h = input.height
            guard output.width == w, output.height == h else { return false }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(lut, index: 1)
            encoder.setTexture(output, index: 2)
            let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
            let gridSize = MTLSize(
                width: (w + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (h + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
            return true
        }
        if lut3DApplyPipelineState == nil {
            guard let fn = makeFunction(name: "apply_3d_lut") else {
                HDRLogger.error(category: logCategory, "apply_3d_lut function not found")
                return false
            }
            do {
                lut3DApplyPipelineState = try device.makeComputePipelineState(function: fn)
                HDRLogger.info(category: logCategory, "CS-012: 3D LUT apply pipeline created")
            } catch {
                HDRLogger.error(category: logCategory, "3D LUT apply pipeline failed: \(error)")
                return false
            }
        }
        guard let pipeline = lut3DApplyPipelineState else { return false }
        let w = input.width
        let h = input.height
        guard output.width == w, output.height == h else { return false }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(lut, index: 1)
        encoder.setTexture(output, index: 2)
        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(
            width: (w + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (h + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        return true
    }

    // MARK: - CS-015: LUT pipeline format conversion (bgra8 ↔ float)

    private var bgra8ToFloatPipelineState: MTLComputePipelineState?
    private var floatToBgra8PipelineState: MTLComputePipelineState?

    /// Encodes bgra8Unorm → rgba32Float copy (normalized read). For LUT input when pipeline uses 8-bit convert output.
    public func encodeBgra8ToFloat(
        input: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if bgra8ToFloatPipelineState == nil {
            guard let fn = makeFunction(name: "bgra8_to_float") else {
                HDRLogger.error(category: logCategory, "bgra8_to_float function not found")
                return false
            }
            do {
                bgra8ToFloatPipelineState = try device.makeComputePipelineState(function: fn)
            } catch {
                HDRLogger.error(category: logCategory, "bgra8_to_float pipeline failed: \(error)")
                return false
            }
        }
        guard let pipeline = bgra8ToFloatPipelineState,
              input.width == output.width, input.height == output.height,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        let (grid, group) = ComputeDispatch.threadgroupsForTexture2D(width: input.width, height: input.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return true
    }

    /// Encodes rgba32Float [0,1] → bgra8Unorm write (clamped). For LUT output for display/scope.
    public func encodeFloatToBgra8(
        input: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if floatToBgra8PipelineState == nil {
            guard let fn = makeFunction(name: "float_to_bgra8") else {
                HDRLogger.error(category: logCategory, "float_to_bgra8 function not found")
                return false
            }
            do {
                floatToBgra8PipelineState = try device.makeComputePipelineState(function: fn)
            } catch {
                HDRLogger.error(category: logCategory, "float_to_bgra8 pipeline failed: \(error)")
                return false
            }
        }
        guard let pipeline = floatToBgra8PipelineState,
              input.width == output.width, input.height == output.height,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        let (grid, group) = ComputeDispatch.threadgroupsForTexture2D(width: input.width, height: input.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return true
    }

    // MARK: - SC-026: Scope input downsampling at 4K (4ms budget)

    private var scopeDownsamplePipelineState: MTLComputePipelineState?

    /// Encodes a 2x bilinear downsample (input → output). Output must be half width/height of input. Used for scope path when input is 4K to meet 4ms budget.
    public func encodeScopeDownsample(
        input: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard output.width == input.width / 2, output.height == input.height / 2 else { return false }
        if scopeDownsamplePipelineState == nil {
            guard let fn = makeFunction(name: "scope_downsample_2x") else {
                HDRLogger.error(category: logCategory, "scope_downsample_2x function not found")
                return false
            }
            do {
                scopeDownsamplePipelineState = try device.makeComputePipelineState(function: fn)
                HDRLogger.info(category: logCategory, "SC-026: scope_downsample_2x pipeline created")
            } catch {
                HDRLogger.error(category: logCategory, "scope_downsample_2x pipeline failed: \(error)")
                return false
            }
        }
        guard let pipeline = scopeDownsamplePipelineState,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        let (grid, group) = ComputeDispatch.threadgroupsForTexture2D(width: output.width, height: output.height, pipeline: pipeline)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return true
    }

    // MARK: - QC-002: Gamut violation detector (CS-004)

    private var gamutViolationCountPipelineState: MTLComputePipelineState?

    /// Runs gamut violation count kernel (pixels outside [0,1] in target gamut). Emits QC event (QC-001) when count > 0.
    /// - Parameters:
    ///   - linearRGBTexture: Input linear RGB texture (any size).
    ///   - sourceToTargetMatrix: 9 floats, column-major (source RGB → target RGB); use CS-004 composed matrices.
    ///   - targetGamutName: Label for logging (e.g. "Rec.709", "Rec.2020").
    ///   - timecode: Optional timecode for the QC event.
    /// - Returns: (violationCount, totalPixels), or nil on failure.
    public func runGamutViolationCheck(
        linearRGBTexture: MTLTexture,
        sourceToTargetMatrix: [Float],
        targetGamutName: String,
        timecode: String? = nil
    ) -> (violationCount: UInt32, totalPixels: UInt32)? {
        guard sourceToTargetMatrix.count >= 9 else { return nil }
        if gamutViolationCountPipelineState == nil {
            guard let fn = makeFunction(name: "gamut_violation_count") else {
                HDRLogger.error(category: logCategory, "gamut_violation_count function not found")
                return nil
            }
            do {
                gamutViolationCountPipelineState = try device.makeComputePipelineState(function: fn)
            } catch {
                HDRLogger.error(category: logCategory, "gamut_violation_count pipeline failed: \(error)")
                return nil
            }
        }
        guard let pipeline = gamutViolationCountPipelineState else { return nil }
        let w = linearRGBTexture.width
        let h = linearRGBTexture.height
        let totalPixels = UInt32(w * h)
        guard let matrixBuffer = device.makeBuffer(bytes: sourceToTargetMatrix, length: 9 * MemoryLayout<Float>.size, options: .storageModeShared),
              let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) else { return nil }
        memset(countBuffer.contents(), 0, MemoryLayout<UInt32>.size)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(matrixBuffer, offset: 0, index: 0)
        encoder.setBuffer(countBuffer, offset: 0, index: 1)
        encoder.setTexture(linearRGBTexture, index: 0)
        let tgSize = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let count = countBuffer.contents().load(as: UInt32.self)
        if count > 0 {
            let severity: QCEventSeverity = count > totalPixels / 10 ? .error : (count > totalPixels / 100 ? .warning : .info)
            let event = QCEvent(
                kind: .gamutViolation,
                severity: severity,
                timecode: timecode,
                channel: nil,
                value: Double(count),
                threshold: Double(totalPixels),
                description: "\(count) pixels outside \(targetGamutName) gamut",
                timestamp: Date()
            )
            HDRLogger.logQC(event)
        }
        return (count, totalPixels)
    }

    // MARK: - QC-012: Signal continuity (black/freeze frame detection)

    /// When set, runSignalContinuityAnalysis feeds this monitor each frame. Nil disables continuity checks.
    public var signalContinuityMonitor: SignalContinuityMonitor?

    private var signalContinuityPipelineState: MTLComputePipelineState?
    /// INT-003: Reused buffer for 64×64 luminance samples to avoid per-frame allocation.
    private var signalContinuitySampleBuffer: MTLBuffer?

    /// Samples texture on a 64×64 grid, computes average luminance and frame signature, feeds SignalContinuityMonitor if set.
    /// Call from pipeline each frame after producing the display texture (e.g. processFrame).
    public func runSignalContinuityAnalysis(texture: MTLTexture, timecode: String? = nil) {
        guard let monitor = signalContinuityMonitor else { return }
        if signalContinuityPipelineState == nil {
            guard let fn = makeFunction(name: "signal_continuity_sample") else { return }
            guard let pipeline = try? device.makeComputePipelineState(function: fn) else { return }
            signalContinuityPipelineState = pipeline
        }
        guard let pipeline = signalContinuityPipelineState else { return }
        let sampleCount = 64 * 64
        let bufferLength = sampleCount * MemoryLayout<Float>.size
        if signalContinuitySampleBuffer == nil || signalContinuitySampleBuffer!.length < bufferLength {
            signalContinuitySampleBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
        }
        guard let buffer = signalContinuitySampleBuffer else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 64, height: 64, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        // INT-003: Do not block completion handler (was waitUntilCompleted — caused main-thread freeze when handler ran on main). Use this buffer's completion to read and feed.
        commandBuffer.addCompletedHandler { _ in
            let ptr = buffer.contents().assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            for i in 0..<sampleCount { sum += ptr[i] }
            let avgLuminance = Double(sum / Float(sampleCount))
            var hash: UInt64 = 0xcbf29ce484222325
            for i in 0..<sampleCount {
                let q = UInt8(min(255, max(0, ptr[i] * 255)))
                hash ^= UInt64(q)
                hash = hash &* 0x100000001b3
            }
            monitor.feedFrame(avgLuminance: avgLuminance, frameSignature: hash)
        }
        commandBuffer.commit()
    }

    // MARK: - QC-003: Luminance compliance checker (CS-001)

    private var luminanceCompliancePipelineState: MTLComputePipelineState?

    /// Runs luminance compliance check: pixels with luminance below 0 or above 1 (legal range [0,1] for linear L/10000 per CS-001).
    /// Emits QC events for .luminanceBelow and .luminanceExceedance when counts > 0.
    /// - Parameters:
    ///   - linearRGBTexture: Input linear RGB texture (L/10000 per channel).
    ///   - timecode: Optional timecode for QC events.
    /// - Returns: (belowCount, aboveCount, totalPixels), or nil on failure.
    public func runLuminanceComplianceCheck(
        linearRGBTexture: MTLTexture,
        timecode: String? = nil
    ) -> (belowCount: UInt32, aboveCount: UInt32, totalPixels: UInt32)? {
        if luminanceCompliancePipelineState == nil {
            guard let fn = makeFunction(name: "luminance_compliance_count") else {
                HDRLogger.error(category: logCategory, "luminance_compliance_count function not found")
                return nil
            }
            do {
                luminanceCompliancePipelineState = try device.makeComputePipelineState(function: fn)
            } catch {
                HDRLogger.error(category: logCategory, "luminance_compliance_count pipeline failed: \(error)")
                return nil
            }
        }
        guard let pipeline = luminanceCompliancePipelineState else { return nil }
        let w = linearRGBTexture.width
        let h = linearRGBTexture.height
        let totalPixels = UInt32(w * h)
        let bufSize = MemoryLayout<UInt32>.size
        guard let belowBuffer = device.makeBuffer(length: bufSize, options: .storageModeShared),
              let aboveBuffer = device.makeBuffer(length: bufSize, options: .storageModeShared) else { return nil }
        memset(belowBuffer.contents(), 0, bufSize)
        memset(aboveBuffer.contents(), 0, bufSize)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(belowBuffer, offset: 0, index: 0)
        encoder.setBuffer(aboveBuffer, offset: 0, index: 1)
        encoder.setTexture(linearRGBTexture, index: 0)
        let tgSize = MTLSize(width: 8, height: 8, depth: 1)
        let gridSize = MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1)
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let below = belowBuffer.contents().load(as: UInt32.self)
        let above = aboveBuffer.contents().load(as: UInt32.self)
        if below > 0 {
            let severity: QCEventSeverity = below > totalPixels / 10 ? .error : (below > totalPixels / 100 ? .warning : .info)
            let event = QCEvent(
                kind: .luminanceBelow,
                severity: severity,
                timecode: timecode,
                channel: nil,
                value: Double(below),
                threshold: Double(totalPixels),
                description: "\(below) pixels below legal luminance (L/10000 < 0)",
                timestamp: Date()
            )
            HDRLogger.logQC(event)
        }
        if above > 0 {
            let severity: QCEventSeverity = above > totalPixels / 10 ? .error : (above > totalPixels / 100 ? .warning : .info)
            let event = QCEvent(
                kind: .luminanceExceedance,
                severity: severity,
                timecode: timecode,
                channel: nil,
                value: Double(above),
                threshold: Double(totalPixels),
                description: "\(above) pixels above legal luminance (L/10000 > 1)",
                timestamp: Date()
            )
            HDRLogger.logQC(event)
        }
        return (below, above, totalPixels)
    }

    // MARK: - CS-016: MaxCLL and MaxFALL real-time calculator (CS-001)

    private var maxCLLMaxFALLPipelineState: MTLComputePipelineState?

    /// Result of real-time MaxCLL/MaxFALL calculation from linear RGB (L/10000). Values in cd/m²; 0 means no content or black.
    public struct MaxCLLMaxFALLResult: Sendable {
        public let maxCLL: UInt16   // Maximum content light level (cd/m²)
        public let maxFALL: UInt16  // Maximum frame-average light level (cd/m²)
        public init(maxCLL: UInt16, maxFALL: UInt16) {
            self.maxCLL = maxCLL
            self.maxFALL = maxFALL
        }
    }

    /// Computes MaxCLL and MaxFALL from linear RGB texture (L/10000 per channel, BT.709 luminance). Real-time per-frame.
    /// - Parameter linearRGBTexture: Input linear RGB (L/10000); same semantics as luminance compliance (CS-001).
    /// - Returns: (maxCLL, maxFALL) in cd/m², or nil on failure.
    public func runMaxCLLMaxFALLCalculator(linearRGBTexture: MTLTexture) -> MaxCLLMaxFALLResult? {
        if maxCLLMaxFALLPipelineState == nil {
            guard let fn = makeFunction(name: "maxcll_maxfall_reduce") else {
                HDRLogger.error(category: logCategory, "maxcll_maxfall_reduce function not found")
                return nil
            }
            do {
                maxCLLMaxFALLPipelineState = try device.makeComputePipelineState(function: fn)
            } catch {
                HDRLogger.error(category: logCategory, "maxcll_maxfall_reduce pipeline failed: \(error)")
                return nil
            }
        }
        guard let pipeline = maxCLLMaxFALLPipelineState else { return nil }
        let w = linearRGBTexture.width
        let h = linearRGBTexture.height
        let totalPixels = w * h
        guard totalPixels > 0 else { return MaxCLLMaxFALLResult(maxCLL: 0, maxFALL: 0) }
        let threadgroups = (totalPixels + 255) / 256
        let bufferFloats = threadgroups * 2
        guard let outBuffer = device.makeBuffer(length: bufferFloats * MemoryLayout<Float>.size, options: .storageModeShared) else { return nil }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(linearRGBTexture, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: threadgroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let ptr = outBuffer.contents().assumingMemoryBound(to: Float.self)
        var globalMax: Float = 0
        var totalSum: Float = 0
        for i in 0..<threadgroups {
            globalMax = max(globalMax, ptr[i * 2])
            totalSum += ptr[i * 2 + 1]
        }
        let nitsScale: Float = 10000  // L/10000 -> cd/m²
        let maxCLLNits = globalMax * nitsScale
        let maxFALLNits = totalSum / Float(totalPixels) * nitsScale
        let maxCLL = UInt16(min(65535, max(0, Int(round(maxCLLNits)))))
        let maxFALL = UInt16(min(65535, max(0, Int(round(maxFALLNits)))))
        return MaxCLLMaxFALLResult(maxCLL: maxCLL, maxFALL: maxFALL)
    }

    /// SC-001: Creates a scope accumulation buffer (uint32 per pixel, configurable size).
    /// Use for waveform/vectorscope hit-count accumulation; SC-002 point rasterizer will write into it.
    public func makeScopeAccumulationBuffer(width: Int = 2048, height: Int = 1024) -> ScopeAccumulationBuffer? {
        ScopeAccumulationBuffer(device: device, width: width, height: height)
    }

    // MARK: - MT-013: Screenshot capture from MTLTexture

    /// Captures a screenshot from the given texture (e.g. display or scope). Copies to CPU via blit, returns CGImage.
    /// Supported formats: .bgra8Unorm, .rgba32Float.
    public func captureScreenshot(from texture: MTLTexture) -> CGImage? {
        TextureCapture.captureScreenshot(device: device, commandQueue: commandQueue, texture: texture)
    }

    /// Saves a CGImage to file as PNG or JPEG.
    public func saveScreenshot(_ image: CGImage, to url: URL, format: ScreenshotFormat) -> Bool {
        TextureCapture.saveScreenshot(image, to: url, format: format)
    }

    /// Copies a CGImage to the general pasteboard.
    public func copyScreenshotToPasteboard(_ image: CGImage) {
        TextureCapture.copyScreenshotToPasteboard(image)
    }

    /// SC-021: Reads a single pixel at (x, y) from a bgra8Unorm texture. Call from background queue; completion can be used on main.
    public func samplePixel(from texture: MTLTexture, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        TextureCapture.samplePixel(device: device, commandQueue: commandQueue, texture: texture, x: x, y: y)
    }
}
