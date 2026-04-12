import Foundation

/// True peak detector with 4× oversampling per ITU-R BS.1770-4 to capture inter-sample peaks.
/// Consumes samples from AU-001 AudioRingBuffer; outputs true peak per channel (linear scale).
///
/// Algorithm: for each channel, oversample by 4× using cubic (Catmull-Rom) interpolation
/// between consecutive samples, then take the maximum absolute value over the block.
/// Call `process(from:)` on the meter/consumer thread; read `currentTruePeakLevels` from any thread.
public final class TruePeakDetector {
    /// Oversampling factor per BS.1770-4 (at least 4×).
    public static let oversamplingFactor: Int = 4

    private let channelCount: Int
    /// Temporary buffer for reading from ring buffer (interleaved).
    private var readBuffer: [Float]
    private let maxReadFrames: Int
    private var truePeakPerChannel: [Float]
    private let lock = NSLock()

    /// - Parameters:
    ///   - channelCount: Must match the ring buffer (2, 8, or 16).
    ///   - maxReadFrames: Maximum frames to read per process call (default 4096).
    public init(channelCount: Int, maxReadFrames: Int = 4096) {
        precondition(channelCount > 0 && maxReadFrames > 0)
        self.channelCount = channelCount
        self.maxReadFrames = maxReadFrames
        self.readBuffer = [Float](repeating: 0, count: maxReadFrames * channelCount)
        self.truePeakPerChannel = [Float](repeating: 0, count: channelCount)
    }

    /// Cubic Catmull-Rom interpolation: y(t) for t in [0,1] between p1 and p2, with p0 and p3 for tangents.
    private static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    /// Process available samples from the ring buffer and update true peak per channel (4× oversampled).
    /// Call from the meter/consumer thread only.
    /// - Parameter ringBuffer: AU-001 AudioRingBuffer to consume from.
    /// - Returns: Number of frames processed.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        let stride = ringBuffer.channels
        precondition(stride == channelCount, "TruePeakDetector channelCount must match ring buffer")
        let toRead = min(ringBuffer.availableFrames, maxReadFrames)
        if toRead == 0 { return 0 }

        let readCount = readBuffer.withUnsafeMutableBufferPointer { dest in
            ringBuffer.read(destination: dest.baseAddress!, maxFrames: toRead)
        }
        if readCount == 0 { return 0 }

        var blockTruePeak = [Float](repeating: 0, count: channelCount)
        for c in 0..<stride {
            var peak: Float = 0
            for f in 0..<readCount {
                let idx = f * stride + c
                let s0 = readBuffer[idx]
                let s1 = (f + 1 < readCount) ? readBuffer[idx + stride] : s0
                let sPrev = (f > 0) ? readBuffer[idx - stride] : s0
                let sNext = (f + 2 < readCount) ? readBuffer[idx + 2 * stride] : s1

                let v0 = abs(s0)
                if v0 > peak { peak = v0 }
                for k in 1..<TruePeakDetector.oversamplingFactor {
                    let t = Float(k) / Float(TruePeakDetector.oversamplingFactor)
                    let interp = TruePeakDetector.catmullRom(sPrev, s0, s1, sNext, t)
                    let v = abs(interp)
                    if v > peak { peak = v }
                }
                if f == readCount - 1 {
                    let v1 = abs(s1)
                    if v1 > peak { peak = v1 }
                }
            }
            blockTruePeak[c] = peak
        }

        lock.lock()
        for c in 0..<channelCount {
            if blockTruePeak[c] > truePeakPerChannel[c] {
                truePeakPerChannel[c] = blockTruePeak[c]
            }
        }
        lock.unlock()
        return readCount
    }

    /// Current true peak per channel in linear scale (may exceed 1.0). Safe to call from any thread (e.g. UI).
    public var currentTruePeakLevels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return truePeakPerChannel
    }

    /// Reset all channel true peaks to zero.
    public func reset() {
        lock.lock()
        for i in 0..<channelCount { truePeakPerChannel[i] = 0 }
        lock.unlock()
    }
}
