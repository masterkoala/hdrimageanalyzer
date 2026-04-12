// QC-009: Timed screenshot capture (every N seconds/frames). Depends on QC-008 (exportDisplayScreenshotToPNG).

import Foundation

/// Mode for QC-009 timed screenshot capture.
public enum TimedScreenshotMode {
    /// Capture every N seconds (Timer-based).
    case timeBased(intervalSeconds: TimeInterval)
    /// Capture every N frames (caller invokes tickFrame() each frame).
    case frameBased(intervalFrames: Int)
}

/// QC-009: Drives periodic screenshot capture using a caller-provided export block (e.g. pipeline.exportDisplayScreenshotToPNG).
/// Supports time-based (every N seconds) and frame-based (every N frames) capture.
public final class TimedScreenshotCapture {
    public static let logCategory = "QC.TimedScreenshot"

    /// Use a private queue to avoid deadlock: tickFrame() is called from the main thread (Metal display link).
    /// Dispatching main.sync from main thread causes deadlock/EXC_BREAKPOINT.
    private let queue = DispatchQueue(label: "com.hdranalyzer.timed-screenshot")
    private var timer: Timer?
    private var frameCount: Int = 0
    private var captureCount: Int = 0

    private var _mode: TimedScreenshotMode = .timeBased(intervalSeconds: 5)
    private var _outputDirectory: URL?
    private var _filenamePrefix: String = "screenshot"
    private var _captureBlock: ((URL) -> Bool)?
    private var _isRunning: Bool = false

    public init() {}

    /// Current mode (time- or frame-based).
    public var mode: TimedScreenshotMode {
        get { queue.sync { _mode } }
        set { queue.async { [weak self] in self?._mode = newValue } }
    }

    /// Output directory for PNG files. Must be set before start (e.g. via start(mode:outputDirectory:filenamePrefix:captureBlock:)).
    public var outputDirectory: URL? {
        get { queue.sync { _outputDirectory } }
        set { queue.async { [weak self] in self?._outputDirectory = newValue } }
    }

    /// Filename prefix (e.g. "screenshot" → screenshot_20260226123045.png).
    public var filenamePrefix: String {
        get { queue.sync { _filenamePrefix } }
        set { queue.async { [weak self] in self?._filenamePrefix = newValue } }
    }

    /// Whether capture is currently active.
    public var isRunning: Bool {
        queue.sync { _isRunning }
    }

    /// Start timed capture. Uses the given block to export a screenshot to the generated URL (e.g. pipeline.exportDisplayScreenshotToPNG(to:)).
    /// For time-based mode, a timer fires every N seconds on the main queue. For frame-based mode, call tickFrame() from your render loop.
    public func start(
        mode: TimedScreenshotMode,
        outputDirectory: URL,
        filenamePrefix: String = "screenshot",
        captureBlock: @escaping (URL) -> Bool
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stop()
            self._mode = mode
            self._outputDirectory = outputDirectory
            self._filenamePrefix = filenamePrefix
            self._captureBlock = captureBlock
            self._isRunning = true
            self.frameCount = 0
            self.captureCount = 0

            switch mode {
            case .timeBased(intervalSeconds: let interval):
                self.scheduleTimer(interval: interval)
            case .frameBased:
                break
            }
            HDRLogger.info(category: Self.logCategory, "timed screenshot capture started mode=\(mode) outputDir=\(outputDirectory.path)")
        }
    }

    /// Stop timed capture (stops timer and frame-based counting).
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.invalidate()
            self.timer = nil
            if self._isRunning {
                HDRLogger.info(category: Self.logCategory, "timed screenshot capture stopped captures=\(self.captureCount)")
            }
            self._isRunning = false
            self._captureBlock = nil
        }
    }

    /// Call once per frame when using frame-based mode. Async (does not block draw loop) to avoid freezing; return value is always false.
    public func tickFrame() -> Bool {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self._isRunning, case .frameBased(intervalFrames: let n) = self._mode, n > 0 else { return }
            self.frameCount += 1
            if self.frameCount % n == 0 {
                _ = self.performCapture()
            }
        }
        return false
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async { self?.performCapture() }
        }
        timer?.tolerance = 0.1
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// Generate next output URL and invoke capture block. Call from queue; runs the block on main (Metal/UI safe) via async.
    @discardableResult
    private func performCapture() -> Bool {
        guard _isRunning, let dir = _outputDirectory, let block = _captureBlock else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let count = captureCount
        let name = "\(_filenamePrefix)_\(stamp)_\(count).png"
        let url = dir.appendingPathComponent(name)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let ok = block(url)
            if ok {
                self.queue.async { self.captureCount += 1 }
            } else {
                HDRLogger.error(category: Self.logCategory, "timed screenshot export failed url=\(url.path)")
            }
        }
        return true
    }
}
