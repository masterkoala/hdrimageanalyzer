import Foundation
import CoreVideo
import Logging
import Common
import DeckLinkBridge

// DeckLinkPixelFormat is defined in Common/CaptureTypes.swift as a typealias to UInt32
// with static members: .v210, .rgb8, .rgb12BitLE, .rgb12Bit

// CaptureSignalState is defined in Common/CaptureTypes.swift

/// Ancillary/VANC packet from capture frame (DL-009). Raw bytes plus line number, DID, SDID, and data space (VANC/HANC).
public struct AncillaryPacket: Sendable {
    /// Raw packet bytes (copy; valid after callback).
    public let data: Data
    /// Vertical line number (VANC/HANC line).
    public let lineNumber: UInt32
    /// Data ID.
    public let did: UInt8
    /// Secondary data ID.
    public let sdid: UInt8
    /// 0 = VANC, 1 = HANC (BMDAncillaryDataSpace).
    public let dataSpace: UInt32

    public init(data: Data, lineNumber: UInt32, did: UInt8, sdid: UInt8, dataSpace: UInt32) {
        self.data = data
        self.lineNumber = lineNumber
        self.did = did
        self.sdid = sdid
        self.dataSpace = dataSpace
    }
}

/// Timecode from capture frame (DL-008). RP188 or VITC string (e.g. "HH:MM:SS:FF"); components parsed when format is standard.
public struct CaptureTimecode: Sendable {
    public let timecodeString: String

    public init(timecodeString: String) {
        self.timecodeString = timecodeString
    }

    /// Components (hours, minutes, seconds, frames) when string matches "HH:MM:SS:FF"; nil otherwise.
    public var components: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)? {
        let parts = timecodeString.split(separator: ":")
        guard parts.count == 4,
              let h = UInt8(parts[0]), let m = UInt8(parts[1]), let s = UInt8(parts[2]), let f = UInt8(parts[3]) else { return nil }
        return (h, m, s, f)
    }
}

/// Video input format change event (DL-006). Notification events and detected signal flags match DeckLink API.
public struct DeckLinkFormatChangeEvent: Sendable {
    public let notificationEvents: UInt32
    public let displayModeId: UInt32
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let detectedSignalFlags: UInt32

    public init(notificationEvents: UInt32, displayModeId: UInt32, width: Int, height: Int, frameRate: Double, detectedSignalFlags: UInt32) {
        self.notificationEvents = notificationEvents
        self.displayModeId = displayModeId
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.detectedSignalFlags = detectedSignalFlags
    }

    /// Derive the best DeckLinkPixelFormat from the SDK's BMDDetectedVideoInputFormatFlags.
    /// Returns nil when flags are unrecognised — caller should keep user-selected format.
    public var recommendedPixelFormat: DeckLinkPixelFormat? {
        // BMDDetectedVideoInputFormatFlags constants:
        let isYCbCr  = (detectedSignalFlags & 1)  != 0   // bmdDetectedVideoInputYCbCr422
        let isRGB    = (detectedSignalFlags & 2)  != 0   // bmdDetectedVideoInputRGB444
        let is8Bit   = (detectedSignalFlags & 8)  != 0   // bmdDetectedVideoInput8BitDepth
        let is10Bit  = (detectedSignalFlags & 16) != 0   // bmdDetectedVideoInput10BitDepth
        let is12Bit  = (detectedSignalFlags & 32) != 0   // bmdDetectedVideoInput12BitDepth

        if isRGB {
            if is12Bit { return .rgb12BitLE }
            // 8-bit or 10-bit RGB → request BGRA (SDK converts for us)
            return .rgb8
        }
        if isYCbCr {
            // 10-bit or 12-bit YCbCr → v210 (native 10-bit packed)
            if is10Bit || is12Bit { return .v210 }
            // 8-bit YCbCr → request BGRA so SDK converts, or v210 (SDK upscales)
            if is8Bit { return .v210 }
            return .v210  // default YCbCr
        }
        return nil
    }
}

/// Session that starts/stops capture and delivers frames via callback (DL-004).
/// Optional `onFramePixelBuffer` (DL-005): when set, zero-copy path is tried first; handler receives owned CVPixelBuffer (caller must release when done, e.g. after creating MTLTexture).
/// Optional `onAudioSamples` (DL-010): when set, embedded SDI audio is enabled (48kHz, 16-bit, stereo); handler receives interleaved float samples in [-1, 1].
/// Optional `onTimecode` (DL-008): when set, timecode (RP188/VITC) is reported per frame; log on first frame or when timecode changes.
public final class DeckLinkCaptureSession {
    public typealias FrameHandler = (UnsafeRawPointer, Int, Int, Int, DeckLinkPixelFormat) -> Void
    /// Called with an owned CVPixelBuffer (IOSurface-backed when available). Caller must release (e.g. CFRelease or use and release after MTLTexture creation).
    public typealias FramePixelBufferHandler = (CVPixelBuffer, Int, Int, DeckLinkPixelFormat) -> Void
    public typealias FormatChangeHandler = (DeckLinkFormatChangeEvent) -> Void
    /// Called with interleaved float samples (frameCount * channels). DL-010; Phase 5 can use for metering.
    public typealias AudioSamplesHandler = (UnsafePointer<Float>, UInt32, UInt32) -> Void
    /// Optional callback when signal state changes (DL-011). Called on main queue.
    public typealias SignalStateHandler = (CaptureSignalState) -> Void
    /// Optional callback when timecode is available for a frame (DL-008). Called from SDK thread; copy if needed.
    public typealias TimecodeHandler = (CaptureTimecode) -> Void
    /// Optional callback for each VANC/HANC ancillary packet (DL-009). Called from SDK thread; data is copied into AncillaryPacket.
    public typealias AncillaryHandler = (AncillaryPacket) -> Void

    private let deviceIndex: Int
    private let modeIndex: Int
    private let pixelFormat: DeckLinkPixelFormat
    /// When true, enable format detection (bmdVideoInputEnableFormatDetection) if onFormatChange is set (CapturePreview sample).
    private let applyDetectedInputMode: Bool
    private let onFrame: FrameHandler
    private let onFramePixelBuffer: FramePixelBufferHandler?
    private let onFormatChange: FormatChangeHandler?
    private let onAudioSamples: AudioSamplesHandler?
    private let onSignalStateChange: SignalStateHandler?
    private let onTimecode: TimecodeHandler?
    private let onAncillary: AncillaryHandler?
    private let logCategory = "Capture"
    /// Expected frame interval in seconds (1/fps). Used for signal loss detection (DL-011).
    private var expectedFrameInterval: TimeInterval = 1.0 / 30.0
    /// Time of last frame arrival (CFAbsoluteTime). Zero until first frame.
    private var lastFrameArrivalTime: CFAbsoluteTime = 0
    /// Signal state: unknown until first frame; then present or lost when no frames for >2x interval.
    private var signalState: CaptureSignalState = .unknown
    /// Timer that checks for signal loss (no frames for >2x frame interval).
    private var signalLossCheckTimer: Timer?
    /// Last audio packet frame count (DL-010); for logging/QC.
    private(set) var lastAudioPacketFrameCount: UInt32 = 0
    private var isCapturing = false
    private let lock = NSLock()
    /// Allow only one frame in flight; if another arrives before delivery, count as dropped (DL-016).
    private var framePending = false
    private let frameQueue = DispatchQueue(label: "HDRImageAnalyzerPro.Capture.frameDelivery", qos: .userInteractive)
    private var receivedFrameCount: UInt64 = 0
    private var firstFrameLogged = false
    private var firstTimecodeLogged = false
    private var lastTimecodeString: String?
    /// Throttle timecode callback to UI (max 4/sec) to avoid main thread flood and freeze (DL-008).
    private var lastTimecodeCallbackTime: CFAbsoluteTime = 0
    private let timecodeCallbackInterval: CFAbsoluteTime = 0.25
    /// Throttle timecode logging to file (max 1/sec) to avoid log flood and I/O load.
    private var lastTimecodeLogTime: CFAbsoluteTime = 0
    private let timecodeLogInterval: CFAbsoluteTime = 1.0
    private var firstAncillaryLogged = false
    private var lastAncillaryPacketCount: Int = 0
    private var lastAncillaryTotalBytes: Int = 0
    private var qcTimer: Timer?
    private let qcLogInterval: TimeInterval = 10

    public init(deviceIndex: Int, modeIndex: Int, pixelFormat: DeckLinkPixelFormat, applyDetectedInputMode: Bool = false, onFrame: @escaping FrameHandler, onFramePixelBuffer: FramePixelBufferHandler? = nil, onFormatChange: FormatChangeHandler? = nil, onAudioSamples: AudioSamplesHandler? = nil, onSignalStateChange: SignalStateHandler? = nil, onTimecode: TimecodeHandler? = nil, onAncillary: AncillaryHandler? = nil) {
        self.deviceIndex = deviceIndex
        self.modeIndex = modeIndex
        self.pixelFormat = pixelFormat
        self.applyDetectedInputMode = applyDetectedInputMode
        self.onFrame = onFrame
        self.onFramePixelBuffer = onFramePixelBuffer
        self.onFormatChange = onFormatChange
        self.onAudioSamples = onAudioSamples
        self.onSignalStateChange = onSignalStateChange
        self.onTimecode = onTimecode
        self.onAncillary = onAncillary
    }

    /// Current signal state (present/lost/unknown). DL-011.
    public var currentSignalState: CaptureSignalState {
        lock.lock()
        defer { lock.unlock() }
        return signalState
    }

    /// True when signal is known to be present; false when lost or unknown.
    public var isSignalPresent: Bool { currentSignalState == .present }

    private static let bridgeCallback: DeckLinkBridgeFrameCallback = { ctx, bytes, rowBytes, width, height, pf in
        guard let ctx = ctx, let bytes = bytes else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        session.handleFrameArrived(bytes: bytes, rowBytes: Int(rowBytes), width: Int(width), height: Int(height), pixelFormat: DeckLinkPixelFormat(pf))
    }

    private static let bridgeCVPixelBufferCallback: DeckLinkBridgeCVPixelBufferFrameCallback = { ctx, cvPixelBuffer, width, height, pf in
        guard let ctx = ctx, let cvPixelBuffer = cvPixelBuffer else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(cvPixelBuffer).takeRetainedValue()
        session.handleFramePixelBuffer(pixelBuffer, width: Int(width), height: Int(height), pixelFormat: DeckLinkPixelFormat(pf))
    }

    private static let formatChangeCallback: DeckLinkBridgeFormatChangeCallback = { ctx, notificationEvents, displayModeId, width, height, frameRate, detectedSignalFlags in
        guard let ctx = ctx else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        let event = DeckLinkFormatChangeEvent(
            notificationEvents: notificationEvents,
            displayModeId: displayModeId,
            width: Int(width),
            height: Int(height),
            frameRate: frameRate,
            detectedSignalFlags: detectedSignalFlags
        )
        HDRLogger.info(category: "Capture", "Format change: \(width)x\(height) @ \(frameRate) fps displayModeId=\(displayModeId) flags=\(detectedSignalFlags)")
        // Only mark signal recovery if we have valid dimensions (flags indicate real signal)
        if width > 0 && height > 0 {
            session.recordSignalRecovery(reason: "format change")
        }
        DispatchQueue.main.async { session.onFormatChange?(event) }
    }

    private static let bridgeAudioCallback: DeckLinkBridgeAudioCallback = { ctx, samples, frameCount, channels in
        guard let ctx = ctx, let samples = samples else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        session.handleAudioSamples(samples: samples, frameCount: frameCount, channels: channels)
    }

    private static let bridgeTimecodeCallback: DeckLinkBridgeTimecodeCallback = { ctx, timecodeUTF8 in
        guard let ctx = ctx, let timecodeUTF8 = timecodeUTF8 else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        let str = String(cString: timecodeUTF8)
        session.handleTimecode(CaptureTimecode(timecodeString: str))
    }

    private static let bridgeAncillaryCallback: DeckLinkBridgeAncillaryCallback = { ctx, bytes, length, lineNumber, did, sdid, dataSpace in
        guard let ctx = ctx, let bytes = bytes, length > 0 else { return }
        let session = Unmanaged<DeckLinkCaptureSession>.fromOpaque(ctx).takeUnretainedValue()
        let data = Data(bytes: bytes, count: Int(length))
        let packet = AncillaryPacket(data: data, lineNumber: lineNumber, did: did, sdid: sdid, dataSpace: dataSpace)
        session.handleAncillary(packet)
    }

    private func handleAncillary(_ packet: AncillaryPacket) {
        lock.lock()
        let isFirst = !firstAncillaryLogged
        if isFirst { firstAncillaryLogged = true }
        lastAncillaryPacketCount += 1
        lastAncillaryTotalBytes += packet.data.count
        lock.unlock()
        if isFirst {
            HDRLogger.info(category: logCategory, "First ancillary packet: line=\(packet.lineNumber) DID=\(packet.did) SDID=\(packet.sdid) size=\(packet.data.count) dataSpace=\(packet.dataSpace)")
        }
        onAncillary?(packet)
    }

    private func handleTimecode(_ timecode: CaptureTimecode) {
        // QC-004: Set current frame timecode so QC events logged during this frame get frame-accurate timecode (DL-008).
        TimecodedQCContext.setCurrentFrameTimecode(timecode.timecodeString)
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let isFirst = !firstTimecodeLogged
        if isFirst { firstTimecodeLogged = true }
        let changed = lastTimecodeString != timecode.timecodeString
        if changed { lastTimecodeString = timecode.timecodeString }
        let shouldLog = isFirst || (changed && (now - lastTimecodeLogTime) >= timecodeLogInterval)
        if shouldLog { lastTimecodeLogTime = now }
        let shouldCallback = (now - lastTimecodeCallbackTime) >= timecodeCallbackInterval
        if shouldCallback { lastTimecodeCallbackTime = now }
        lock.unlock()
        if isFirst {
            HDRLogger.info(category: logCategory, "First timecode: \(timecode.timecodeString)")
        } else if shouldLog {
            HDRLogger.info(category: logCategory, "Timecode changed: \(timecode.timecodeString)")
        }
        if shouldCallback {
            onTimecode?(timecode)
        }
    }

    private func handleFramePixelBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, pixelFormat: DeckLinkPixelFormat) {
        lock.lock()
        if framePending {
            PerformanceCounters.shared.recordDroppedFrame()
            let totalDropped = PerformanceCounters.shared.droppedFrameCount
            lock.unlock()
            HDRLogger.info(category: logCategory, "Dropped frame (total dropped= \(totalDropped))")
            return
        }
        framePending = true
        lock.unlock()
        guard let onFramePixelBuffer = onFramePixelBuffer else {
            lock.lock()
            framePending = false
            lock.unlock()
            return
        }
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            self.recordFrameArrival()
            self.logFrameArrivalIfNeeded()
            onFramePixelBuffer(pixelBuffer, width, height, pixelFormat)
            self.lock.lock()
            self.framePending = false
            self.lock.unlock()
        }
    }

    private func handleAudioSamples(samples: UnsafePointer<Float>, frameCount: UInt32, channels: UInt32) {
        lastAudioPacketFrameCount = frameCount
        onAudioSamples?(samples, frameCount, channels)
    }

    private func handleFrameArrived(bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, pixelFormat: DeckLinkPixelFormat) {
        lock.lock()
        if framePending {
            PerformanceCounters.shared.recordDroppedFrame()
            let totalDropped = PerformanceCounters.shared.droppedFrameCount
            lock.unlock()
            HDRLogger.info(category: logCategory, "Dropped frame (total dropped= \(totalDropped))")
            return
        }
        framePending = true
        lock.unlock()
        // Submit directly on SDK thread — TripleBufferedFrameManager.submitFrame copies to its own
        // staging buffer, so the SDK buffer pointer is safe to release after onFrame returns.
        // This eliminates: (1) Data allocation, (2) Data memcpy, (3) closure capture overhead.
        recordFrameArrival()
        logFrameArrivalIfNeeded()
        onFrame(bytes, rowBytes, width, height, pixelFormat)
        lock.lock()
        framePending = false
        lock.unlock()
    }

    private func logFrameArrivalIfNeeded() {
        lock.lock()
        receivedFrameCount += 1
        let count = receivedFrameCount
        let first = !firstFrameLogged
        if first { firstFrameLogged = true }
        lock.unlock()
        if first {
            // #region agent log
            debugSessionLog(location: "DeckLinkCaptureSession.logFrameArrivalIfNeeded", message: "first frame received", data: ["receivedFrameCount": count], hypothesisId: "H4")
            // #endregion
            HDRLogger.info(category: logCategory, "First frame received")
        } else if count % 300 == 0 {
            HDRLogger.debug(category: logCategory, "Frame arrival (received= \(count))")
        }
    }

    /// Record frame arrival for signal loss detection (DL-011). Call from both handleFrameArrived and handleFramePixelBuffer paths.
    private func recordFrameArrival() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastFrameArrivalTime = now
        let wasLost = (signalState == .lost)
        if wasLost {
            signalState = .present
            lock.unlock()
            HDRLogger.info(category: logCategory, "Signal recovered (frames resumed)")
            DispatchQueue.main.async { [weak self] in
                self?.onSignalStateChange?(.present)
            }
        } else {
            let wasUnknown = (signalState == .unknown)
            if wasUnknown { signalState = .present }
            lock.unlock()
            if wasUnknown {
                DispatchQueue.main.async { [weak self] in
                    self?.onSignalStateChange?(.present)
                }
            }
        }
    }

    /// Clear signal-lost state on recovery (format change). Called from format-change callback (SDK thread).
    private func recordSignalRecovery(reason: String) {
        lock.lock()
        let wasLost = (signalState == .lost)
        signalState = .present
        lock.unlock()
        if wasLost {
            HDRLogger.info(category: logCategory, "Signal recovered (\(reason))")
            DispatchQueue.main.async { [weak self] in
                self?.onSignalStateChange?(.present)
            }
        }
    }

    /// Timer tick: if no frame for >2x frame interval, mark signal lost and notify (DL-011).
    private func checkSignalLoss() {
        lock.lock()
        guard isCapturing, receivedFrameCount > 0, signalState != .lost else {
            lock.unlock()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let interval = expectedFrameInterval
        let last = lastFrameArrivalTime
        let elapsed = now - last
        if elapsed > 2.0 * interval {
            signalState = .lost
            lock.unlock()
            HDRLogger.info(category: logCategory, "Signal loss detected (no frames for \(String(format: "%.2f", elapsed))s > 2× frame interval \(String(format: "%.3f", interval))s)")
            DispatchQueue.main.async { [weak self] in
                self?.onSignalStateChange?(.lost)
            }
        } else {
            lock.unlock()
        }
    }

    /// Start capture. Returns false if already capturing or bridge error. If onFormatChange was set, format detection is enabled (DL-006).
    public func start() -> Bool {
        lock.lock()
        if isCapturing {
            lock.unlock()
            return false
        }
        lock.unlock()
        let modes = DeckLinkGetDisplayModes(deviceIndex: deviceIndex)
        if modeIndex < modes.count, modes[modeIndex].frameRate > 0 {
            expectedFrameInterval = 1.0 / modes[modeIndex].frameRate
        } else {
            expectedFrameInterval = 1.0 / 30.0
        }
        lock.lock()
        lastFrameArrivalTime = 0
        signalState = .unknown
        lock.unlock()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let formatCb: DeckLinkBridgeFormatChangeCallback? = onFormatChange != nil ? DeckLinkCaptureSession.formatChangeCallback : nil
        let cvCb: DeckLinkBridgeCVPixelBufferFrameCallback? = onFramePixelBuffer != nil ? DeckLinkCaptureSession.bridgeCVPixelBufferCallback : nil
        let audioCb: DeckLinkBridgeAudioCallback? = onAudioSamples != nil ? DeckLinkCaptureSession.bridgeAudioCallback : nil
        let ancillaryCb: DeckLinkBridgeAncillaryCallback? = onAncillary != nil ? DeckLinkCaptureSession.bridgeAncillaryCallback : nil
        // DL-008: Always register timecode callback so we can log first/change even when onTimecode is nil. DL-009: ancillary (VANC/HANC) optional.
        let result = DeckLinkBridgeStartCapture(
            Int32(deviceIndex),
            Int32(modeIndex),
            pixelFormat,
            applyDetectedInputMode ? 1 : 0,
            DeckLinkCaptureSession.bridgeCallback,
            ctx,
            formatCb,
            formatCb != nil ? ctx : nil,
            cvCb,
            audioCb,
            audioCb != nil ? ctx : nil,
            DeckLinkCaptureSession.bridgeTimecodeCallback,
            ctx,
            ancillaryCb,
            ancillaryCb != nil ? ctx : nil
        )
        // #region agent log
        debugSessionLog(location: "DeckLinkCaptureSession.start", message: "DeckLinkBridgeStartCapture result", data: ["result": result], hypothesisId: "H3")
        // #endregion
        lock.lock()
        if result == 0 {
            isCapturing = true
            receivedFrameCount = 0
            firstFrameLogged = false
            firstTimecodeLogged = false
            lastTimecodeString = nil
            firstAncillaryLogged = false
            lastAncillaryPacketCount = 0
            lastAncillaryTotalBytes = 0
            startQCTimer()
            startSignalLossCheckTimer()
            lock.unlock()
            HDRLogger.info(category: "Capture", "DeckLink capture started device=\(deviceIndex) mode=\(modeIndex) frameInterval=\(String(format: "%.3f", expectedFrameInterval))s")
        } else {
            lock.unlock()
            if result == -2 {
                HDRLogger.info(category: "Capture", "DeckLink device \(deviceIndex) already has an active capture (one per device)")
            } else {
                HDRLogger.error(category: "Capture", "DeckLink StartCapture failed: \(result)")
            }
        }
        return result == 0
    }

    /// Stop capture.
    public func stop() {
        lock.lock()
        if !isCapturing {
            lock.unlock()
            return
        }
        stopQCTimer()
        stopSignalLossCheckTimer()
        signalState = .unknown
        lastFrameArrivalTime = 0
        DeckLinkBridgeStopCapture(Int32(deviceIndex))
        isCapturing = false
        TimecodedQCContext.clearCurrentFrameTimecode()
        lock.unlock()
        HDRLogger.info(category: "Capture", "DeckLink capture stopped device=\(deviceIndex)")
    }

    public var capturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCapturing
    }

    private func startQCTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.qcTimer?.invalidate()
            self?.qcTimer = Timer.scheduledTimer(withTimeInterval: self?.qcLogInterval ?? 10, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                let capturing = self.isCapturing
                let received = self.receivedFrameCount
                self.lock.unlock()
                if capturing {
                    let dropped = PerformanceCounters.shared.droppedFrameCount
                    HDRLogger.info(category: self.logCategory, "Capture QC: received= \(received) dropped= \(dropped)")
                }
            }
            self?.qcTimer?.tolerance = 1
            RunLoop.main.add(self?.qcTimer ?? Timer(), forMode: .common)
        }
    }

    private func stopQCTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.qcTimer?.invalidate()
            self?.qcTimer = nil
        }
    }

    private func startSignalLossCheckTimer() {
        let interval = min(max(expectedFrameInterval, 0.05), 0.2)
        DispatchQueue.main.async { [weak self] in
            self?.signalLossCheckTimer?.invalidate()
            self?.signalLossCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkSignalLoss()
            }
            self?.signalLossCheckTimer?.tolerance = 0.02
            if let t = self?.signalLossCheckTimer { RunLoop.main.add(t, forMode: .common) }
        }
    }

    private func stopSignalLossCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.signalLossCheckTimer?.invalidate()
            self?.signalLossCheckTimer = nil
        }
    }
}
