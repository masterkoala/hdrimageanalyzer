import Foundation
import Atomics

/// Lock-free single-producer single-consumer ring buffer for audio samples from DeckLink (DL-010).
/// Producer: capture thread (audio callback). Consumer: meter/processing thread.
/// Supports 2, 8, or 16 channels; interleaved float samples in [-1, 1].
/// Capacity is in frames (one frame = channelCount samples).
public final class AudioRingBuffer {
    /// Allowed channel counts (2, 8, 16).
    public static let supportedChannelCounts: [Int] = [2, 8, 16]

    private let channelCount: Int
    private let capacityFrames: Int
    private var buffer: UnsafeMutableBufferPointer<Float>
    private let head: ManagedAtomic<Int>
    private let tail: ManagedAtomic<Int>

    /// - Parameters:
    ///   - channelCount: 2, 8, or 16.
    ///   - capacityFrames: Maximum number of frames to buffer (configurable).
    public init(channelCount: Int, capacityFrames: Int) {
        precondition(AudioRingBuffer.supportedChannelCounts.contains(channelCount), "channelCount must be 2, 8, or 16")
        precondition(capacityFrames > 0, "capacityFrames must be positive")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.buffer = UnsafeMutableBufferPointer.allocate(capacity: capacityFrames * channelCount)
        self.buffer.initialize(repeating: 0)
        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
    }

    deinit {
        buffer.deallocate()
    }

    /// Number of channels (2, 8, or 16).
    public var channels: Int { channelCount }

    /// Maximum number of frames that can be buffered.
    public var capacity: Int { capacityFrames }

    /// Number of frames currently available to read (approximate; single consumer).
    public var availableFrames: Int {
        let t = tail.load(ordering: .acquiring)
        let h = head.load(ordering: .acquiring)
        let n = (t - h + capacityFrames) % capacityFrames
        return n
    }

    /// Number of frames that can be written without overwriting unread data (approximate; single producer).
    public var writableFrames: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return capacityFrames - 1 - (t - h + capacityFrames) % capacityFrames
    }

    /// Producer: enqueue interleaved float samples. Call from capture thread only.
    /// - Returns: Number of frames actually written (may be less if buffer full).
    @discardableResult
    public func write(samples: UnsafePointer<Float>, frameCount: Int) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let used = (t - h + capacityFrames) % capacityFrames
        let free = capacityFrames - 1 - used
        let toWrite = min(frameCount, free)
        if toWrite == 0 { return 0 }
        let stride = channelCount
        let base = buffer.baseAddress!
        for i in 0..<toWrite {
            let slot = (t + i) % capacityFrames
            for c in 0..<stride {
                base[slot * stride + c] = samples[i * stride + c]
            }
        }
        tail.store((t + toWrite) % capacityFrames, ordering: .releasing)
        return toWrite
    }

    /// Consumer: dequeue up to maxFrames frames into destination. Call from meter/processing thread only.
    /// - Returns: Number of frames actually read.
    @discardableResult
    public func read(destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let t = tail.load(ordering: .acquiring)
        let h = head.load(ordering: .relaxed)
        let used = (t - h + capacityFrames) % capacityFrames
        let toRead = min(maxFrames, used)
        if toRead == 0 { return 0 }
        let stride = channelCount
        let base = buffer.baseAddress!
        for i in 0..<toRead {
            let slot = (h + i) % capacityFrames
            for c in 0..<stride {
                destination[i * stride + c] = base[slot * stride + c]
            }
        }
        head.store((h + toRead) % capacityFrames, ordering: .releasing)
        return toRead
    }

    /// Consumer: drop up to maxFrames frames without copying. Call from consumer thread only.
    /// - Returns: Number of frames dropped.
    @discardableResult
    public func discard(maxFrames: Int) -> Int {
        let t = tail.load(ordering: .acquiring)
        let h = head.load(ordering: .relaxed)
        let used = (t - h + capacityFrames) % capacityFrames
        let toDrop = min(maxFrames, used)
        if toDrop == 0 { return 0 }
        head.store((h + toDrop) % capacityFrames, ordering: .releasing)
        return toDrop
    }

    /// Clear all buffered frames (best-effort; producer may be writing concurrently).
    public func clear() {
        let t = tail.load(ordering: .acquiring)
        head.store(t, ordering: .releasing)
    }
}
