import XCTest
import Common
@testable import MetalEngine

final class MetalEngineTests: XCTestCase {

    func testMetalEngineSharedExists() {
        guard let engine = MetalEngine.shared else {
            XCTFail("MetalEngine.shared nil (no Metal device)")
            return
        }
        XCTAssertNotNil(engine.device)
        XCTAssertNotNil(engine.commandQueue)
    }

    /// INT-005: GPU audit smoke — one frame through pipeline; verifies no GPU error and pipeline is ready for Metal System Trace profiling. See Docs/GPU_Performance_Audit_Metal_System_Trace.md.
    func testGPUAuditSmokeOneFrame() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device — skip GPU audit smoke")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed — skip GPU audit smoke")
        }
        let width = 3840
        let height = 2160
        let rowBytes = width * 4
        let bufferLength = rowBytes * height
        guard let buffer = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            XCTFail("Failed to allocate frame buffer for GPU audit smoke")
            return
        }
        memset(buffer.contents(), 0, bufferLength)
        pipeline.submitFrame(bytes: buffer.contents(), rowBytes: rowBytes, width: width, height: height, pixelFormat: 0)
        let outTexture = pipeline.processFrame()
        XCTAssertNotNil(outTexture, "processFrame() should return non-nil texture (INT-005 GPU audit smoke)")
    }

    /// MT-015: Benchmark total GPU frame time at 4K (3840×2160). Runs 10s of synthetic frames, uses PerformanceCounters.gpuFrameTimes(), reports min/max/avg/percentile. Goal: document <16ms (60fps) budget. Skips when no Metal device.
    func testGPUFrameTimeBenchmark4K60() throws {
        guard let engine = MetalEngine.shared else {
            throw XCTSkip("No Metal device — skip GPU benchmark")
        }
        guard let pipeline = MasterPipeline(engine: engine) else {
            throw XCTSkip("MasterPipeline init failed — skip GPU benchmark")
        }

        let width = 3840
        let height = 2160
        let rowBytes = width * 4
        let bufferLength = rowBytes * height
        guard let buffer = engine.device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            XCTFail("Failed to allocate 4K frame buffer")
            return
        }
        // Zero-fill so placeholder path reads deterministic data.
        memset(buffer.contents(), 0, bufferLength)

        let runSeconds = 10.0
        let deadline = CFAbsoluteTimeGetCurrent() + runSeconds
        var frameCount = 0
        while CFAbsoluteTimeGetCurrent() < deadline {
            pipeline.submitFrame(bytes: buffer.contents(), rowBytes: rowBytes, width: width, height: height, pixelFormat: 0)
            _ = pipeline.processFrame()
            frameCount += 1
        }

        let gpuTimesSeconds = PerformanceCounters.shared.gpuFrameTimes()
        if gpuTimesSeconds.isEmpty {
            XCTFail("No GPU frame times recorded (run: \(runSeconds)s, frames: \(frameCount))")
            return
        }

        let sorted = gpuTimesSeconds.sorted()
        let minSec = sorted.first!
        let maxSec = sorted.last!
        let sum = sorted.reduce(0, +)
        let avgSec = sum / Double(sorted.count)
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        let p99 = percentile(sorted, 0.99)
        let budget60fpsSec = 1.0 / 60.0  // 16.67ms

        // Report (and document 60fps budget)
        let ms: (Double) -> Double = { $0 * 1000 }
        print("MT-015 GPU frame time benchmark (4K \(width)×\(height), \(runSeconds)s, \(frameCount) frames, \(sorted.count) samples)")
        print("  min: \(String(format: "%.3f", ms(minSec))) ms, max: \(String(format: "%.3f", ms(maxSec))) ms, avg: \(String(format: "%.3f", ms(avgSec))) ms")
        print("  p50: \(String(format: "%.3f", ms(p50))) ms, p95: \(String(format: "%.3f", ms(p95))) ms, p99: \(String(format: "%.3f", ms(p99))) ms")
        print("  60fps budget: \(String(format: "%.3f", ms(budget60fpsSec))) ms — meets budget: \(avgSec <= budget60fpsSec)")

        // Document result: assert we meet <16ms (60fps) budget for average (optional soft assertion)
        XCTAssertLessThanOrEqual(avgSec, budget60fpsSec, "Average GPU frame time \(String(format: "%.3f", ms(avgSec))) ms exceeds 60fps budget \(String(format: "%.3f", ms(budget60fpsSec))) ms")
    }
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Swift.min(sorted.count - 1, Swift.max(0, Int(Double(sorted.count) * p)))
    return sorted[index]
}
