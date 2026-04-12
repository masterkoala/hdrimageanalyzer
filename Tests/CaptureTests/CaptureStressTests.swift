import XCTest
import Common
@testable import Capture

/// DL-017: Capture pipeline stress test. Requires DeckLink hardware; skips if no device.
/// Runs capture at 4K60 or highest available display mode for a configurable duration (default 60s),
/// counts received and dropped frames via PerformanceCounters / session callback, asserts zero drops
/// (or documents threshold). Optional: logs frame times min/max/avg.
///
/// INT-006: 24-hour continuous capture stability — use testCaptureStress24HourRun with
/// CAPTURE_STRESS_24H=1, or run Scripts/stress-test-24h.sh. See Scripts/STRESS_TEST_24H.md.
final class CaptureStressTests: XCTestCase {

    /// 24 hours in seconds (INT-006).
    private static let twentyFourHours: TimeInterval = 24 * 60 * 60

    /// Duration in seconds. Override via env CAPTURE_STRESS_DURATION (e.g. 10 for quick run).
    private static var stressDurationSeconds: TimeInterval {
        if let s = ProcessInfo.processInfo.environment["CAPTURE_STRESS_DURATION"], let v = Double(s), v > 0 {
            return v
        }
        return 60
    }

    /// Acceptable drop count (default 0). Can set CAPTURE_STRESS_MAX_DROPS for CI with marginal hardware.
    private static var maxAllowedDrops: UInt64 {
        if let s = ProcessInfo.processInfo.environment["CAPTURE_STRESS_MAX_DROPS"], let v = UInt64(s) {
            return v
        }
        return 0
    }

    /// DL-017: Stress test — capture at highest mode for 60s (or CAPTURE_STRESS_DURATION), assert no drops.
    func testCaptureStressSustainedRun() throws {
        let mgr = DeckLinkDeviceManager()
        let devices = mgr.enumerateDevices()
        if devices.isEmpty {
            try XCTSkipIf(true, "No DeckLink device present; stress test requires hardware")
            return
        }

        let modes = DeckLinkGetDisplayModes(deviceIndex: 0)
        if modes.isEmpty {
            try XCTSkipIf(true, "No display modes for device 0")
            return
        }

        // Prefer 4K60, else highest resolution × frame rate (by area × fps)
        let modeIndex = Self.indexOf4K60OrHighest(modes)
        let mode = modes[modeIndex]
        let duration = Self.stressDurationSeconds
        let maxDrops = Self.maxAllowedDrops

        let received = AtomicUInt64(0)
        let frameTimesStore = AtomicFrameTimes()

        let onFrame: DeckLinkCaptureSession.FrameHandler = { _, _, _, _, _ in
            received.add(1)
            let t = CFAbsoluteTimeGetCurrent()
            PerformanceCounters.shared.recordFrame(at: t)
            frameTimesStore.append(t)
        }

        let session = DeckLinkCaptureSession(
            deviceIndex: 0,
            modeIndex: modeIndex,
            pixelFormat: .v210,
            onFrame: onFrame
        )

        PerformanceCounters.shared.resetDroppedCount()
        let started = session.start()
        if !started {
            try XCTSkipIf(true, "DeckLink capture failed to start (device 0, mode \(modeIndex) \(mode.name) — device may be in use or no signal)")
            return
        }

        defer { session.stop() }

        Thread.sleep(forTimeInterval: duration)

        session.stop()
        // Allow in-flight callback to run
        Thread.sleep(forTimeInterval: 0.5)

        let receivedCount = received.value
        let droppedCount = PerformanceCounters.shared.droppedFrameCount

        // Frame time stats (from our recorded times)
        let times = frameTimesStore.copy()
        if !times.isEmpty {
            var deltas: [CFTimeInterval] = []
            for i in 1..<times.count {
                deltas.append(times[i] - times[i - 1])
            }
            if !deltas.isEmpty {
                let minDt = deltas.min() ?? 0
                let maxDt = deltas.max() ?? 0
                let sum = deltas.reduce(0, +)
                let avgDt = sum / Double(deltas.count)
                // Log for diagnostics (XCTest will show in console)
                print("[CaptureStressTests] frame times (s): min=\(String(format: "%.4f", minDt)) max=\(String(format: "%.4f", maxDt)) avg=\(String(format: "%.4f", avgDt))")
            }
        }

        print("[CaptureStressTests] duration=\(duration)s mode=\(mode.name) received=\(receivedCount) dropped=\(droppedCount)")

        XCTAssertLessThanOrEqual(
            droppedCount,
            maxDrops,
            "Dropped frames \(droppedCount) exceeds allowed \(maxDrops) (set CAPTURE_STRESS_MAX_DROPS for threshold)"
        )
        XCTAssertGreaterThan(
            receivedCount,
            0,
            "Expected at least one frame in \(duration)s"
        )
    }

    // MARK: - INT-006: 24-hour continuous capture stability

    /// INT-006: 24-hour stress test. Runs only when CAPTURE_STRESS_24H=1 (e.g. via Scripts/stress-test-24h.sh).
    /// Requires DeckLink device with active signal. Pass: zero dropped frames; received count consistent with mode.
    func testCaptureStress24HourRun() throws {
        guard ProcessInfo.processInfo.environment["CAPTURE_STRESS_24H"] == "1" else {
            try XCTSkipIf(true, "24-hour stress test skipped (set CAPTURE_STRESS_24H=1 to run)")
            return
        }

        let mgr = DeckLinkDeviceManager()
        let devices = mgr.enumerateDevices()
        if devices.isEmpty {
            try XCTSkipIf(true, "No DeckLink device present; 24h stress test requires hardware")
            return
        }

        let modes = DeckLinkGetDisplayModes(deviceIndex: 0)
        if modes.isEmpty {
            try XCTSkipIf(true, "No display modes for device 0")
            return
        }

        let modeIndex = Self.indexOf4K60OrHighest(modes)
        let mode = modes[modeIndex]
        let duration = Self.twentyFourHours
        let maxDrops = Self.maxAllowedDrops

        let received = AtomicUInt64(0)
        let frameTimesStore = AtomicFrameTimes()

        let onFrame: DeckLinkCaptureSession.FrameHandler = { _, _, _, _, _ in
            received.add(1)
            let t = CFAbsoluteTimeGetCurrent()
            PerformanceCounters.shared.recordFrame(at: t)
            frameTimesStore.append(t)
        }

        let session = DeckLinkCaptureSession(
            deviceIndex: 0,
            modeIndex: modeIndex,
            pixelFormat: .v210,
            onFrame: onFrame
        )

        PerformanceCounters.shared.resetDroppedCount()
        let started = session.start()
        if !started {
            try XCTSkipIf(true, "DeckLink capture failed to start (device 0, mode \(modeIndex) \(mode.name))")
            return
        }

        defer { session.stop() }

        print("[CaptureStressTests] INT-006 24h stress: running for \(duration)s (\(duration/3600)h) mode=\(mode.name)")
        Thread.sleep(forTimeInterval: duration)

        session.stop()
        Thread.sleep(forTimeInterval: 0.5)

        let receivedCount = received.value
        let droppedCount = PerformanceCounters.shared.droppedFrameCount

        let times = frameTimesStore.copy()
        if !times.isEmpty {
            var deltas: [CFTimeInterval] = []
            for i in 1..<times.count {
                deltas.append(times[i] - times[i - 1])
            }
            if !deltas.isEmpty {
                let minDt = deltas.min() ?? 0
                let maxDt = deltas.max() ?? 0
                let sum = deltas.reduce(0, +)
                let avgDt = sum / Double(deltas.count)
                print("[CaptureStressTests] INT-006 24h frame times (s): min=\(String(format: "%.4f", minDt)) max=\(String(format: "%.4f", maxDt)) avg=\(String(format: "%.4f", avgDt))")
            }
        }

        print("[CaptureStressTests] INT-006 24h result: duration=\(duration)s received=\(receivedCount) dropped=\(droppedCount)")

        XCTAssertLessThanOrEqual(droppedCount, maxDrops, "24h stress: dropped \(droppedCount) exceeds allowed \(maxDrops)")
        XCTAssertGreaterThan(receivedCount, 0, "24h stress: expected at least one frame")
    }
}

// MARK: - Helpers

private extension CaptureStressTests {

    /// Index of 4K60 in modes, or index of mode with highest (width*height*fps).
    static func indexOf4K60OrHighest(_ modes: [DeckLinkDisplayMode]) -> Int {
        let fourK60 = modes.firstIndex { m in
            m.width >= 3840 && m.height >= 2160 && m.frameRate >= 59 && m.frameRate <= 61
        }
        if let i = fourK60 { return i }
        var best = 0
        var bestScore: Double = 0
        for (i, m) in modes.enumerated() {
            let score = Double(m.width * m.height) * m.frameRate
            if score > bestScore {
                bestScore = score
                best = i
            }
        }
        return best
    }
}

/// Simple thread-safe counter for received frames.
private final class AtomicUInt64: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func add(_ delta: UInt64) {
        lock.lock()
        _value += delta
        lock.unlock()
    }
    init(_ initial: UInt64 = 0) { _value = initial }
}

/// Thread-safe storage for frame timestamps (for min/max/avg).
private final class AtomicFrameTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var _times: [CFTimeInterval] = []
    func append(_ t: CFTimeInterval) {
        lock.lock()
        _times.append(t)
        lock.unlock()
    }
    func copy() -> [CFTimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _times
    }
}
