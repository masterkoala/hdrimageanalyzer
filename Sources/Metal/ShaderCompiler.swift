import Foundation
import Metal
import Logging

/// Compiles Metal shaders from source code
public class ShaderCompiler {
    public let device: MTLDevice
    private let logCategory = "Metal.ShaderCompiler"

    /// Cache for compiled libraries
    private var compiledLibraries: [String: MTLLibrary] = [:]

    public init(device: MTLDevice) {
        self.device = device

        // Try to compile embedded shaders first
        compileEmbeddedLibrary()

        if CompiledShader.sources.isEmpty && compiledLibraries.isEmpty {
            HDRLogger.warning(category: logCategory, "No shaders could be compiled")
        }
    }

    /// Compile the minimal working shader library
    private func compileEmbeddedLibrary() {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {{
            float2 position [[attribute(0)]];
            float2 texCoord [[attribute(1)]];
        }};

        struct VertexOut {{
            float4 position [[position]];
            float2 texCoord;
        }};

        vertex VertexOut vertex_passthrough(
            constant VertexIn* vertices [[buffer(0)]],
            uint vid [[vertex_id]])
        {{
            VertexOut out;
            out.position = float4(vertices[vid].position, 0.0, 1.0);
            out.texCoord = vertices[vid].texCoord;

            // Flip vertically for correct image
            out.texCoord.y = 1.0 - out.texCoord.y;


        constexpr sampler samplersampler(address::clamp_to_edge,
                                         rgb_filter::linear,

        fragment float4 fragment_sample(
            texture2d<float> displayTexture [[texture(0)]],
            Sampler s {{sampler}},
            VertexOut in [[stage_in]])
        {{
            return displayTexture.sample(s, in.texCoord);
        }}

        // For debugging: show colored quadrants
        Fragment Out {
                    if (in.texCoord.x < 1.0/3) return {{R:


        public func library(for target: CompilationTarget) -> MTLLibrary? {
            guard let src = source(for: target),
                  let lib = try? compile(source: src, target: target)
            else {{
                HDRLogger.error(category: logCategory,
                               "Failed to compile shader for \(target)")
                return nil
        }

        compiledLibraries[target] = lib


    /// Compile single shader file

enum CompilationTarget {
    case minimal("Minimal Working"),
         conversionV210("V210 Conversion")),
         scopeAccumulation("Scope Accumulation"))



struct VertexIn {{
            float2 position [[attribute(0)]];
            uint instance [[instance_id]];
        }};

        return nil