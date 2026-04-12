// Bonjour/mDNS service advertisement (Phase 9, NET-008).
// Advertises the embedded HTTP server so clients can discover it on the local network.

import Foundation
import Logging
import Common

/// Bonjour/mDNS publisher for the embedded web server. Uses Foundation.NetService (_http._tcp).
public final class BonjourService: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var netService: NetService?
    private var isPublished = false

    public override init() {
        super.init()
    }

    deinit {
        stop()
    }

    /// Service type for HTTP (standard Bonjour type).
    public static let httpServiceType = "_http._tcp"
    /// Default service name shown in Finder/Safari and other mDNS browsers.
    public static let defaultServiceName = "HDR Image Analyzer Pro"

    /// Start advertising the service on the given port. Name is the display name for mDNS.
    /// Call from any thread; NetService is published on the main run loop.
    public func start(port: UInt32, name: String = defaultServiceName) {
        lock.lock()
        if isPublished, let svc = netService {
            let samePort = svc.port == Int32(port)
            lock.unlock()
            if samePort { return }
            stop()
            start(port: port, name: name)
            return
        }
        lock.unlock()
        let service = NetService(domain: "", type: Self.httpServiceType, name: name, port: Int32(port))
        service.includesPeerToPeer = true
        service.delegate = self
        if Thread.isMainThread {
            service.publish(options: [])
        } else {
            DispatchQueue.main.async {
                service.publish(options: [])
            }
        }
        lock.lock()
        netService = service
        lock.unlock()
        HDRLogger.info(category: "Network", "Bonjour publishing '\(name)' _http._tcp port \(port)")
    }

    /// Stop advertising. Safe to call from any thread and when not published.
    public func stop() {
        lock.lock()
        let service = netService
        netService = nil
        isPublished = false
        lock.unlock()
        guard let svc = service else { return }
        if Thread.isMainThread {
            svc.stop()
        } else {
            DispatchQueue.main.async {
                svc.stop()
            }
        }
        svc.delegate = nil
        HDRLogger.info(category: "Network", "Bonjour stopped")
    }

    /// Whether the service is currently published (or in progress).
    public var isRunning: Bool {
        lock.lock()
        let has = netService != nil
        lock.unlock()
        return has
    }
}

// MARK: - NetServiceDelegate

extension BonjourService: NetServiceDelegate {
    public func netServiceDidPublish(_ sender: NetService) {
        lock.lock()
        isPublished = true
        lock.unlock()
        HDRLogger.info(category: "Network", "Bonjour published: \(sender.name) _http._tcp port \(sender.port)")
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        lock.lock()
        netService = nil
        isPublished = false
        lock.unlock()
        let msg = errorDict.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        HDRLogger.error(category: "Network", "Bonjour did not publish: \(msg)")
    }

    public func netServiceDidStop(_ sender: NetService) {
        lock.lock()
        if netService === sender {
            netService = nil
            isPublished = false
        }
        lock.unlock()
    }
}
