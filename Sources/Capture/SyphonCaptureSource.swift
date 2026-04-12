import Foundation
import Metal
import AppKit
import SwiftUI
import Common
import Logging

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Syphon Capture Source (Phase 10, SYPH-001)
// Syphon input support for GPU-level video capture on macOS.
// Zero-latency monitoring from DaVinci Resolve, Final Cut Pro, After Effects, etc.
// Uses Objective-C runtime to interface with Syphon.framework (dynamically loaded).

// MARK: - Syphon Server Description

/// Describes a discovered Syphon server (publisher) on the system.
public struct SyphonServerDescription: Equatable, Identifiable, Sendable {
    /// Server name (may be empty for unnamed servers).
    public let name: String
    /// Application name publishing the Syphon server.
    public let appName: String
    /// Unique identifier for this server instance.
    public let uuid: String

    public var id: String { uuid }

    /// Combined display name for UI presentation.
    public var displayName: String {
        if name.isEmpty {
            return appName
        }
        return "\(appName) - \(name)"
    }

    public init(name: String, appName: String, uuid: String) {
        self.name = name
        self.appName = appName
        self.uuid = uuid
    }
}

// MARK: - Syphon Framework Loader

/// Manages dynamic loading of Syphon.framework via dlopen / Objective-C runtime.
/// Provides graceful degradation when Syphon is not installed.
private final class SyphonFrameworkLoader {
    static let shared = SyphonFrameworkLoader()

    private(set) var isLoaded = false
    private var frameworkHandle: UnsafeMutableRawPointer?

    // Cached Objective-C class references
    private(set) var syphonServerDirectoryClass: AnyClass?
    private(set) var syphonClientClass: AnyClass?

    private static let frameworkPaths = [
        "/Library/Frameworks/Syphon.framework/Syphon",
        "/usr/local/Frameworks/Syphon.framework/Syphon",
        "Syphon.framework/Syphon",
        "@rpath/Syphon.framework/Syphon",
    ]

    private init() {
        loadFramework()
    }

    deinit {
        if let handle = frameworkHandle {
            dlclose(handle)
        }
    }

    private func loadFramework() {
        for path in Self.frameworkPaths {
            let handle = dlopen(path, RTLD_NOW)
            if let handle = handle {
                frameworkHandle = handle
                resolveClasses()
                if syphonServerDirectoryClass != nil {
                    isLoaded = true
                    HDRLogger.info(category: "Syphon", "Syphon.framework loaded from: \(path)")
                    return
                } else {
                    dlclose(handle)
                    frameworkHandle = nil
                }
            }
        }
        HDRLogger.info(category: "Syphon", "Syphon.framework not available (not installed or not in expected paths)")
    }

    private func resolveClasses() {
        syphonServerDirectoryClass = NSClassFromString("SyphonServerDirectory")
        syphonClientClass = NSClassFromString("SyphonClient")
        if syphonServerDirectoryClass == nil {
            HDRLogger.debug(category: "Syphon", "SyphonServerDirectory class not found in loaded framework")
        }
        if syphonClientClass == nil {
            HDRLogger.debug(category: "Syphon", "SyphonClient class not found in loaded framework")
        }
    }
}

// MARK: - Syphon Server Directory Keys

/// Keys used in Syphon server description dictionaries.
private enum SyphonServerKey {
    static let serverName = "SyphonServerDescriptionNameKey"
    static let appName = "SyphonServerDescriptionAppNameKey"
    static let uuid = "SyphonServerDescriptionUUIDKey"
}

// MARK: - Syphon Notification Names

/// Notification names broadcast by SyphonServerDirectory.
private enum SyphonNotification {
    static let serverAnnounce = "SyphonServerAnnounceNotification"
    static let serverRetire = "SyphonServerRetireNotification"
    static let serverUpdate = "SyphonServerUpdateNotification"
}

// MARK: - SyphonCaptureSource

/// Capture source that subscribes to a Syphon server to receive GPU textures.
/// Conforms to CaptureSource for integration with the capture pipeline.
///
/// Uses Objective-C runtime to dynamically interface with Syphon.framework.
/// Converts received IOSurface-backed textures into MTLTexture frames for the pipeline.
public final class SyphonCaptureSource: CaptureSourceBase, CaptureSource {

    private let logCategory = "Syphon"
    private let lock = NSLock()

    // MARK: - Published Properties

    /// Currently discovered Syphon servers.
    public private(set) var availableServers: [SyphonServerDescription] = []

    /// The server currently selected for capture.
    public private(set) var selectedServer: SyphonServerDescription?

    /// Callback invoked when a new texture frame is received from the Syphon server.
    /// Parameters: (texture, width, height).
    public var onFrameReceived: ((MTLTexture, Int, Int) -> Void)?

    /// Callback invoked when the format (resolution or frame rate) changes.
    /// Parameters: (width, height, estimatedFrameRate).
    public var onFormatChanged: ((Int, Int, Double) -> Void)?

    /// Callback invoked when signal state changes.
    public var onSignalStateChanged: ((CaptureSignalState) -> Void)?

    // MARK: - Private State

    /// The Objective-C SyphonClient instance (retained via Unmanaged).
    private var syphonClient: AnyObject?

    /// The SyphonServerDirectory shared instance.
    private var serverDirectory: AnyObject?

    /// Metal device used for texture creation from IOSurface.
    private let metalDevice: MTLDevice?

    /// Texture cache for converting IOSurface to MTLTexture.
    private var textureCache: CVMetalTextureCache?

    /// Tracks last known frame dimensions for format change detection.
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    /// Frame counter for logging.
    private var receivedFrameCount: UInt64 = 0
    private var firstFrameLogged = false

    /// Signal loss detection.
    private var lastFrameArrivalTime: CFAbsoluteTime = 0
    private var signalLossCheckTimer: Timer?
    private let expectedFrameInterval: TimeInterval = 1.0 / 60.0

    /// Estimated frame rate based on frame arrival times.
    private var frameRateEstimator = FrameRateEstimator()

    /// Notification observers for server directory changes.
    private var announceObserver: NSObjectProtocol?
    private var retireObserver: NSObjectProtocol?

    // MARK: - Initialization

    public override init(sourceId: String = "syphon_capture", sourceName: String = "Syphon Input") {
        self.metalDevice = MTLCreateSystemDefaultDevice()
        super.init(sourceId: sourceId, sourceName: sourceName)

        if let device = metalDevice {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            self.textureCache = cache
        }

        HDRLogger.info(category: logCategory, "SyphonCaptureSource initialized; framework available: \(SyphonFrameworkLoader.shared.isLoaded)")
    }

    deinit {
        stopCapture()
        disconnect()
        removeServerDirectoryObservers()
    }

    // MARK: - Framework Availability

    /// Whether Syphon.framework is loaded and available.
    public var isSyphonAvailable: Bool {
        SyphonFrameworkLoader.shared.isLoaded
    }

    // MARK: - CaptureSource Protocol

    override public func connect() -> Bool {
        guard SyphonFrameworkLoader.shared.isLoaded else {
            HDRLogger.info(category: logCategory, "Cannot connect: Syphon.framework not available")
            return false
        }

        guard metalDevice != nil else {
            HDRLogger.error(category: logCategory, "Cannot connect: no Metal device available")
            return false
        }

        // Get the SyphonServerDirectory shared instance
        guard let directoryClass = SyphonFrameworkLoader.shared.syphonServerDirectoryClass else {
            HDRLogger.error(category: logCategory, "Cannot connect: SyphonServerDirectory class not found")
            return false
        }

        let sharedSel = NSSelectorFromString("sharedDirectory")
        guard directoryClass.responds(to: sharedSel) else {
            HDRLogger.error(category: logCategory, "SyphonServerDirectory does not respond to sharedDirectory")
            return false
        }

        let directory = (directoryClass as AnyObject).perform(sharedSel)?.takeUnretainedValue()
        serverDirectory = directory

        setupServerDirectoryObservers()
        refreshServerList()

        HDRLogger.info(category: logCategory, "Connected to Syphon server directory; found \(availableServers.count) server(s)")
        return super.connect()
    }

    override public func disconnect() {
        stopCapture()
        removeServerDirectoryObservers()
        serverDirectory = nil

        lock.lock()
        availableServers = []
        selectedServer = nil
        lock.unlock()

        super.disconnect()
        HDRLogger.info(category: logCategory, "Disconnected from Syphon server directory")
    }

    override public func startCapture() -> Bool {
        guard SyphonFrameworkLoader.shared.isLoaded else {
            HDRLogger.info(category: logCategory, "Cannot start capture: Syphon.framework not available")
            return false
        }

        guard let server = selectedServer else {
            HDRLogger.info(category: logCategory, "Cannot start capture: no server selected")
            return false
        }

        guard let device = metalDevice else {
            HDRLogger.error(category: logCategory, "Cannot start capture: no Metal device")
            return false
        }

        guard let clientClass = SyphonFrameworkLoader.shared.syphonClientClass else {
            HDRLogger.error(category: logCategory, "Cannot start capture: SyphonClient class not found")
            return false
        }

        // Build the server description dictionary for SyphonClient
        let serverDict: NSDictionary = [
            SyphonServerKey.serverName: server.name,
            SyphonServerKey.appName: server.appName,
            SyphonServerKey.uuid: server.uuid,
        ]

        // Create SyphonClient via Objective-C runtime:
        // [[SyphonClient alloc] initWithServerDescription:serverDict context:CGLContext options:nil newFrameHandler:handler]
        // We use the Metal-based init if available, falling back to OpenGL + IOSurface extraction.
        let client = createSyphonClient(clientClass: clientClass, serverDict: serverDict, device: device)
        guard let client = client else {
            HDRLogger.error(category: logCategory, "Failed to create SyphonClient for server: \(server.displayName)")
            return false
        }

        lock.lock()
        syphonClient = client
        receivedFrameCount = 0
        firstFrameLogged = false
        lastFrameArrivalTime = 0
        lastWidth = 0
        lastHeight = 0
        frameRateEstimator.reset()
        lock.unlock()

        startSignalLossCheckTimer()

        HDRLogger.info(category: logCategory, "Capture started for server: \(server.displayName)")
        return super.startCapture()
    }

    override public func stopCapture() {
        stopSignalLossCheckTimer()

        lock.lock()
        let client = syphonClient
        syphonClient = nil
        let frameCount = receivedFrameCount
        lock.unlock()

        // Stop the SyphonClient
        if let client = client {
            let stopSel = NSSelectorFromString("stop")
            if (client as AnyObject).responds(to: stopSel) {
                _ = (client as AnyObject).perform(stopSel)
            }
        }

        super.stopCapture()
        HDRLogger.info(category: logCategory, "Capture stopped; total frames received: \(frameCount)")
    }

    // MARK: - Server Discovery

    /// Refresh the list of available Syphon servers.
    public func refreshServerList() {
        guard let directory = serverDirectory else {
            HDRLogger.debug(category: logCategory, "Cannot refresh server list: no directory instance")
            return
        }

        let serversSel = NSSelectorFromString("servers")
        guard (directory as AnyObject).responds(to: serversSel) else {
            HDRLogger.debug(category: logCategory, "SyphonServerDirectory does not respond to servers")
            return
        }

        guard let serversResult = (directory as AnyObject).perform(serversSel)?.takeUnretainedValue() else {
            lock.lock()
            availableServers = []
            lock.unlock()
            return
        }

        guard let serverDicts = serversResult as? [[String: Any]] else {
            lock.lock()
            availableServers = []
            lock.unlock()
            return
        }

        let servers = serverDicts.compactMap { dict -> SyphonServerDescription? in
            guard let uuid = dict[SyphonServerKey.uuid] as? String else { return nil }
            let name = dict[SyphonServerKey.serverName] as? String ?? ""
            let appName = dict[SyphonServerKey.appName] as? String ?? "Unknown"
            return SyphonServerDescription(name: name, appName: appName, uuid: uuid)
        }

        lock.lock()
        availableServers = servers
        lock.unlock()

        HDRLogger.debug(category: logCategory, "Server list refreshed: \(servers.count) server(s) found")
    }

    /// Select a Syphon server for capture. If capture is active, it will be restarted.
    public func selectServer(_ server: SyphonServerDescription) {
        let wasCapturing = isCapturing

        if wasCapturing {
            stopCapture()
        }

        lock.lock()
        selectedServer = server
        lock.unlock()

        HDRLogger.info(category: logCategory, "Selected server: \(server.displayName)")

        if wasCapturing {
            _ = startCapture()
        }
    }

    // MARK: - SyphonClient Creation (Objective-C Runtime)

    /// Creates a SyphonClient instance using Objective-C runtime.
    /// Attempts SyphonMetalClient first (Syphon 0.4+), falls back to SyphonClient with IOSurface extraction.
    private func createSyphonClient(clientClass: AnyClass, serverDict: NSDictionary, device: MTLDevice) -> AnyObject? {
        // Try SyphonMetalClient first (Syphon 0.4+ with Metal support)
        if let metalClientClass = NSClassFromString("SyphonMetalClient") {
            if let client = createMetalClient(clientClass: metalClientClass, serverDict: serverDict, device: device) {
                HDRLogger.info(category: logCategory, "Using SyphonMetalClient (native Metal path)")
                return client
            }
        }

        // Fall back to standard SyphonClient with OpenGL context + IOSurface extraction
        return createOpenGLClient(clientClass: clientClass, serverDict: serverDict, device: device)
    }

    /// Create a SyphonMetalClient (native Metal path, Syphon 0.4+).
    private func createMetalClient(clientClass: AnyClass, serverDict: NSDictionary, device: MTLDevice) -> AnyObject? {
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithServerDescription:device:options:newFrameHandler:")

        guard clientClass.responds(to: allocSel) else { return nil }
        guard let allocated = (clientClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return nil }

        // Check if the Metal init selector exists
        guard allocated.responds(to: initSel) else { return nil }

        // We cannot directly invoke initWithServerDescription:device:options:newFrameHandler:
        // via perform() because it has >2 arguments. Use NSInvocation equivalent via objc_msgSend.
        typealias InitFn = @convention(c) (AnyObject, Selector, NSDictionary, MTLDevice, NSDictionary?, Any?) -> AnyObject?
        let imp = unsafeBitCast(
            class_getMethodImplementation(type(of: allocated), initSel),
            to: InitFn.self
        )

        let frameHandler: @convention(block) (AnyObject) -> Void = { [weak self] client in
            self?.handleNewFrame(from: client)
        }

        let client = imp(allocated, initSel, serverDict, device, nil, frameHandler)
        return client
    }

    /// Create a standard SyphonClient with OpenGL context (legacy path).
    /// Extracts IOSurface from received frames and converts to MTLTexture.
    private func createOpenGLClient(clientClass: AnyClass, serverDict: NSDictionary, device: MTLDevice) -> AnyObject? {
        // Get an OpenGL context for SyphonClient
        guard let glContext = createSharedGLContext() else {
            HDRLogger.error(category: logCategory, "Failed to create OpenGL context for SyphonClient")
            return nil
        }

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithServerDescription:context:options:newFrameHandler:")

        guard clientClass.responds(to: allocSel) else { return nil }
        guard let allocated = (clientClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return nil }
        guard allocated.responds(to: initSel) else { return nil }

        typealias InitFn = @convention(c) (AnyObject, Selector, NSDictionary, OpaquePointer, NSDictionary?, Any?) -> AnyObject?
        let imp = unsafeBitCast(
            class_getMethodImplementation(type(of: allocated), initSel),
            to: InitFn.self
        )

        let frameHandler: @convention(block) (AnyObject) -> Void = { [weak self] client in
            self?.handleNewFrameFromGLClient(from: client)
        }

        let client = imp(allocated, initSel, serverDict, glContext, nil, frameHandler)
        HDRLogger.info(category: logCategory, "Using SyphonClient (OpenGL + IOSurface extraction path)")
        return client
    }

    /// Creates a shared CGL context for the legacy SyphonClient path.
    private func createSharedGLContext() -> OpaquePointer? {
        var pf: CGLPixelFormatObj?
        var npix: GLint = 0
        var attrs: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_GL4_Core.rawValue)),
            CGLPixelFormatAttribute(0),
        ]
        let err = CGLChoosePixelFormat(&attrs, &pf, &npix)
        guard err == kCGLNoError, let pixelFormat = pf else {
            // Fall back to legacy profile
            var legacyAttrs: [CGLPixelFormatAttribute] = [CGLPixelFormatAttribute(0)]
            let err2 = CGLChoosePixelFormat(&legacyAttrs, &pf, &npix)
            guard err2 == kCGLNoError, let legacyPF = pf else { return nil }
            var ctx: CGLContextObj?
            CGLCreateContext(legacyPF, nil, &ctx)
            CGLDestroyPixelFormat(legacyPF)
            return ctx.map { OpaquePointer($0) }
        }
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        CGLDestroyPixelFormat(pixelFormat)
        return ctx.map { OpaquePointer($0) }
    }

    // MARK: - Frame Handling

    /// Handle a new frame from SyphonMetalClient (native Metal path).
    private func handleNewFrame(from client: AnyObject) {
        recordFrameArrival()

        // Get the texture via -[SyphonMetalClient newFrameImage]
        let newFrameSel = NSSelectorFromString("newFrameImage")
        guard client.responds(to: newFrameSel),
              let result = client.perform(newFrameSel)?.takeRetainedValue() else {
            return
        }

        // The result should be an id<MTLTexture>
        guard let texture = result as? MTLTexture else {
            return
        }

        let width = texture.width
        let height = texture.height

        logFrameArrivalIfNeeded(width: width, height: height)
        detectFormatChange(width: width, height: height)

        onFrameReceived?(texture, width, height)
    }

    /// Handle a new frame from legacy SyphonClient (OpenGL path).
    /// Extracts IOSurface and converts to MTLTexture.
    private func handleNewFrameFromGLClient(from client: AnyObject) {
        recordFrameArrival()

        guard let device = metalDevice else { return }

        // Get the IOSurface via -[SyphonClient IOSurface] (Syphon internal method)
        // or via -[SyphonClient newFrameImage] which returns an SyphonImage with IOSurface.
        let newFrameSel = NSSelectorFromString("newFrameImage")
        guard client.responds(to: newFrameSel),
              let frameImage = client.perform(newFrameSel)?.takeRetainedValue() else {
            return
        }

        // Get texture size from SyphonImage
        let sizeSel = NSSelectorFromString("textureSize")
        var width: Int = 0
        var height: Int = 0

        if frameImage.responds(to: sizeSel) {
            // textureSize returns NSSize
            typealias SizeFn = @convention(c) (AnyObject, Selector) -> NSSize
            let sizeImp = unsafeBitCast(
                class_getMethodImplementation(type(of: frameImage), sizeSel),
                to: SizeFn.self
            )
            let size = sizeImp(frameImage, sizeSel)
            width = Int(size.width)
            height = Int(size.height)
        }

        // Extract IOSurface from SyphonImage
        let surfaceSel = NSSelectorFromString("surface")
        guard frameImage.responds(to: surfaceSel),
              let surfaceResult = frameImage.perform(surfaceSel)?.takeUnretainedValue() else {
            return
        }

        // Convert IOSurface to MTLTexture
        let surface = unsafeBitCast(surfaceResult, to: IOSurface.self)
        if width == 0 { width = IOSurfaceGetWidth(surface) }
        if height == 0 { height = IOSurfaceGetHeight(surface) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            HDRLogger.debug(category: logCategory, "Failed to create MTLTexture from IOSurface")
            return
        }

        logFrameArrivalIfNeeded(width: width, height: height)
        detectFormatChange(width: width, height: height)

        onFrameReceived?(texture, width, height)
    }

    // MARK: - Signal Detection

    /// Record frame arrival time for signal loss detection.
    private func recordFrameArrival() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastFrameArrivalTime = now
        frameRateEstimator.recordFrame(time: now)
        let wasLost = (currentSignalState == .lost)
        let wasUnknown = (currentSignalState == .unknown)
        lock.unlock()

        if wasLost {
            HDRLogger.info(category: logCategory, "Signal recovered (frames resumed)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onSignalStateChanged?(.present)
            }
        } else if wasUnknown {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onSignalStateChanged?(.present)
            }
        }
    }

    /// Log first frame and periodic frame counts.
    private func logFrameArrivalIfNeeded(width: Int, height: Int) {
        lock.lock()
        receivedFrameCount += 1
        let count = receivedFrameCount
        let first = !firstFrameLogged
        if first { firstFrameLogged = true }
        lock.unlock()

        if first {
            HDRLogger.info(category: logCategory, "First Syphon frame received: \(width)x\(height)")
        } else if count % 300 == 0 {
            let fps = frameRateEstimator.estimatedFPS
            HDRLogger.debug(category: logCategory, "Syphon frame arrival (received=\(count) est_fps=\(String(format: "%.1f", fps)))")
        }
    }

    /// Detect resolution changes and notify via callback.
    private func detectFormatChange(width: Int, height: Int) {
        lock.lock()
        let changed = (width != lastWidth || height != lastHeight) && width > 0 && height > 0
        if changed {
            lastWidth = width
            lastHeight = height
        }
        lock.unlock()

        if changed {
            let fps = frameRateEstimator.estimatedFPS
            HDRLogger.info(category: logCategory, "Format change detected: \(width)x\(height) @ ~\(String(format: "%.1f", fps)) fps")
            DispatchQueue.main.async { [weak self] in
                self?.onFormatChanged?(width, height, fps)
            }
        }
    }

    // MARK: - Signal Loss Timer

    private func startSignalLossCheckTimer() {
        let interval = min(max(expectedFrameInterval, 0.05), 0.2)
        DispatchQueue.main.async { [weak self] in
            self?.signalLossCheckTimer?.invalidate()
            self?.signalLossCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkSignalLoss()
            }
            self?.signalLossCheckTimer?.tolerance = 0.02
            if let t = self?.signalLossCheckTimer {
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    private func stopSignalLossCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.signalLossCheckTimer?.invalidate()
            self?.signalLossCheckTimer = nil
        }
    }

    private func checkSignalLoss() {
        lock.lock()
        guard isCapturing, receivedFrameCount > 0, currentSignalState != .lost else {
            lock.unlock()
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let last = lastFrameArrivalTime
        let elapsed = now - last
        if elapsed > 2.0 * expectedFrameInterval {
            lock.unlock()
            HDRLogger.info(category: logCategory, "Signal loss detected (no frames for \(String(format: "%.2f", elapsed))s)")
            DispatchQueue.main.async { [weak self] in
                self?.onSignalStateChanged?(.lost)
            }
        } else {
            lock.unlock()
        }
    }

    // MARK: - Server Directory Observers

    private func setupServerDirectoryObservers() {
        let nc = NotificationCenter.default

        announceObserver = nc.addObserver(
            forName: NSNotification.Name(SyphonNotification.serverAnnounce),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshServerList()
        }

        retireObserver = nc.addObserver(
            forName: NSNotification.Name(SyphonNotification.serverRetire),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleServerRetired(notification)
        }
    }

    private func removeServerDirectoryObservers() {
        let nc = NotificationCenter.default
        if let observer = announceObserver {
            nc.removeObserver(observer)
            announceObserver = nil
        }
        if let observer = retireObserver {
            nc.removeObserver(observer)
            retireObserver = nil
        }
    }

    private func handleServerRetired(_ notification: Notification) {
        refreshServerList()

        // If the retired server is our currently selected/capturing server, stop capture
        if let userInfo = notification.userInfo,
           let uuid = userInfo[SyphonServerKey.uuid] as? String {
            lock.lock()
            let isSelected = selectedServer?.uuid == uuid
            lock.unlock()

            if isSelected && isCapturing {
                HDRLogger.info(category: logCategory, "Selected Syphon server retired; stopping capture")
                stopCapture()
            }
        }
    }
}

// MARK: - Frame Rate Estimator

/// Simple frame rate estimator using a rolling window of frame arrival times.
private struct FrameRateEstimator {
    private var timestamps: [CFAbsoluteTime] = []
    private let windowSize = 60

    var estimatedFPS: Double {
        guard timestamps.count >= 2 else { return 0 }
        let duration = timestamps.last! - timestamps.first!
        guard duration > 0 else { return 0 }
        return Double(timestamps.count - 1) / duration
    }

    mutating func recordFrame(time: CFAbsoluteTime) {
        timestamps.append(time)
        if timestamps.count > windowSize {
            timestamps.removeFirst(timestamps.count - windowSize)
        }
    }

    mutating func reset() {
        timestamps.removeAll()
    }
}

// MARK: - SyphonDiscovery (ObservableObject)

/// Monitors Syphon server announcements and retirements via NotificationCenter.
/// Publishes updates when servers appear or disappear. ObservableObject for SwiftUI binding.
public final class SyphonDiscovery: ObservableObject {

    private let logCategory = "SyphonDiscovery"

    /// Currently discovered Syphon servers.
    @Published public private(set) var servers: [SyphonServerDescription] = []

    /// Whether Syphon.framework is available on this system.
    @Published public private(set) var isAvailable: Bool = false

    /// The underlying capture source for Syphon input.
    public let captureSource: SyphonCaptureSource

    private var announceObserver: NSObjectProtocol?
    private var retireObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?

    public init() {
        self.captureSource = SyphonCaptureSource()
        self.isAvailable = SyphonFrameworkLoader.shared.isLoaded
    }

    deinit {
        stopMonitoring()
    }

    /// Start monitoring for Syphon server changes.
    public func startMonitoring() {
        guard isAvailable else {
            HDRLogger.info(category: logCategory, "Syphon monitoring not started: framework not available")
            return
        }

        guard captureSource.connect() else {
            HDRLogger.error(category: logCategory, "Failed to connect to Syphon server directory")
            return
        }

        let nc = NotificationCenter.default

        announceObserver = nc.addObserver(
            forName: NSNotification.Name(SyphonNotification.serverAnnounce),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        retireObserver = nc.addObserver(
            forName: NSNotification.Name(SyphonNotification.serverRetire),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        updateObserver = nc.addObserver(
            forName: NSNotification.Name(SyphonNotification.serverUpdate),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()
        HDRLogger.info(category: logCategory, "Syphon server monitoring started")
    }

    /// Stop monitoring for server changes.
    public func stopMonitoring() {
        let nc = NotificationCenter.default
        if let o = announceObserver { nc.removeObserver(o); announceObserver = nil }
        if let o = retireObserver { nc.removeObserver(o); retireObserver = nil }
        if let o = updateObserver { nc.removeObserver(o); updateObserver = nil }

        captureSource.disconnect()
        servers = []
        HDRLogger.info(category: logCategory, "Syphon server monitoring stopped")
    }

    /// Manually refresh the server list.
    public func refresh() {
        captureSource.refreshServerList()
        servers = captureSource.availableServers
    }
}

// MARK: - SyphonInputPanel (SwiftUI View)

/// Inline theme colors for Syphon panel (avoids dependency on HDRUI module's AJATheme).
private enum SyphonTheme {
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let elevatedBackground = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let border = Color(red: 0.25, green: 0.25, blue: 0.28)
    static let accent = Color(red: 0.35, green: 0.55, blue: 0.95)
    static let primaryText = Color(red: 0.92, green: 0.92, blue: 0.94)
    static let secondaryText = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let tertiaryText = Color(red: 0.45, green: 0.45, blue: 0.50)
}

/// SwiftUI panel showing discovered Syphon servers with connect/disconnect controls.
public struct SyphonInputPanel: View {
    @ObservedObject private var discovery: SyphonDiscovery

    public init(discovery: SyphonDiscovery) {
        self._discovery = ObservedObject(wrappedValue: discovery)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if !discovery.isAvailable {
                unavailableMessage
            } else if discovery.servers.isEmpty {
                noServersMessage
            } else {
                serverList
            }
        }
        .padding(12)
        .background(SyphonTheme.panelBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SyphonTheme.border, lineWidth: 1)
        )
        .onAppear {
            discovery.startMonitoring()
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Image(systemName: "rectangle.connected.to.line.below")
                .foregroundColor(SyphonTheme.accent)
            Text("Syphon Input")
                .font(.headline)
                .foregroundColor(SyphonTheme.primaryText)

            Spacer()

            statusIndicator

            Button(action: { discovery.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(SyphonTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Refresh Syphon server list")
            .disabled(!discovery.isAvailable)
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundColor(SyphonTheme.secondaryText)
        }
    }

    private var statusColor: Color {
        if !discovery.isAvailable {
            return .gray
        }
        if discovery.captureSource.isCapturing {
            return .green
        }
        if discovery.captureSource.selectedServer != nil {
            return SyphonTheme.accent
        }
        return .gray
    }

    private var statusText: String {
        if !discovery.isAvailable {
            return "Unavailable"
        }
        if discovery.captureSource.isCapturing {
            return "Capturing"
        }
        if discovery.captureSource.selectedServer != nil {
            return "Connected"
        }
        return "Idle"
    }

    private var unavailableMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Syphon.framework not installed")
                .font(.subheadline)
                .foregroundColor(SyphonTheme.secondaryText)
            Text("Install Syphon from syphon.github.io to enable GPU-level video capture from applications like DaVinci Resolve, Final Cut Pro, and After Effects.")
                .font(.caption)
                .foregroundColor(SyphonTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var noServersMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Syphon servers found")
                .font(.subheadline)
                .foregroundColor(SyphonTheme.secondaryText)
            Text("Start a Syphon-compatible application (DaVinci Resolve, After Effects, etc.) to publish a video output.")
                .font(.caption)
                .foregroundColor(SyphonTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(discovery.servers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: SyphonServerDescription) -> some View {
        let isSelected = discovery.captureSource.selectedServer?.uuid == server.uuid
        let isCapturing = discovery.captureSource.isCapturing && isSelected

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(SyphonTheme.primaryText)
                    .lineLimit(1)
                Text(server.appName)
                    .font(.caption)
                    .foregroundColor(SyphonTheme.tertiaryText)
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(isCapturing ? Color.green : (isSelected ? SyphonTheme.accent : SyphonTheme.border))
                .frame(width: 8, height: 8)

            // Connect / Disconnect button
            Button(action: {
                if isCapturing {
                    discovery.captureSource.stopCapture()
                } else {
                    discovery.captureSource.selectServer(server)
                    _ = discovery.captureSource.startCapture()
                }
            }) {
                Text(isCapturing ? "Disconnect" : "Connect")
                    .font(.caption)
                    .foregroundColor(isCapturing ? .red : SyphonTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isCapturing ? Color.red : SyphonTheme.accent, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? SyphonTheme.elevatedBackground : Color.clear)
        )
    }
}
