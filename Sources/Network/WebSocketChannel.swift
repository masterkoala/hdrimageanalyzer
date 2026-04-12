// WebSocket real-time control channel (Phase 9, NET-009). RFC 6455.
// Handshake accept key, frame parse/send, multi-client broadcast.

import Foundation
import Logging
import Common

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - WebSocket accept key (RFC 6455)

private let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC11B07"

/// Compute Sec-WebSocket-Accept from the client's Sec-WebSocket-Key header value.
public func webSocketAcceptKey(from clientKey: String) -> String? {
    let input = (clientKey.trimmingCharacters(in: .whitespaces) + webSocketGUID)
    guard let data = input.data(using: .utf8) else { return nil }
#if canImport(CryptoKit)
    let hash = Insecure.SHA1.hash(data: data)
    return Data(hash).base64EncodedString()
#else
    return nil
#endif
}

// MARK: - WebSocket frame (RFC 6455)

private enum WSOpcode: UInt8 {
    case continuation = 0
    case text = 1
    case binary = 2
    case close = 8
    case ping = 9
    case pong = 10
}

/// Parses one WebSocket frame from the front of `buffer`. Returns (opcode, payload) and consumes bytes; returns nil if frame incomplete.
private func parseWebSocketFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
    guard buffer.count >= 2 else { return nil }
    let first = buffer[buffer.startIndex]
    let second = buffer[buffer.startIndex + 1]
    let opcode = first & 0x0F
    let masked = (second & 0x80) != 0
    var payloadLen = Int(second & 0x7F)
    var headSize = 2
    if payloadLen == 126 {
        guard buffer.count >= 4 else { return nil }
        payloadLen = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
        headSize = 4
    } else if payloadLen == 127 {
        guard buffer.count >= 10 else { return nil }
        payloadLen = 0
        for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(buffer[buffer.startIndex + 2 + i]) }
        headSize = 10
    }
    let maskKeySize = masked ? 4 : 0
    guard buffer.count >= headSize + maskKeySize + payloadLen else { return nil }
    let payloadStart = buffer.startIndex + headSize + maskKeySize
    var payload = buffer.subdata(in: payloadStart..<(payloadStart + payloadLen))
    if masked {
        let keyStart = buffer.startIndex + headSize
        for i in 0..<payload.count {
            payload[i] ^= buffer[keyStart + (i % 4)]
        }
    }
    buffer.removeFirst(headSize + maskKeySize + payloadLen)
    return (opcode, payload)
}

/// Build a WebSocket text frame (server→client, no mask).
private func makeWebSocketTextFrame(_ text: String) -> Data? {
    guard let payload = text.data(using: .utf8) else { return nil }
    return makeWebSocketFrame(opcode: WSOpcode.text.rawValue, payload: payload)
}

private func makeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
    var header = [UInt8](repeating: 0, count: 14)
    header[0] = 0x80 | opcode
    var headLen = 2
    if payload.count < 126 {
        header[1] = UInt8(payload.count)
    } else if payload.count <= 65535 {
        header[1] = 126
        header[2] = UInt8(payload.count >> 8)
        header[3] = UInt8(payload.count & 0xFF)
        headLen = 4
    } else {
        header[1] = 127
        var n = payload.count
        for i in (0..<8).reversed() {
            header[2 + i] = UInt8(n & 0xFF)
            n >>= 8
        }
        headLen = 10
    }
    var data = Data(header.prefix(headLen))
    data.append(payload)
    return data
}

// MARK: - WebSocket connection handler

private final class WebSocketConnection: @unchecked Sendable {
    let fd: Int32
    let queue: DispatchQueue
    private var buffer = Data()
    private let onText: (String) -> Void
    private let onClose: (WebSocketConnection) -> Void

    init(fd: Int32, queue: DispatchQueue, onText: @escaping (String) -> Void, onClose: @escaping (WebSocketConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.onText = onText
        self.onClose = onClose
    }

    func send(text: String) {
        guard let frame = makeWebSocketTextFrame(text) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = frame.withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, frame.count) }
        }
    }

    func send(data: Data) {
        let frame = makeWebSocketFrame(opcode: WSOpcode.text.rawValue, payload: data)
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = frame.withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, frame.count) }
        }
    }

    func close() {
        let frame = makeWebSocketFrame(opcode: WSOpcode.close.rawValue, payload: Data())
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, frame.count) }
        Darwin.close(fd)
        onClose(self)
    }

    func readMore(_ newData: Data) {
        buffer.append(newData)
        while let (opcode, payload) = parseWebSocketFrame(from: &buffer) {
            switch opcode {
            case WSOpcode.text.rawValue:
                if let s = String(data: payload, encoding: .utf8) { onText(s) }
            case WSOpcode.binary.rawValue:
                if let s = String(data: payload, encoding: .utf8) { onText(s) }
            case WSOpcode.close.rawValue:
                close()
                return
            case WSOpcode.ping.rawValue:
                let pong = makeWebSocketFrame(opcode: WSOpcode.pong.rawValue, payload: payload)
                _ = pong.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, pong.count) }
            default:
                break
            }
        }
    }
}

// MARK: - WebSocket channel (multi-client)

/// Real-time WebSocket control channel. Accepts connections on upgrade, parses frames, and invokes message callback; supports broadcast.
public final class WebSocketChannel: @unchecked Sendable {
    public static let shared = WebSocketChannel()
    private let queue = DispatchQueue(label: "HDRImageAnalyzerPro.WebSocketChannel", qos: .userInitiated)
    private var connections: [Int32: WebSocketConnection] = [:]
    private var readSource: [Int32: DispatchSourceRead] = [:]
    private let lock = NSLock()

    /// Called when a text (or binary decoded as UTF-8) message is received. Set by app for control handling.
    public var onMessage: ((String) -> Void)?

    public init() {}

    /// Add a client connection (fd ownership transferred). Called after HTTP 101 upgrade.
    public func addConnection(_ clientFD: Int32) {
        queue.async { [weak self] in
            guard let self = self else { Darwin.close(clientFD); return }
#if canImport(Darwin)
            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)
#endif
            let conn = WebSocketConnection(fd: clientFD, queue: self.queue, onText: { [weak self] text in
                self?.lock.lock()
                let callback = self?.onMessage
                self?.lock.unlock()
                callback?(text)
            }, onClose: { [weak self] conn in
                self?.removeConnection(conn.fd)
            })
            self.lock.lock()
            self.connections[clientFD] = conn
            self.lock.unlock()
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: self.queue)
            source.setEventHandler { [weak conn] in
                guard let conn = conn else { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(clientFD, &buf, 4096)
                guard n > 0 else {
                    conn.close()
                    return
                }
                conn.readMore(Data(buf.prefix(n)))
            }
            source.setCancelHandler {
                Darwin.close(clientFD)
            }
            self.lock.lock()
            self.readSource[clientFD] = source
            self.lock.unlock()
            source.resume()
            HDRLogger.info(category: "Network", "WebSocket client connected (fd \(clientFD))")
        }
    }

    private func removeConnection(_ fd: Int32) {
        lock.lock()
        readSource[fd]?.cancel()
        readSource.removeValue(forKey: fd)
        connections.removeValue(forKey: fd)
        lock.unlock()
        HDRLogger.info(category: "Network", "WebSocket client disconnected (fd \(fd))")
    }

    /// Send a text message to all connected clients.
    public func broadcast(text: String) {
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.send(text: text) }
    }

    /// Send raw JSON data to all connected clients.
    public func broadcast(data: Data) {
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.send(data: data) }
    }

    /// Number of connected clients.
    public var clientCount: Int {
        lock.lock()
        let n = connections.count
        lock.unlock()
        return n
    }
}
