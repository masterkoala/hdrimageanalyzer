import Foundation

/// Peak level meter with PPM-style ballistic response (attack/release).
/// Consumes samples from AU-001 AudioRingBuffer; outputs peak level per channel for UI.
///
/// Ballistics:
/// - **Attack:** Instant (peak follows signal up immediately; PPM-style).
/// - **Release:** Exponential decay with configurable time constant (default ~1.5 s).
///
/// Call `process(from:)` on the meter/consumer thread; read `currentPeakLevels` from any thread for UI.
public final class PeakLevelMeter {
    /// Default release time constant (seconds) for PPM-style fallback.
    public static let defaultReleaseTimeConstant: Float = 1.5

    private let channelCount: Int
    private let sampleRate: Float
    /// Release coefficient per sample: peak *= releaseCoeff when no new peak.
    private let releaseCoeffPerSample: Float
    private var peakPerChannel: [Float]
    private let lock = NSLock()
    /// Temporary buffer for reading from ring buffer (interleaved).
    private var readBuffer: [Float]
    private let maxReadFrames: Int

    /// - Parameters:
    ///   - channelCount: Must match the ring buffer (2, 8, or 16).
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    ///   - releaseTimeConstantSec: Time constant for exponential release in seconds (e.g. 1.5 for PPM).
    ///   - maxReadFrames: Maximum frames to read per process call (default 4096).
    public init(
        channelCount: Int,
        sampleRate: Float,
        releaseTimeConstantSec: Float = PeakLevelMeter.defaultReleaseTimeConstant,
        maxReadFrames: Int = 4096
    ) {
        precondition(channelCount > 0 && sampleRate > 0 && releaseTimeConstantSec > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.releaseCoeffPerSample = exp(-1 / (releaseTimeConstantSec * sampleRate))
        self.peakPerChannel = [Float](repeating: 0, count: channelCount)
        self.maxReadFrames = maxReadFrames
        self.readBuffer = [Float](repeating: 0, count: maxReadFrames * channelCount)
    }

    /// Process available samples from the ring buffer and update ballistic peak per channel.
    /// Call from the meter/consumer thread only (same thread that reads the ring buffer).
    /// - Parameter ringBuffer: AU-001 AudioRingBuffer to consume from.
    /// - Returns: Number of frames processed.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        let stride = ringBuffer.channels
        precondition(stride == channelCount, "PeakLevelMeter channelCount must match ring buffer")
        let toRead = min(ringBuffer.availableFrames, maxReadFrames)
        if toRead == 0 {
            applyReleaseOnly(frames: 256)
            return 0
        }
        let readCount = readBuffer.withUnsafeMutableBufferPointer { dest in
            ringBuffer.read(destination: dest.baseAddress!, maxFrames: toRead)
        }
        if readCount == 0 {
            applyReleaseOnly(frames: 256)
            return 0
        }
        var instantPeak = [Float](repeating: 0, count: channelCount)
        for f in 0..<readCount {
            for c in 0..<stride {
                let v = abs(readBuffer[f * stride + c])
                if v > instantPeak[c] { instantPeak[c] = v }
            }
        }
        let releaseCoeffBlock = pow(releaseCoeffPerSample, Float(readCount))
        lock.lock()
        for c in 0..<channelCount {
            let current = peakPerChannel[c]
            let next = max(instantPeak[c], current * releaseCoeffBlock)
            peakPerChannel[c] = next
        }
        lock.unlock()
        return readCount
    }

    /// Apply release only (no new input). Call when no frames were read to keep ballistics moving.
    private func applyReleaseOnly(frames: Int) {
        let r = pow(releaseCoeffPerSample, Float(frames))
        lock.lock()
        for c in 0..<channelCount {
            peakPerChannel[c] *= r
        }
        lock.unlock()
    }

    /// Current peak level per channel in linear scale [0, 1]. Safe to call from any thread (e.g. UI).
    public var currentPeakLevels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return peakPerChannel
    }

    /// Reset all channel peaks to zero.
    public func reset() {
        lock.lock()
        for i in 0..<channelCount { peakPerChannel[i] = 0 }
        lock.unlock()
    }
}
