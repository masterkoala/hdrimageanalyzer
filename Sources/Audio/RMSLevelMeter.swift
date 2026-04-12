import Foundation

/// RMS level meter over a configurable sliding window.
/// Consumes samples from AU-001 AudioRingBuffer; computes RMS per channel over the window (e.g. 300 ms).
/// Outputs RMS values for UI (linear scale [0, 1]).
///
/// Call `process(from:)` on the meter/consumer thread; read `currentRMSLevels` from any thread for UI.
public final class RMSLevelMeter {
    /// Default window duration in seconds (e.g. 300 ms).
    public static let defaultWindowSeconds: Float = 0.3

    private let channelCount: Int
    private let sampleRate: Float
    /// Window length in frames (one frame = one sample per channel).
    private let windowFrames: Int
    /// Per-channel sum of squares over the current window (for sliding RMS).
    private var sumSqPerChannel: [Float]
    /// Circular buffer of the last windowFrames frames (interleaved) for sliding window.
    private var windowBuffer: [Float]
    private var windowWriteIndex: Int
    /// Number of frames currently in the window (until full, then always windowFrames).
    private var windowFilled: Int
    private let lock = NSLock()
    /// Temporary buffer for reading from ring buffer (interleaved).
    private var readBuffer: [Float]
    private let maxReadFrames: Int

    /// - Parameters:
    ///   - channelCount: Must match the ring buffer (2, 8, or 16).
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    ///   - windowSeconds: RMS window duration in seconds (e.g. 0.3 for 300 ms).
    ///   - maxReadFrames: Maximum frames to read per process call (default 4096).
    public init(
        channelCount: Int,
        sampleRate: Float,
        windowSeconds: Float = RMSLevelMeter.defaultWindowSeconds,
        maxReadFrames: Int = 4096
    ) {
        precondition(channelCount > 0 && sampleRate > 0 && windowSeconds > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.windowFrames = max(1, Int(sampleRate * windowSeconds))
        self.sumSqPerChannel = [Float](repeating: 0, count: channelCount)
        self.windowBuffer = [Float](repeating: 0, count: self.windowFrames * channelCount)
        self.windowWriteIndex = 0
        self.windowFilled = 0
        self.maxReadFrames = maxReadFrames
        self.readBuffer = [Float](repeating: 0, count: maxReadFrames * channelCount)
    }

    /// RMS window duration in seconds.
    public var windowSeconds: Float {
        Float(windowFrames) / sampleRate
    }

    /// Process available samples from the ring buffer and update RMS per channel.
    /// Call from the meter/consumer thread only (same thread that reads the ring buffer).
    /// - Parameter ringBuffer: AU-001 AudioRingBuffer to consume from.
    /// - Returns: Number of frames processed.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        let stride = ringBuffer.channels
        precondition(stride == channelCount, "RMSLevelMeter channelCount must match ring buffer")
        let toRead = min(ringBuffer.availableFrames, maxReadFrames)
        if toRead == 0 { return 0 }

        let readCount = readBuffer.withUnsafeMutableBufferPointer { dest in
            ringBuffer.read(destination: dest.baseAddress!, maxFrames: toRead)
        }
        if readCount == 0 { return 0 }

        lock.lock()
        for f in 0..<readCount {
            for c in 0..<stride {
                let x = readBuffer[f * stride + c]
                let slot = windowWriteIndex * stride + c
                if windowFilled == windowFrames {
                    let oldVal = windowBuffer[slot]
                    sumSqPerChannel[c] -= oldVal * oldVal
                }
                windowBuffer[slot] = x
                sumSqPerChannel[c] += x * x
            }
            windowWriteIndex = (windowWriteIndex + 1) % windowFrames
            if windowFilled < windowFrames {
                windowFilled += 1
            }
        }
        lock.unlock()
        return readCount
    }

    /// Current RMS level per channel in linear scale [0, 1]. Safe to call from any thread (e.g. UI).
    /// Returns zero for each channel until at least one sample has been processed in the window.
    public var currentRMSLevels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = windowFilled > 0 ? Float(windowFilled) : 1
        return sumSqPerChannel.map { sqrt(max(0, $0) / n) }
    }

    /// Reset window state (all sums and buffer to zero).
    public func reset() {
        lock.lock()
        for i in 0..<channelCount { sumSqPerChannel[i] = 0 }
        for i in 0..<windowBuffer.count { windowBuffer[i] = 0 }
        windowWriteIndex = 0
        windowFilled = 0
        lock.unlock()
    }
}
