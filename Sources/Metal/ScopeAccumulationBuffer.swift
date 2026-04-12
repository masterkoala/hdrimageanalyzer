// SC-001: Scope accumulation buffer — uint32 per pixel 2D grid for hit-count accumulation
// (Blender-style point rasterization). Used by waveform/vectorscope compute (SC-002).
// Create via MetalEngine.makeScopeAccumulationBuffer(width:height:). Reset before each frame;
// bind for compute; optionally resolve to texture for display.

import Foundation
import Metal
import Logging
import Common

/// Configurable 2D accumulation buffer (uint32 per pixel) for scope hit-count rasterization.
/// Layout: row-major, index = y * width + x. Byte size = width * height * 4.
public final class ScopeAccumulationBuffer {
    /// Grid width (e.g. waveform width or vectorscope diameter).
    public let width: Int
    /// Grid height (e.g. waveform height or vectorscope height).
    public let height: Int
    /// Metal buffer: width * height * MemoryLayout<UInt32>.stride bytes.
    public let buffer: MTLBuffer
    /// Total number of uint32 elements (width * height).
    public var elementCount: Int { width * height }

    private let device: MTLDevice
    private let logCategory = "ScopeAccumulation"

    /// Creates an accumulation buffer. Size is configurable (e.g. 2048×1024 for waveform).
    /// - Parameters:
    ///   - device: Metal device.
    ///   - width: Grid width (default 2048).
    ///   - height: Grid height (default 1024).
    public init?(device: MTLDevice, width: Int = 2048, height: Int = 1024) {
        let count = width * height
        let byteLength = count * MemoryLayout<UInt32>.stride
        guard count > 0, byteLength > 0,
              let buf = device.makeBuffer(length: byteLength, options: .storageModePrivate) else {
            return nil
        }
        self.device = device
        self.width = width
        self.height = height
        self.buffer = buf
        HDRLogger.info(category: logCategory, "ScopeAccumulationBuffer \(width)×\(height) (\(byteLength) bytes)")
    }

    /// Resets the buffer to zero. Call once per frame before accumulating.
    /// - Parameter commandBuffer: Command buffer to encode the fill into.
    public func reset(commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        blit.endEncoding()
    }

    /// PERF-002: Apply temporal decay (multiply all counts by decayFactor). Replaces reset() for temporal accumulation.
    /// - Parameters:
    ///   - commandBuffer: Command buffer to encode decay into.
    ///   - pipelineState: Compute pipeline for scope_accumulation_decay kernel.
    ///   - decayBuffer: Buffer containing a single Float with the decay factor (e.g. 0.90).
    public func decay(commandBuffer: MTLCommandBuffer, pipelineState: MTLComputePipelineState, decayBuffer: MTLBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipelineState)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBuffer(decayBuffer, offset: 0, index: 1)
        var count = UInt32(elementCount)
        enc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        let threadWidth = pipelineState.threadExecutionWidth
        let threadgroups = (elementCount + threadWidth - 1) / threadWidth
        enc.dispatchThreadgroups(MTLSize(width: threadgroups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// Binds this buffer for compute at the given index. Use before dispatching the point rasterizer.
    /// - Parameters:
    ///   - encoder: Compute command encoder.
    ///   - index: Buffer bind index (e.g. 0 for accumulation target).
    public func bindForCompute(encoder: MTLComputeCommandEncoder, at index: Int) {
        encoder.setBuffer(buffer, offset: 0, index: index)
    }

    /// Resolves accumulation counts to a displayable texture (normalized intensity).
    /// Output texture must be same width×height and format .r32Float or .rgba8Unorm (handled by kernel).
    /// - Parameters:
    ///   - encoder: Compute command encoder (already set with pipeline and params if needed).
    ///   - texture: Output texture (width×height); kernel writes normalized float.
    ///   - scale: Divisor for normalization (e.g. max expected count or 1 for passthrough).
    public func resolveToTexture(
        encoder: MTLComputeCommandEncoder,
        texture: MTLTexture,
        scale: Float = 255.0
    ) {
        guard texture.width == width && texture.height == height else {
            HDRLogger.error(category: "ScopeAccum", "resolveToTexture: texture size \(texture.width)×\(texture.height) must match buffer \(width)×\(height)")
            return
        }
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes([scale], length: MemoryLayout<Float>.stride, index: 1)
        encoder.setTexture(texture, index: 0)
        // Dispatch is caller's responsibility (pipeline and threadgroups from ComputeDispatch).
    }

    /// Readback accumulation data to CPU (for debugging only; use sparingly).
    /// Requires a shared-storage buffer copy; prefer resolveToTexture for display.
    /// - Parameter commandBuffer: Command buffer; will be committed and waited on.
    /// - Returns: Array of uint32 counts, or nil if copy buffer creation fails.
    public func readback(syncWith commandBuffer: MTLCommandBuffer) -> [UInt32]? {
        guard let copyBuffer = device.makeBuffer(length: buffer.length, options: .storageModeShared) else {
            return nil
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: buffer, sourceOffset: 0, to: copyBuffer, destinationOffset: 0, size: buffer.length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        let ptr = copyBuffer.contents().assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: ptr, count: elementCount))
    }
}
