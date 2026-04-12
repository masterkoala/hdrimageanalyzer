#include <metal_stdlib>
using namespace metal;

// v210 format is a 10-bit YUV packed format
// Each 32-bit word contains 10 bits of U, 10 bits of Y0, 10 bits of Y1, and 2 bits of V
// This shader converts v210 to RGB

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_convert(
    constant VertexIn* vertices [[buffer(0)]],
    uint vid [[vertex_id]])
{
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;

    // Flip vertically
    out.texCoord.y = 1.0 - out.texCoord.y;
    return out;
}

// Convert v210 to RGB
fragment float4 fragment_convert_v210(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant float3* colorMatrix [[buffer(0)]]
) {
    // Sample the texture
    float4 color = inputTexture.sample(textureSampler, in.texCoord);

    // For now just return the sampled color - actual v210 conversion would go here
    return color;
}

// Placeholder fragment shader for fallback
fragment float4 fragment_convert_placeholder(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Sample the texture and return it as-is
    float4 color = inputTexture.sample(textureSampler, in.texCoord);
    return color;
}