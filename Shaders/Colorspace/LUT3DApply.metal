// CS-012: GPU 3D LUT application — trilinear interpolation.
// CS-013: Tetrahedral interpolation option (highest quality).
// CS-015: Format conversion for Display/Scope LUT pipeline (bgra8 ↔ float).
// Compute kernel: input RGB → LUT coords → sample → output.

#include <metal_stdlib>
using namespace metal;

// CS-015: Copy/normalize from bgra8Unorm (bound as texture2d<float,read> → normalized) to rgba32Float for LUT input.
kernel void bgra8_to_float(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    outTexture.write(c, gid);
}

// CS-015: Clamp float [0,1] and write to bgra8Unorm output (bound as texture2d<float,write>; driver converts).
kernel void float_to_bgra8(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
    float4 c = inTexture.read(gid);
    c = float4(saturate(c.r), saturate(c.g), saturate(c.b), saturate(c.a));
    outTexture.write(c, gid);
}

/// Sampler for 3D LUT: linear filtering (trilinear), clamp to edge.
constant constexpr sampler lutSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

/// Apply 3D LUT to input image. Input and output are 2D RGBA textures (float).
/// LUT is a 3D texture (size×size×size) from CubeLUT; R=inner, G=middle, B=outer.
/// Maps input RGB [0,1] to LUT coordinates with voxel-center correction for accurate trilinear interpolation.
kernel void apply_3d_lut(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture3d<float, access::sample> lutTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height())
        return;

    float4 rgba = inTexture.read(gid);
    float r = rgba.r;
    float g = rgba.g;
    float b = rgba.b;

    // LUT dimensions (assume cube: width = height = depth)
    uint lutSize = lutTexture.get_width();
    if (lutSize == 0) {
        outTexture.write(rgba, gid);
        return;
    }

    // Map input [0,1] to normalized LUT coords so that 0 and 1 hit voxel centers (standard .cube behavior).
    // coord = (rgb * (N-1) + 0.5) / N
    float n = float(lutSize);
    float3 coord;
    coord.x = (r * (n - 1.0f) + 0.5f) / n;
    coord.y = (g * (n - 1.0f) + 0.5f) / n;
    coord.z = (b * (n - 1.0f) + 0.5f) / n;

    float4 outRgba = lutTexture.sample(lutSampler, coord);
    outRgba.a = rgba.a;  // Preserve input alpha
    outTexture.write(outRgba, gid);
}

// CS-013: Tetrahedral interpolation — 4 samples per pixel, 6 tetrahedra per cell. Highest quality LUT option.
// LUT must have access::read for integer lattice reads. Input RGB [0,1] → continuous 0..N-1 → floor to (nR,nG,nB), frac (fR,fG,fB).
// Select one of 6 tetrahedra by ordering of (fR,fG,fB); interpolate 4 corners with barycentric weights.
kernel void apply_3d_lut_tetrahedral(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture3d<float, access::read> lutTexture [[texture(1)]],
    texture2d<float, access::write> outTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height())
        return;

    float4 rgba = inTexture.read(gid);
    float r = rgba.r;
    float g = rgba.g;
    float b = rgba.b;

    uint lutSize = lutTexture.get_width();
    if (lutSize == 0 || lutSize < 2) {
        outTexture.write(rgba, gid);
        return;
    }

    float n = float(lutSize);
    float scale = (n - 1.0f);
    // Continuous position in [0, N-1]; clamp to avoid out-of-bounds
    float cr = clamp(r * scale, 0.0f, scale);
    float cg = clamp(g * scale, 0.0f, scale);
    float cb = clamp(b * scale, 0.0f, scale);

    uint nR = uint(cr);
    uint nG = uint(cg);
    uint nB = uint(cb);
    uint nR1 = min(nR + 1, lutSize - 1);
    uint nG1 = min(nG + 1, lutSize - 1);
    uint nB1 = min(nB + 1, lutSize - 1);

    float fR = cr - float(nR);
    float fG = cg - float(nG);
    float fB = cb - float(nB);

    // Sample 8 cell corners (4 used per tetrahedron).
    float4 c000 = lutTexture.read(uint3(nR, nG, nB));
    float4 c100 = lutTexture.read(uint3(nR1, nG, nB));
    float4 c010 = lutTexture.read(uint3(nR, nG1, nB));
    float4 c001 = lutTexture.read(uint3(nR, nG, nB1));
    float4 c110 = lutTexture.read(uint3(nR1, nG1, nB));
    float4 c101 = lutTexture.read(uint3(nR1, nG, nB1));
    float4 c011 = lutTexture.read(uint3(nR, nG1, nB1));
    float4 c111 = lutTexture.read(uint3(nR1, nG1, nB1));

    float4 outRgba;
    if (fG >= fB && fB >= fR) {
        // T1: (1-fG)*c000 + (fG-fB)*c010 + (fB-fR)*c011 + fR*c111
        outRgba = (1.0f - fG) * c000 + (fG - fB) * c010 + (fB - fR) * c011 + fR * c111;
    } else if (fB > fR && fR > fG) {
        // T2: (1-fB)*c000 + (fB-fR)*c001 + (fR-fG)*c101 + fG*c111
        outRgba = (1.0f - fB) * c000 + (fB - fR) * c001 + (fR - fG) * c101 + fG * c111;
    } else if (fB > fG && fG >= fR) {
        // T3: (1-fB)*c000 + (fB-fG)*c001 + (fG-fR)*c011 + fR*c111
        outRgba = (1.0f - fB) * c000 + (fB - fG) * c001 + (fG - fR) * c011 + fR * c111;
    } else if (fR >= fG && fG > fB) {
        // T4: (1-fR)*c000 + (fR-fG)*c100 + (fG-fB)*c110 + fB*c111
        outRgba = (1.0f - fR) * c000 + (fR - fG) * c100 + (fG - fB) * c110 + fB * c111;
    } else if (fG > fR && fR >= fB) {
        // T5: (1-fG)*c000 + (fG-fR)*c010 + (fR-fB)*c110 + fB*c111
        outRgba = (1.0f - fG) * c000 + (fG - fR) * c010 + (fR - fB) * c110 + fB * c111;
    } else {
        // T6: fR >= fB >= fG: (1-fR)*c000 + (fR-fB)*c100 + (fB-fG)*c101 + fG*c111
        outRgba = (1.0f - fR) * c000 + (fR - fB) * c100 + (fB - fG) * c101 + fG * c111;
    }

    outRgba.a = rgba.a;
    outTexture.write(outRgba, gid);
}
