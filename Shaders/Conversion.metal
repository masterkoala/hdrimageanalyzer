#include <metal_stdlib>
using namespace metal;

// Basic vertex shader for texture rendering
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

// Basic fragment shader for displaying textures
fragment float4 fragment_convert(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Sample the texture and return it as-is
    float4 color = inputTexture.sample(textureSampler, in.texCoord);
    return color;
}

// Placeholder for v210 to RGB conversion (will be implemented later)
fragment float4 fragment_convert_v210(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // For now, just pass through the input
    float4 color = inputTexture.sample(textureSampler, in.texCoord);
    return color;
}