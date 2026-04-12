import Foundation

/// ITU-R BS.1770 loudness meter: K-weighting (high-shelf + high-pass for main channels,
/// high-pass only for LFE), sum of weighted channel powers, momentary loudness in LKFS.
/// Consumes samples from AU-001 AudioRingBuffer. Outputs momentary loudness over a 400 ms block.
///
/// Call `process(from:)` on the meter/consumer thread; read `momentaryLKFS` from any thread for UI.
public final class BS1770LoudnessMeter {
    /// Momentary loudness block duration in seconds (ITU-R BS.1770: 400 ms).
    public static let defaultMomentaryBlockSeconds: Float = 0.4

    /// Offset to convert mean square to LKFS (ITU-R BS.1770): -0.691 dB.
    private static let lkfsOffset: Float = -0.691

    private let channelCount: Int
    private let sampleRate: Float
    /// Block length in frames for momentary loudness (e.g. 400 ms).
    private let blockFrames: Int
    /// Channel index for LFE when present (8 or 16 ch: typically 3). -1 if no LFE (2 ch).
    private let lfeChannelIndex: Int
    /// Per-channel K-weighting filter state (biquads). Main channels: 2 stages (shelf + HP); LFE: 1 stage (HP).
    private var filterStates: [KWeightingFilterState]
    /// Sum of squared weighted samples over the current 400 ms block (single accumulator for all channels).
    private var sumSq: Float
    /// Number of frames currently in the block (0 .. blockFrames).
    private var blockFilled: Int
    /// Circular buffer of the last blockFrames * channelCount samples (after K-weighting) for sliding block.
    /// We store per-sample weighted values to subtract when sliding (or we recompute; here we keep a running sum and a ring of squared values).
    /// Simpler: keep a ring of (weighted sample)^2 per frame (sum over channels), and running sum; when we add a new frame we subtract the oldest frame's contribution.
    private var blockSumSqPerFrame: [Float]
    private var blockWriteIndex: Int
    /// Frames processed in current 400 ms block (for on400msBlockComplete).
    private var framesInBlockSinceEmit: Int
    private let lock = NSLock()
    private var readBuffer: [Float]
    private let maxReadFrames: Int

    /// Called every 400 ms with the completed block's mean square (for EBU R128 short-term/integrated).
    /// Invoked on the same thread as `process(from:)`.
    public var on400msBlockComplete: ((_ meanSq: Float) -> Void)?

    /// - Parameters:
    ///   - channelCount: Must match the ring buffer (2, 8, or 16). 2 = stereo (no LFE); 8/16 = LFE at index 3.
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    ///   - momentaryBlockSeconds: Momentary loudness block duration in seconds (default 0.4 = 400 ms).
    ///   - maxReadFrames: Maximum frames to read per process call (default 4096).
    public init(
        channelCount: Int,
        sampleRate: Float,
        momentaryBlockSeconds: Float = BS1770LoudnessMeter.defaultMomentaryBlockSeconds,
        maxReadFrames: Int = 4096
    ) {
        precondition(AudioRingBuffer.supportedChannelCounts.contains(channelCount), "channelCount must be 2, 8, or 16")
        precondition(sampleRate > 0 && momentaryBlockSeconds > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.blockFrames = max(1, Int(sampleRate * momentaryBlockSeconds))
        let lfeIdx = channelCount >= 8 ? 3 : -1
        self.lfeChannelIndex = lfeIdx
        self.filterStates = (0..<channelCount).map { ch in
            KWeightingFilterState(isLFE: ch == lfeIdx, sampleRate: sampleRate)
        }
        self.sumSq = 0
        self.blockFilled = 0
        self.blockSumSqPerFrame = [Float](repeating: 0, count: blockFrames)
        self.blockWriteIndex = 0
        self.framesInBlockSinceEmit = 0
        self.maxReadFrames = maxReadFrames
        self.readBuffer = [Float](repeating: 0, count: maxReadFrames * channelCount)
    }

    /// Momentary loudness block duration in seconds.
    public var momentaryBlockSeconds: Float {
        Float(blockFrames) / sampleRate
    }

    /// Process available samples from the ring buffer: apply K-weighting, accumulate sum of squares over 400 ms block, update momentary LKFS.
    /// Call from the meter/consumer thread only.
    /// - Parameter ringBuffer: AU-001 AudioRingBuffer to consume from.
    /// - Returns: Number of frames processed.
    @discardableResult
    public func process(from ringBuffer: AudioRingBuffer) -> Int {
        let stride = ringBuffer.channels
        precondition(stride == channelCount, "BS1770LoudnessMeter channelCount must match ring buffer")
        let toRead = min(ringBuffer.availableFrames, maxReadFrames)
        if toRead == 0 { return 0 }

        let readCount = readBuffer.withUnsafeMutableBufferPointer { dest in
            ringBuffer.read(destination: dest.baseAddress!, maxFrames: toRead)
        }
        if readCount == 0 { return 0 }

        lock.lock()
        for f in 0..<readCount {
            var frameSumSq: Float = 0
            for c in 0..<stride {
                let x = readBuffer[f * stride + c]
                var state = filterStates[c]
                let weighted = state.process(x)
                filterStates[c] = state
                // BS.1770 channel weights: all 1.0 (including LFE after its HP).
                frameSumSq += weighted * weighted
            }
            if blockFilled == blockFrames {
                sumSq -= blockSumSqPerFrame[blockWriteIndex]
            }
            blockSumSqPerFrame[blockWriteIndex] = frameSumSq
            sumSq += frameSumSq
            blockWriteIndex = (blockWriteIndex + 1) % blockFrames
            if blockFilled < blockFrames {
                blockFilled += 1
                if blockFilled == blockFrames {
                    // First complete block — emit immediately
                    let meanSq = sumSq / Float(blockFrames)
                    if meanSq > 0 {
                        on400msBlockComplete?(meanSq)
                    }
                    framesInBlockSinceEmit = 0
                }
            } else {
                framesInBlockSinceEmit += 1
                if framesInBlockSinceEmit >= blockFrames {
                    let meanSq = sumSq / Float(blockFrames)
                    if meanSq > 0 {
                        on400msBlockComplete?(meanSq)
                    }
                    framesInBlockSinceEmit = 0
                }
            }
        }
        lock.unlock()
        return readCount
    }

    /// Momentary loudness in LKFS (400 ms block). Returns nil if insufficient data (block not yet full); otherwise -inf to ~0 (full scale).
    /// Safe to call from any thread (e.g. UI).
    public var momentaryLKFS: Float? {
        lock.lock()
        defer { lock.unlock() }
        guard blockFilled == blockFrames, blockFrames > 0 else { return nil }
        let meanSq = sumSq / Float(blockFrames)
        guard meanSq > 0 else { return nil }
        let lkfs = BS1770LoudnessMeter.lkfsOffset + 10.0 * log10f(meanSq)
        return lkfs
    }

    /// Reset filter state and block accumulator (e.g. when starting a new program).
    public func reset() {
        lock.lock()
        for i in 0..<channelCount {
            filterStates[i].reset()
        }
        sumSq = 0
        for i in 0..<blockSumSqPerFrame.count { blockSumSqPerFrame[i] = 0 }
        blockWriteIndex = 0
        blockFilled = 0
        framesInBlockSinceEmit = 0
        lock.unlock()
    }
}

// MARK: - K-weighting filter (ITU-R BS.1770)

/// Per-channel K-weighting: main channels = high-shelf + high-pass; LFE = high-pass only.
/// Biquad direct form II transposed; coefficients at 48 kHz (scaled for other rates via same design).
private struct KWeightingFilterState {
    private var stage1: BiquadFilter
    private var stage2: BiquadFilter

    init(isLFE: Bool, sampleRate: Float) {
        if isLFE {
            // LFE: single high-pass at 20 Hz (BS.1770).
            stage1 = BiquadFilter(coefficients: BiquadFilter.lfeHighPass20Hz(sampleRate: sampleRate))
            stage2 = BiquadFilter.passthrough
        } else {
            // Main: stage 1 = high-shelf (~1681 Hz, +4 dB), stage 2 = high-pass ~38 Hz.
            stage1 = BiquadFilter(coefficients: BiquadFilter.kWeightingHighShelf(sampleRate: sampleRate))
            stage2 = BiquadFilter(coefficients: BiquadFilter.kWeightingHighPass38Hz(sampleRate: sampleRate))
        }
    }

    mutating func process(_ sample: Float) -> Float {
        let s1 = stage1.process(sample)
        return stage2.process(s1)
    }

    mutating func reset() {
        stage1.reset()
        stage2.reset()
    }
}

/// Second-order IIR (biquad) direct form II transposed.
private struct BiquadFilter {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float, x2: Float, y1: Float, y2: Float

    init(coefficients c: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)) {
        self.b0 = c.b0
        self.b1 = c.b1
        self.b2 = c.b2
        self.a1 = c.a1
        self.a2 = c.a2
        self.x1 = 0
        self.x2 = 0
        self.y1 = 0
        self.y2 = 0
    }

    static let passthrough = BiquadFilter(coefficients: (1, 0, 0, 0, 0))

    mutating func process(_ x0: Float) -> Float {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x0
        y2 = y1
        y1 = y0
        return y0
    }

    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }

    /// K-weighting stage 1: high-shelf, fc ≈ 1681 Hz, +4 dB at 48 kHz (ITU-R BS.1770).
    static func kWeightingHighShelf(sampleRate: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        if sampleRate == 48000 {
            return (1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
        }
        return designHighShelf(sampleRate: sampleRate, fc: 1681, gainDB: 4)
    }

    /// K-weighting stage 2: high-pass fc ≈ 38 Hz at 48 kHz.
    static func kWeightingHighPass38Hz(sampleRate: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        if sampleRate == 48000 {
            return (1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)
        }
        return designHighPass(sampleRate: sampleRate, fc: 38, q: 0.5)
    }

    /// LFE high-pass 20 Hz.
    static func lfeHighPass20Hz(sampleRate: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        if sampleRate == 48000 {
            return (1.0, -2.0, 1.0, -1.99444651641190, 0.99446679158222)
        }
        return designHighPass(sampleRate: sampleRate, fc: 20, q: 0.5)
    }

    /// Simple high-pass biquad (fc, Q); bilinear transform.
    private static func designHighPass(sampleRate: Float, fc: Int, q: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        let k = tan(Float.pi * Float(fc) / sampleRate)
        let k2 = k * k
        let qinv = 1.0 / q
        let norm = 1.0 / (1.0 + k * qinv + k2)
        let b0 = norm
        let b1 = -2 * norm
        let b2 = norm
        let a1 = 2 * (k2 - 1) * norm
        let a2 = (1 - k * qinv + k2) * norm
        return (b0, b1, b2, a1, a2)
    }

    /// High-shelf biquad (fc Hz, gainDB); simplified design.
    private static func designHighShelf(sampleRate: Float, fc: Int, gainDB: Float) -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        let k = tan(Float.pi * Float(fc) / sampleRate)
        let v = pow(10.0, abs(gainDB) / 20.0)
        let sqrtV = sqrt(v)
        let norm = 1.0 / (1.0 + sqrtV * k + k * k)
        let b0 = (1.0 + sqrtV * k + k * k) * norm
        let b1 = 2.0 * (k * k - 1.0) * norm
        let b2 = (1.0 - sqrtV * k + k * k) * norm
        let a1 = b1
        let a2 = (1.0 - sqrtV * k + k * k) * norm
        if gainDB >= 0 {
            return (b0, b1, b2, a1, a2)
        }
        return (norm, 2.0 * (k * k - 1.0) * norm, norm, 2.0 * (k * k - 1.0) * norm, (1.0 - sqrtV * k + k * k) * norm)
    }
}
