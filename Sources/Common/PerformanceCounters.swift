import Foundation

/// Frame times, GPU frame times, and dropped-frame counters (roadmap F-017, MT-010). Thread-safe; modules record then read.
public final class PerformanceCounters {
    public static let shared = PerformanceCounters()
    private let lock = NSLock()
    private var frameTimestamps: [CFTimeInterval] = []
    private var gpuFrameTimesSeconds: [Double] = []
    private let maxSamples = 120
    public private(set) var droppedFrameCount: UInt64 = 0

    private init() {}

    public func recordFrame(at time: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        frameTimestamps.append(time)
        if frameTimestamps.count > maxSamples { frameTimestamps.removeFirst() }
    }

    /// MT-010: Record GPU frame processing time (commit → completed, in seconds). Call from MTLCommandBuffer.addCompletedHandler.
    public func recordGPUFrameTime(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        gpuFrameTimesSeconds.append(seconds)
        if gpuFrameTimesSeconds.count > maxSamples { gpuFrameTimesSeconds.removeFirst() }
    }

    /// MT-010: Last N GPU frame times in seconds (same order as frameTimes).
    public func gpuFrameTimes() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return gpuFrameTimesSeconds
    }

    /// MT-010: Most recent GPU frame time in seconds, or nil if none recorded.
    public func lastGPUFrameTime() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return gpuFrameTimesSeconds.last
    }

    public func recordDroppedFrame() {
        lock.lock()
        defer { lock.unlock() }
        droppedFrameCount += 1
    }

    public func frameTimes() -> [CFTimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return frameTimestamps
    }

    public func resetDroppedCount() {
        lock.lock()
        defer { lock.unlock() }
        droppedFrameCount = 0
    }
}
