import SwiftUI
import Audio
import Combine

/// State for audio meter UI (AU-008). Binds to AU-002 PeakLevelMeter and optionally AU-003 RMSLevelMeter.
/// Polls meters on a timer and publishes levels for AudioMeterView. When meters are nil, publishes zeros.
/// PERF-003: Timer only runs when meters are bound; equality checks prevent unnecessary @Published updates
/// that would cascade SwiftUI body re-evaluations across the entire MainView hierarchy.
public final class AudioMeterState: ObservableObject {
    @Published public var peakLevels: [Float] = [0, 0]
    @Published public var rmsLevels: [Float]?
    @Published public var showRMS: Bool = true
    /// AU-010: Lissajous (L,R) samples for phase scope. From PhaseCorrelationMeter.lissajousSamples when set.
    @Published public var lissajousLeft: [Float]?
    @Published public var lissajousRight: [Float]?

    private var peakMeter: PeakLevelMeter?
    private var rmsMeter: RMSLevelMeter?
    private var phaseCorrelationMeter: PhaseCorrelationMeter?
    private var timer: AnyCancellable?
    private let pollInterval: TimeInterval = 0.05

    public init() {
        // PERF-003: Don't start polling until meters are actually bound.
        // Previously started unconditionally, causing 20 SwiftUI redraws/sec even with no audio.
    }

    /// Bind AU-010 phase correlation meter for Lissajous display. Call when capture provides phase meter.
    public func setPhaseCorrelationMeter(_ meter: PhaseCorrelationMeter?) {
        phaseCorrelationMeter = meter
        if meter == nil {
            lissajousLeft = nil
            lissajousRight = nil
        }
        updateTimerState()
    }

    /// Bind AU-002 peak meter (and optionally AU-003 RMS). Call when capture provides audio pipeline with meters.
    public func setMeters(peak: PeakLevelMeter?, rms: RMSLevelMeter?) {
        peakMeter = peak
        rmsMeter = rms
        let channelCount = peak?.currentPeakLevels.count ?? rms?.currentRMSLevels.count ?? 2
        if peakLevels.count != channelCount {
            peakLevels = [Float](repeating: 0, count: channelCount)
        }
        if rms != nil {
            if rmsLevels == nil || (rmsLevels?.count ?? 0) != channelCount {
                rmsLevels = [Float](repeating: 0, count: channelCount)
            }
        } else {
            rmsLevels = nil
        }
        updateTimerState()
    }

    /// PERF-003: Start/stop polling timer based on whether any meters are bound.
    private func updateTimerState() {
        let hasMeters = peakMeter != nil || rmsMeter != nil || phaseCorrelationMeter != nil
        if hasMeters && timer == nil {
            startPolling()
        } else if !hasMeters && timer != nil {
            timer?.cancel()
            timer = nil
        }
    }

    private func startPolling() {
        timer = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.poll()
            }
    }

    private func poll() {
        // PERF-003: Only update @Published properties when values actually changed.
        // Each @Published set triggers objectWillChange → SwiftUI body re-evaluation of all
        // observing views (MainView, AudioMeterView, LissajousScopeView, etc.).
        if let peak = peakMeter {
            let newPeaks = peak.currentPeakLevels
            if newPeaks != peakLevels { peakLevels = newPeaks }
        }
        if let rms = rmsMeter {
            let newRMS = rms.currentRMSLevels
            if newRMS != rmsLevels { rmsLevels = newRMS }
        }
        if let phase = phaseCorrelationMeter {
            let samples = phase.lissajousSamples
            if samples.left != lissajousLeft { lissajousLeft = samples.left }
            if samples.right != lissajousRight { lissajousRight = samples.right }
        }
    }

    deinit {
        timer?.cancel()
    }
}
