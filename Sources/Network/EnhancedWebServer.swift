import Foundation
import Logging
import Common

/// Enhanced web server with support for OFX device connections and advanced APIs
public class EnhancedWebServer {
    public static let shared = EnhancedWebServer()

    private let logCategory = "Network.EnhancedWebServer"

    // Core server components
    private var webServer: EmbeddedWebServer?
    private var webSocketChannel: WebSocketChannel?

    // OFX integration support
    private var ofxDeviceConnections: [String: OFXDeviceConnection] = [:]

    // Server configuration
    public var port: Int = 8080
    public var enableOFXIntegration: Bool = true
    public var enableSecureConnections: Bool = true

    // Performance monitoring
    private var requestCount: Int = 0
    private var lastResetTime: Date = Date()

    private init() {
        HDRLogger.debug(category: logCategory, message: "EnhancedWebServer initialized")
    }

    /// Start the enhanced web server
    /// - Returns: Boolean indicating success or failure
    public func start() -> Bool {
        // Initialize the embedded web server
        let server = EmbeddedWebServer()
        webServer = server

        // Setup the request handler that dispatches to the correct endpoint
        server.setHandler { [weak self] request in
            guard let self = self else { return HTTPResponse.notFound() }
            return self.dispatchRequest(request)
        }

        // Start the server
        guard server.start(port: UInt16(port)) else {
            HDRLogger.error(category: logCategory, message: "Failed to start web server on port \(port)")
            return false
        }

        HDRLogger.info(category: logCategory, message: "Enhanced web server started on port \(port)")
        return true
    }

    /// Stop the enhanced web server
    public func stop() {
        webServer?.stop()
        webServer = nil
        webSocketChannel = nil

        ofxDeviceConnections.removeAll()
        HDRLogger.info(category: logCategory, message: "Enhanced web server stopped")
    }

    /// Add an OFX device connection
    /// - Parameters:
    ///   - deviceID: Unique identifier for the OFX device
    ///   - connection: OFX device connection object
    public func addOFXDeviceConnection(deviceID: String, connection: OFXDeviceConnection) {
        ofxDeviceConnections[deviceID] = connection
        HDRLogger.info(category: logCategory, message: "Added OFX device connection: \(deviceID)")
    }

    /// Remove an OFX device connection
    /// - Parameter deviceID: Unique identifier for the OFX device
    public func removeOFXDeviceConnection(deviceID: String) {
        ofxDeviceConnections.removeValue(forKey: deviceID)
        HDRLogger.info(category: logCategory, message: "Removed OFX device connection: \(deviceID)")
    }

    /// Get list of connected OFX devices
    /// - Returns: Array of device identifiers
    public func getConnectedOFXDevices() -> [String] {
        return Array(ofxDeviceConnections.keys)
    }

    /// Send data to all connected clients
    /// - Parameter data: Data to send
    public func broadcastData(_ data: Data) {
        webSocketChannel?.broadcast(data: data)
    }

    /// Get server statistics
    /// - Returns: Server statistics object
    public func getStatistics() -> WebServerStats {
        let uptime = Date().timeIntervalSince(lastResetTime)
        return WebServerStats(
            requestCount: requestCount,
            uptime: uptime,
            connectedDevices: ofxDeviceConnections.count,
            port: port
        )
    }

    /// Reset server statistics
    public func resetStatistics() {
        requestCount = 0
        lastResetTime = Date()
        HDRLogger.info(category: logCategory, message: "Server statistics reset")
    }

    // MARK: - Private Methods

    /// Central request dispatcher that routes requests based on method and path
    private func dispatchRequest(_ request: HTTPRequest) -> HTTPResponse {
        requestCount += 1

        // OFX endpoints
        if enableOFXIntegration {
            if request.method == "GET" && request.path == "/ofx/devices" {
                return handleOFXDeviceDiscovery(request)
            }
            if request.method == "POST" && request.path.hasPrefix("/ofx/device/") && request.path.hasSuffix("/control") {
                return handleOFXDeviceControl(request)
            }
            if request.method == "GET" && request.path == "/ofx/simulations" {
                return handleOFXSimulationStatus(request)
            }
        }

        // Standard endpoints
        if request.method == "GET" {
            switch request.path {
            case "/health":
                return handleHealthCheck(request)
            case "/stats":
                return handleStatistics(request)
            case "/config":
                return handleConfiguration(request)
            default:
                break
            }
        }

        return HTTPResponse.notFound()
    }

    private func handleOFXDeviceDiscovery(_ request: HTTPRequest) -> HTTPResponse {
        let devices = Array(ofxDeviceConnections.keys)
        let response: [String: Any] = [
            "devices": devices,
            "count": devices.count
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: response))
    }

    private func handleOFXDeviceControl(_ request: HTTPRequest) -> HTTPResponse {
        // This would handle control commands for OFX devices
        let responseBody: [String: Any] = [
            "status": "success",
            "message": "Device control command received"
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: responseBody))
    }

    private func handleOFXSimulationStatus(_ request: HTTPRequest) -> HTTPResponse {
        // This would return status of all active simulations
        let responseBody: [String: Any] = [
            "simulations": [String](),
            "status": "active"
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: responseBody))
    }

    private func handleHealthCheck(_ request: HTTPRequest) -> HTTPResponse {
        let formatter = ISO8601DateFormatter()
        let healthStatus: [String: Any] = [
            "status": "healthy",
            "timestamp": formatter.string(from: Date()),
            "ofx_integration": enableOFXIntegration
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: healthStatus))
    }

    private func handleStatistics(_ request: HTTPRequest) -> HTTPResponse {
        let stats = getStatistics()
        let responseBody: [String: Any] = [
            "request_count": stats.requestCount,
            "uptime": stats.uptime,
            "connected_devices": stats.connectedDevices,
            "port": stats.port
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: responseBody))
    }

    private func handleConfiguration(_ request: HTTPRequest) -> HTTPResponse {
        let config: [String: Any] = [
            "port": port,
            "ofx_integration": enableOFXIntegration,
            "secure_connections": enableSecureConnections
        ]

        return HTTPResponse(statusCode: 200, body: try? JSONSerialization.data(withJSONObject: config))
    }
}

/// Web server statistics
public struct WebServerStats {
    public let requestCount: Int
    public let uptime: TimeInterval
    public let connectedDevices: Int
    public let port: Int

    public init(requestCount: Int, uptime: TimeInterval, connectedDevices: Int, port: Int) {
        self.requestCount = requestCount
        self.uptime = uptime
        self.connectedDevices = connectedDevices
        self.port = port
    }
}

/// OFX device connection wrapper
public class OFXDeviceConnection {
    public let deviceID: String
    public let deviceType: String
    public let status: DeviceStatus
    public let lastActive: Date

    public init(deviceID: String, deviceType: String) {
        self.deviceID = deviceID
        self.deviceType = deviceType
        self.status = .connected
        self.lastActive = Date()
    }
}

/// Device status enumeration
public enum DeviceStatus: String, CaseIterable {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case error = "Error"
    case initializing = "Initializing"
}