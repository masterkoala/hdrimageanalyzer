import Foundation

/// Phase correlation meter: L/R correlation (-1 to +1) and Lissajous (XY) data for UI.
/// Consumes stereo L/R (channels 0 and 1) from AU-001 AudioRingBuffer; computes Pearson
/// correlation over a sliding window and keeps recent L/R samples for Lissajous display.
///
/// Call `process(from:)` on the meter/consumer thread; read `currentCorrelation` and
/// `lissajousSamples` from any thread for UI (phase meter display, Lissajous scope).
public final class PhaseCorrelationMeter {
    /// Default correlation window duration in seconds (e.g. 300 ms).
    public static let defaultWindowSeconds: Float = 0.3
    /// Default number of (L,R) samples kept for Lissajous display.
    public static let defaultLissajousSamples: Int = 512

    private let channelCount: Int
    private let sampleRate: Float
    /// Window length in frames for correlation (one frame = one sample per channel).
    private let windowFrames: Int
    /// Number of (L,R) pairs to keep for Lissajous output.
    private let lissajousCapacity: Int

    /// Sliding-window state for L and R only (channels 0 and 1).
    private var sumL: Float
    private var sumR: Float
    private var sumL2: Float
    private var sumR2: Float
    private var sumLR: Float
    private var windowBufferL: [Float]
    private var windowBufferR: [Float]
    private var windowWriteIndex: Int
    private var windowFilled: Int

    /// Circular buffer of last LissajousCapacity (L,R) samples for UI.
    private var lissajousL: [Float]
    private var lissajousR: [Float]
    private var lissajousWriteIndex: Int

    private let lock = NSLock()
    private var readBuffer: [Float]
    private let maxReadFrames: Int

    /// - Parameters:
    ///   - channelCount: Must match the ring buffer (2, 8, or 16); L=channel 0, R=channel 1.
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    ///   - windowSeconds: Correlation window duration in seconds (e.g. 0.3 for 300 ms).
    ///   - lissajousSamples: Number of (L,R) pairs to keep for Lissajous display (default 512).
    ///   - maxReadFrames: Maximum frames to read per process call (default 4096).
    public init(
        channelCount: Int,
        sampleRate: Float,
        windowSeconds: Float = PhaseCorrelationMeter.defaultWindowSeconds,
        lissajousSamples: Int = PhaseCorrelationMeter.defaultLissajousSamples,
        maxReadFrames: Int = 4096
    ) {
        precondition(channelCount >= 2, "PhaseCorrelationMeter requires at least 2 channels (L/R)")
        precondition(sampleRate > 0 && windowSeconds > 0 && lissajousSamples > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.windowFrames = max(1, Int(sampleRate * windowSeconds))
        self.lissajousCapacity = min(max(1, lissajousSamples), 4096)
        self.sumL = 0
        self.sumR = 0
        self.sumL2 = 0
        self.sumR2 = 0
        self.sumLR = 0
        self.windowBufferL = [Float](repeating: 0, count: windowFrames)
        self.windowBufferR = [Float](repeating: 0, count: windowFrames)
        self.windowWriteIndex = 0
        self.windowFilled = 0
        self.lissajousL = [Float](repeating: 0, count: self.lissajousCapacity)
        self.lissajousR = [Float](repeating: 0, count: self.lissajousCapacity)
        self.lissajousWriteIndex = 0
        self.maxReadFrames = maxReadFrames
        self.readBuffer = [Float](repeating: 0, count: maxReadFrames * channelCount)
    }

    /// Correlation window duration in seconds.
    public var windowSeconds: Float {
        Float(windowFrames) / sampleRate
    }

    /// Process available samples from the ring buffer and update correlation and Lissajous buffers.
    /// Call from the meter/consumer thread only (same thread that reads the ring buffer).
    /// - Parameter ringBuffer: AU-001 AudioRingBuffer to consume from.
    /// - Returns: Number of frames processed.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        let stride = ringBuffer.channels
        precondition(stride == channelCount, "PhaseCorrelationMeter channelCount must match ring buffer")
        let toRead = min(ringBuffer.availableFrames, maxReadFrames)
        if toRead == 0 { return 0 }

        let readCount = readBuffer.withUnsafeMutableBufferPointer { dest in
            ringBuffer.read(destination: dest.baseAddress!, maxFrames: toRead)
        }
        if readCount == 0 { return 0 }

        lock.lock()
        for f in 0..<readCount {
            let l = readBuffer[f * stride + 0]
            let r = readBuffer[f * stride + 1]

            if windowFilled == windowFrames {
                let oldL = windowBufferL[windowWriteIndex]
                let oldR = windowBufferR[windowWriteIndex]
                sumL -= oldL
                sumR -= oldR
                sumL2 -= oldL * oldL
                sumR2 -= oldR * oldR
                sumLR -= oldL * oldR
            }
            windowBufferL[windowWriteIndex] = l
            windowBufferR[windowWriteIndex] = r
            sumL += l
            sumR += r
            sumL2 += l * l
            sumR2 += r * r
            sumLR += l * r
            windowWriteIndex = (windowWriteIndex + 1) % windowFrames
            if windowFilled < windowFrames {
                windowFilled += 1
            }

            lissajousL[lissajousWriteIndex] = l
            lissajousR[lissajousWriteIndex] = r
            lissajousWriteIndex = (lissajousWriteIndex + 1) % lissajousCapacity
        }
        lock.unlock()
        return readCount
    }

    /// Current L/R correlation in [-1, 1]. Safe to call from any thread (e.g. UI).
    /// +1 = in phase (mono-like), -1 = out of phase, 0 = uncorrelated.
    /// Returns 0 until the window has at least one sample.
    public var currentCorrelation: Float {
        lock.lock()
        defer { lock.unlock() }
        guard windowFilled > 0 else { return 0 }
        let n = Float(windowFilled)
        let denomL = n * sumL2 - sumL * sumL
        let denomR = n * sumR2 - sumR * sumR
        let denom = denomL * denomR
        guard denom > 0 else { return 0 }
        let num = n * sumLR - sumL * sumR
        let r = num / sqrt(denom)
        return max(-1, min(1, r))
    }

    /// Recent (L, R) samples for Lissajous/XY display. Safe to call from any thread.
    /// Returns (leftSamples, rightSamples) each of length lissajousCapacity, in chronological order
    /// (oldest at index 0, newest at end). UI can plot leftSamples[i] vs rightSamples[i].
    public var lissajousSamples: (left: [Float], right: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        var left = [Float](repeating: 0, count: lissajousCapacity)
        var right = [Float](repeating: 0, count: lissajousCapacity)
        for i in 0..<lissajousCapacity {
            let idx = (lissajousWriteIndex + i) % lissajousCapacity
            left[i] = lissajousL[idx]
            right[i] = lissajousR[idx]
        }
        return (left, right)
    }

    /// Reset correlation window and Lissajous buffers.
    public func reset() {
        lock.lock()
        sumL = 0
        sumR = 0
        sumL2 = 0
        sumR2 = 0
        sumLR = 0
        for i in 0..<windowFrames {
            windowBufferL[i] = 0
            windowBufferR[i] = 0
        }
        windowWriteIndex = 0
        windowFilled = 0
        for i in 0..<lissajousCapacity {
            lissajousL[i] = 0
            lissajousR[i] = 0
        }
        lissajousWriteIndex = 0
        lock.unlock()
    }
}
