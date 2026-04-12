// MT-005: Compute shader dispatcher — threadgroup sizing from texture/buffer dimensions.
// Use for consistent dispatch across MasterPipeline and scope compute kernels.

import Foundation
import Metal

/// Helper to compute threadgroupsPerGrid and threadsPerThreadgroup for compute dispatch.
public enum ComputeDispatch {

    /// Returns (threadgroupsPerGrid, threadsPerThreadgroup) for a 2D texture so that
    /// the grid covers width×height pixels. Uses pipeline's threadExecutionWidth and
    /// maxTotalThreadsPerThreadgroup for optimal group size.
    public static func threadgroupsForTexture2D(
        width: Int,
        height: Int,
        pipeline: MTLComputePipelineState
    ) -> (grid: MTLSize, group: MTLSize) {
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        let group = MTLSize(width: w, height: max(1, h), depth: 1)
        let grid = MTLSize(
            width: (width + group.width - 1) / group.width,
            height: (height + group.height - 1) / group.height,
            depth: 1
        )
        return (grid, group)
    }

    /// Returns (threadgroupsPerGrid, threadsPerThreadgroup) for a 1D buffer of `count` elements.
    /// Use for row- or column-based compute (e.g. waveform column reduction).
    public static func threadgroupsForBuffer1D(
        count: Int,
        pipeline: MTLComputePipelineState
    ) -> (grid: MTLSize, group: MTLSize) {
        let w = pipeline.threadExecutionWidth
        let group = MTLSize(width: w, height: 1, depth: 1)
        let threadgroups = (count + group.width - 1) / group.width
        let grid = MTLSize(width: threadgroups, height: 1, depth: 1)
        return (grid, group)
    }

    /// Returns (threadgroupsPerGrid, threadsPerThreadgroup) for a 2D dispatch with custom
    /// group width/height (e.g. when kernel expects a fixed layout).
    public static func threadgroupsFor2D(
        width: Int,
        height: Int,
        groupWidth: Int,
        groupHeight: Int
    ) -> (grid: MTLSize, group: MTLSize) {
        let group = MTLSize(width: groupWidth, height: groupHeight, depth: 1)
        let grid = MTLSize(
            width: (width + groupWidth - 1) / groupWidth,
            height: (height + groupHeight - 1) / groupHeight,
            depth: 1
        )
        return (grid, group)
    }
}
