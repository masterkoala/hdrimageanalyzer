// Embedded HTTP server (Phase 9, NET-004). Raw HTTP via BSD sockets — no Vapor dependency.
// Uses Darwin sockets to avoid module name clash with target "Network".

import Foundation
import Logging
import Common

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - HTTP types

/// Minimal HTTP request parsed from the first line and headers (and optional body).
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: String?
    public let headers: [String: String]
    /// Request body when Content-Length was present; nil otherwise.
    public let body: Data?
}

/// Response to send back (status + optional body; Content-Length set automatically).
public struct HTTPResponse {
    public let statusCode: Int
    public let body: Data?
    public let contentType: String?
    /// Optional extra headers (e.g. Set-Cookie). Keys are header names; values are raw header values.
    public let headers: [String: String]?
    /// When set, response is a WebSocket upgrade (101); server must not close the connection after sending.
    public let webSocketAccept: String?

    public init(statusCode: Int, body: Data? = nil, contentType: String? = nil, headers: [String: String]? = nil, webSocketAccept: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
        self.headers = headers
        self.webSocketAccept = webSocketAccept
    }

    public static func ok(_ body: Data? = nil, contentType: String? = "text/plain", headers: [String: String]? = nil) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: body, contentType: contentType, headers: headers)
    }

    public static func ok(html: String, headers: [String: String]? = nil) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: html.data(using: .utf8), contentType: "text/html; charset=utf-8", headers: headers)
    }

    public static func ok(text: String, headers: [String: String]? = nil) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: text.data(using: .utf8), contentType: "text/plain; charset=utf-8", headers: headers)
    }

    public static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, body: "Not Found".data(using: .utf8), contentType: "text/plain; charset=utf-8")
    }

    public static func unauthorized(body: Data? = nil, contentType: String? = "application/json; charset=utf-8") -> HTTPResponse {
        HTTPResponse(statusCode: 401, body: body ?? "{\"error\":\"Unauthorized\"}".data(using: .utf8), contentType: contentType)
    }

    public static func serverError(_ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: 500, body: message.data(using: .utf8), contentType: "text/plain; charset=utf-8")
    }

    /// WebSocket upgrade (101 Switching Protocols). Connection must remain open after sending.
    public static func webSocketUpgrade(acceptKey: String) -> HTTPResponse {
        HTTPResponse(statusCode: 101, body: nil, contentType: nil, headers: nil, webSocketAccept: acceptKey)
    }
}

/// Handler for incoming HTTP requests. Return the response to send. Called on a background queue.
public typealias HTTPRequestHandler = (HTTPRequest) -> HTTPResponse

// MARK: - Embedded Web Server

/// Lightweight HTTP server using BSD TCP sockets. Listens on a port and invokes a handler per request.
public final class EmbeddedWebServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HDRImageAnalyzerPro.EmbeddedWebServer", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    private var listenSocket: Int32 = -1
    private var port: UInt16 = 0
    private var handler: HTTPRequestHandler?
    private let lock = NSLock()
    private var _isRunning = false

    public init() {}

    deinit {
        stop()
    }

    /// Set the request handler (optional). If nil, / and /health return 200 OK.
    public func setHandler(_ handler: HTTPRequestHandler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// When the handler returns a WebSocket upgrade (101), this callback is invoked with the client FD; server does not close it.
    public var onWebSocketUpgrade: ((Int32) -> Void)?

    /// Start listening on the given port. Returns true if bound successfully.
    public func start(port: UInt16 = 8765) -> Bool {
        var bound = false
        queue.sync {
            lock.lock()
            guard !_isRunning else {
                lock.unlock()
                HDRLogger.info(category: "Network", "Web server already running on port \(self.port)")
                return
            }
            lock.unlock()

            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                HDRLogger.error(category: "Network", "Web server socket() failed")
                return
            }
            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
#if canImport(Darwin)
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
#endif
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindResult == 0 else {
                HDRLogger.error(category: "Network", "Web server bind failed on port \(port)")
                Darwin.close(fd)
                return
            }
            guard Darwin.listen(fd, 64) == 0 else {
                HDRLogger.error(category: "Network", "Web server listen failed")
                Darwin.close(fd)
                return
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnections(listenFD: fd)
            }
            source.setCancelHandler {
                Darwin.close(fd)
            }
            source.resume()

            lock.lock()
            listenSocket = fd
            acceptSource = source
            self.port = port
            _isRunning = true
            bound = true
            lock.unlock()
            HDRLogger.info(category: "Network", "Web server listening on port \(port)")
        }
        return bound
    }

    /// Stop the server.
    public func stop() {
        queue.sync {
            lock.lock()
            let source = acceptSource
            acceptSource = nil
            listenSocket = -1
            port = 0
            _isRunning = false
            lock.unlock()
            source?.cancel()
            HDRLogger.info(category: "Network", "Web server stopped")
        }
    }

    /// Currently bound port; 0 if not running.
    public var boundPort: UInt16 {
        lock.lock()
        let p = port
        lock.unlock()
        return p
    }

    /// Whether the server is running.
    public var isRunning: Bool {
        lock.lock()
        let r = _isRunning
        lock.unlock()
        return r
    }

    // MARK: - Accept loop

    private func acceptConnections(listenFD: Int32) {
        repeat {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &len) }
            }
            guard clientFD >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                return
            }
            queue.async { [weak self] in
                self?.handleConnection(clientFD: clientFD)
            }
        } while true
    }

    private func handleConnection(clientFD: Int32) {
        var buffer = Data()
        let chunkSize = 4096
        var buf = [UInt8](repeating: 0, count: chunkSize)
        repeat {
            let n = Darwin.read(clientFD, &buf, chunkSize)
            guard n > 0 else { Darwin.close(clientFD); return }
            buffer.append(contentsOf: buf.prefix(n))
            if let request = parseRequest(from: &buffer) {
                let response = dispatch(request)
                if response.statusCode == 101, response.webSocketAccept != nil {
                    sendResponse(response, clientFD: clientFD)
                    lock.lock()
                    let callback = onWebSocketUpgrade
                    lock.unlock()
                    callback?(clientFD)
                    return
                }
                sendResponse(response, clientFD: clientFD)
                Darwin.close(clientFD)
                return
            }
            if n < chunkSize { break }
        } while true
        Darwin.close(clientFD)
    }

    private func parseRequest(from buffer: inout Data) -> HTTPRequest? {
        guard let doubleNewline = buffer.range(of: "\r\n\r\n".data(using: .utf8)!)
            ?? buffer.range(of: "\n\n".data(using: .utf8)!) else { return nil }
        let headEnd = doubleNewline.upperBound
        let headData = buffer.prefix(upTo: doubleNewline.lowerBound)
        guard let raw = String(data: headData, encoding: .utf8) else { return nil }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let pathAndQuery = String(requestLine[1])
        let path: String
        let query: String?
        if let q = pathAndQuery.firstIndex(of: "?") {
            path = String(pathAndQuery[..<q])
            query = String(pathAndQuery[pathAndQuery.index(after: q)...])
        } else {
            path = pathAndQuery
            query = nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body: Data? = nil
        if let lenStr = headers["content-length"], let contentLength = Int(lenStr), contentLength >= 0 {
            let bodyStart = headEnd
            let totalNeeded = bodyStart + contentLength
            if buffer.count < totalNeeded {
                return nil
            }
            body = buffer.subdata(in: bodyStart..<totalNeeded)
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func dispatch(_ request: HTTPRequest) -> HTTPResponse {
        lock.lock()
        let handler = handler
        lock.unlock()
        if let handler = handler {
            return handler(request)
        }
        if request.path == "/" || request.path == "/health" {
            return .ok(text: "OK")
        }
        return .notFound()
    }

    private func sendResponse(_ response: HTTPResponse, clientFD: Int32) {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        if response.statusCode == 101, let acceptKey = response.webSocketAccept {
            let headerLines = "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
            let data = (statusLine + headerLines).data(using: .utf8)!
            _ = data.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, data.count) }
            return
        }
        let body = response.body ?? Data()
        let contentType = response.contentType ?? "text/plain; charset=utf-8"
        var headerLines = "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let extra = response.headers {
            for (name, value) in extra {
                headerLines += "\(name): \(value)\r\n"
            }
        }
        headerLines += "\r\n"
        var data = (statusLine + headerLines).data(using: .utf8)!
        data.append(body)
        _ = data.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, data.count) }
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
