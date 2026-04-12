// MT-006: Shared shader types — layout must match Sources/Metal/ShaderTypes.swift for CPU/GPU.
// Used by convert_v210_to_rgb and future kernels (frame params, etc.).

#ifndef SHADERTYPES_METAL
#define SHADERTYPES_METAL

#include <metal_stdlib>
using namespace metal;

/// v210 decode params: width/height in pixels, rowBytes for buffer stride.
struct V210Params {
    uint width;
    uint height;
    uint rowBytes;
};

/// SC-003: Phosphor resolve — gamma and gain for non-linear tone mapping (pow(normalized, gamma) * gain).
struct ScopeResolveParams {
    float gamma;
    float gain;
};

/// General frame params for future use (format, dimensions, flags).
struct FrameParams {
    uint width;
    uint height;
    uint pixelFormat;  // FourCC / format id
    uint rowBytes;
};

#endif
