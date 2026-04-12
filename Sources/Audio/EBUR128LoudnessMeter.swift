import Foundation

/// EBU R128 loudness meter built on ITU-R BS.1770 (AU-006).
/// Outputs momentary (400 ms), short-term (3 s), and integrated (gated) loudness in LKFS.
///
/// - Momentary: 400 ms sliding window (from BS.1770).
/// - Short-term: 3 s sliding window (7.5 × 400 ms blocks).
/// - Integrated: gated loudness since reset; gate at -10 LU below ungated (EBU R128).
///
/// Call `process(from:)` on the meter thread; read LKFS properties from any thread for UI.
public final class EBUR128LoudnessMeter {
    /// LKFS offset (BS.1770): -0.691 dB.
    private static let lkfsOffset: Float = -0.691

    /// Gate relative to ungated integrated (EBU R128): -10 LU.
    private static let gateLUBelowUngated: Float = 10.0

    /// Short-term window: 3 s = 7.5 × 400 ms blocks.
    private static let shortTermBlockCount: Float = 7.5
    private static let shortTermRingSize: Int = 8

    private let bs1770: BS1770LoudnessMeter
    private let lock = NSLock()

    /// Ring of last 8 × 400 ms block mean_sq (newest at index 0).
    private var shortTermRing: [Float]
    private var shortTermRingCount: Int
    private var shortTermWriteIndex: Int

    /// All 400 ms block mean_sqs since reset (for integrated). Capped to avoid unbounded growth.
    private var integratedBlockMeanSqs: [Float]
    private let maxIntegratedBlocks: Int

    public init(
        channelCount: Int,
        sampleRate: Float,
        maxReadFrames: Int = 4096,
        maxIntegratedBlocks: Int = 9000
    ) {
        self.bs1770 = BS1770LoudnessMeter(
            channelCount: channelCount,
            sampleRate: sampleRate,
            momentaryBlockSeconds: 0.4,
            maxReadFrames: maxReadFrames
        )
        self.shortTermRing = [Float](repeating: 0, count: Self.shortTermRingSize)
        self.shortTermRingCount = 0
        self.shortTermWriteIndex = 0
        self.integratedBlockMeanSqs = []
        self.maxIntegratedBlocks = max(1, maxIntegratedBlocks)

        bs1770.on400msBlockComplete = { [weak self] meanSq in
            self?.pushBlockMeanSq(meanSq)
        }
    }

    private func pushBlockMeanSq(_ meanSq: Float) {
        lock.lock()
        // Short-term: ring of 8, newest at 0.
        shortTermRing[shortTermWriteIndex] = meanSq
        shortTermWriteIndex = (shortTermWriteIndex + 1) % Self.shortTermRingSize
        if shortTermRingCount < Self.shortTermRingSize {
            shortTermRingCount += 1
        }
        // Integrated: append (cap size).
        if integratedBlockMeanSqs.count >= maxIntegratedBlocks {
            integratedBlockMeanSqs.removeFirst()
        }
        integratedBlockMeanSqs.append(meanSq)
        lock.unlock()
    }

    /// Process available samples from the ring buffer. Call from the meter/consumer thread only.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        bs1770.process(from: ringBuffer)
    }

    /// Momentary loudness in LKFS (400 ms block). From BS.1770.
    public var momentaryLKFS: Float? {
        bs1770.momentaryLKFS
    }

    /// Short-term loudness in LKFS (3 s sliding window = 7.5 × 400 ms). Nil until at least one 400 ms block available.
    public var shortTermLKFS: Float? {
        lock.lock()
        defer { lock.unlock() }
        guard shortTermRingCount > 0 else { return nil }
        let sum = shortTermRing.reduce(0, +)
        let meanSq: Float
        if shortTermRingCount < Self.shortTermRingSize {
            meanSq = sum / Float(shortTermRingCount)
        } else {
            let oldest = shortTermRing[shortTermWriteIndex]
            meanSq = (sum - 0.5 * oldest) / Self.shortTermBlockCount
        }
        guard meanSq > 0 else { return nil }
        return Self.lkfsOffset + 10.0 * log10f(meanSq)
    }

    /// Integrated loudness in LKFS (gated, since reset). Nil until at least one 400 ms block; then gated per EBU R128 (-10 LU below ungated).
    public var integratedLKFS: Float? {
        lock.lock()
        defer { lock.unlock() }
        guard !integratedBlockMeanSqs.isEmpty else { return nil }
        let ungatedMeanSq = integratedBlockMeanSqs.reduce(0, +) / Float(integratedBlockMeanSqs.count)
        guard ungatedMeanSq > 0 else { return nil }
        let ungatedLKFS = Self.lkfsOffset + 10.0 * log10f(ungatedMeanSq)
        let gateLKFS = ungatedLKFS - Self.gateLUBelowUngated
        let gateMeanSq = pow(10.0, (gateLKFS - Self.lkfsOffset) / 10.0)
        let gated = integratedBlockMeanSqs.filter { $0 >= gateMeanSq }
        guard !gated.isEmpty else { return ungatedLKFS }
        let gatedMeanSq = gated.reduce(0, +) / Float(gated.count)
        guard gatedMeanSq > 0 else { return nil }
        return Self.lkfsOffset + 10.0 * log10f(gatedMeanSq)
    }

    /// Reset short-term ring and integrated history (e.g. new program). Also resets the underlying BS.1770 meter.
    public func reset() {
        lock.lock()
        shortTermRingCount = 0
        shortTermWriteIndex = 0
        integratedBlockMeanSqs.removeAll()
        lock.unlock()
        bs1770.reset()
    }
}
