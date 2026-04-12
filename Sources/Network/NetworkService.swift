import Foundation
import Logging
import Common

/// Network/NDI (Phase 9, NET-001, NET-002), embedded web server (NET-004), Bonjour/mDNS (NET-008).
public enum NetworkService {
    /// Shared NDI discovery instance for source enumeration.
    public static let ndiDiscovery = NDIDiscovery()
    /// Shared NDI video receiver for receive/decode pipeline.
    public static let ndiVideoReceiver = NDIVideoReceiver()
    /// Embedded HTTP server for remote control / Web UI (NET-004).
    public static let webServer = EmbeddedWebServer()
    /// Bonjour/mDNS advertiser for web server discovery (NET-008).
    public static let bonjourService = BonjourService()

    public static func register() {
        HDRLogger.info(category: "Network", "NetworkService registered")
    }

    // MARK: - Embedded web server (NET-004)

    /// Start the embedded web server on the given port (default 8765). Returns true if bound successfully.
    /// When successful, also starts Bonjour/mDNS advertisement (NET-008) so the service is discoverable on the local network.
    public static func startWebServer(port: UInt16 = 8765) -> Bool {
        let ok = webServer.start(port: port)
        if ok {
            bonjourService.start(port: UInt32(webServer.boundPort), name: BonjourService.defaultServiceName)
        }
        return ok
    }

    /// Stop the embedded web server and Bonjour advertisement.
    public static func stopWebServer() {
        bonjourService.stop()
        webServer.stop()
    }

    /// Set a custom request handler for the web server. If unset, / and /health return 200 OK.
    /// Also configures WebSocket upgrade callback (NET-009) so GET /ws hands off to WebSocketChannel.
    public static func setWebServerHandler(_ handler: HTTPRequestHandler?) {
        webServer.setHandler(handler)
        webServer.onWebSocketUpgrade = { WebSocketChannel.shared.addConnection($0) }
    }

    /// Start NDI source discovery. Safe to call when NDI SDK is not installed (no-op).
    public static func startNDIDiscovery() {
        ndiDiscovery.startFinding()
    }

    /// Stop NDI source discovery.
    public static func stopNDIDiscovery() {
        ndiDiscovery.stopFinding()
    }

    /// Currently discovered NDI sources. Empty if discovery not started or SDK not loaded.
    public static func currentNDISources() -> [NDISourceInfo] {
        ndiDiscovery.currentSources()
    }

    // MARK: - NDI video receive (NET-002)

    /// Connect NDI receiver to a source. Use after discovery; safe when SDK not loaded.
    public static func connectToNDISource(_ source: NDISourceInfo) {
        ndiVideoReceiver.connect(to: source)
    }

    /// Disconnect NDI receiver.
    public static func disconnectNDI() {
        ndiVideoReceiver.disconnect()
    }

    /// Capture one NDI video frame (timeout in ms). Returns nil if not connected or no frame.
    public static func captureNDIVideoFrame(timeoutMs: UInt32 = 1000) -> NDIVideoFrame? {
        ndiVideoReceiver.captureVideoFrame(timeoutMs: timeoutMs)
    }

    /// Set delegate for NDI video frames (e.g. to feed Metal pipeline via submitFrame).
    public static func setNDIVideoReceiverDelegate(_ delegate: NDIVideoReceiverDelegate?) {
        ndiVideoReceiver.setDelegate(delegate)
    }

    // MARK: - NDI audio receive (NET-003)

    /// Capture one NDI audio frame (multi-channel planar float32). Returns nil if not connected or no frame.
    public static func captureNDIAudioFrame(timeoutMs: UInt32 = 1000) -> NDIAudioFrame? {
        ndiVideoReceiver.captureAudioFrame(timeoutMs: timeoutMs)
    }

    /// Set delegate for NDI audio frames (e.g. for metering or Phase 5 Audio DSP).
    public static func setNDIAudioReceiverDelegate(_ delegate: NDIAudioReceiverDelegate?) {
        ndiVideoReceiver.setAudioDelegate(delegate)
    }

    /// Start background loop that captures NDI audio and delivers to the audio delegate.
    public static func startNDIAudioReceiveLoop(timeoutMs: UInt32 = 100) {
        ndiVideoReceiver.startAudioReceiveLoop(timeoutMs: timeoutMs)
    }

    /// Stop the NDI audio receive loop.
    public static func stopNDIAudioReceiveLoop() {
        ndiVideoReceiver.stopAudioReceiveLoop()
    }
}
