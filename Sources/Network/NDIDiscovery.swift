import Foundation
import Logging
import Common

// MARK: - NDI source discovery (Phase 9, NET-001)
// Uses NDI SDK via dynamic loading so the app builds without vendoring the SDK.
// NDI runtime can be installed to /usr/local/lib or via NDI installer.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Raw function pointers for NDI find API (resolved via dlsym). Cast at call site to avoid @convention(c) ObjC representability.
private struct NDIFuncs {
    var initialize: UnsafeMutableRawPointer?
    var destroy: UnsafeMutableRawPointer?
    var find_create_v2: UnsafeMutableRawPointer?
    var find_destroy: UnsafeMutableRawPointer?
    var find_get_current_sources: UnsafeMutableRawPointer?
}

/// Discovers NDI sources on the network using the NDI SDK (dynamically loaded).
public final class NDIDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HDRImageAnalyzerPro.NDIDiscovery", qos: .userInitiated)
    private var findInstance: OpaquePointer?
    private var ndiLibHandle: UnsafeMutableRawPointer?
    private var ndiFuncs: NDIFuncs?
    private var isFinding = false
    private weak var delegate: NDIDiscoveryDelegate?
    private var notifySources: (([NDISourceInfo]) -> Void)?

    public init() {}

    deinit {
        stopFinding()
        unloadNDI()
    }

    /// Set delegate for source updates (called on the discovery queue).
    public func setDelegate(_ delegate: NDIDiscoveryDelegate?) {
        queue.async { [weak self] in
            self?.delegate = delegate
        }
    }

    /// Optional callback for source updates (alternative to delegate).
    public func setSourcesCallback(_ callback: (([NDISourceInfo]) -> Void)?) {
        queue.async { [weak self] in
            self?.notifySources = callback
        }
    }

    /// Start discovering NDI sources. Safe to call multiple times; no-op if already finding.
    public func startFinding() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isFinding { return }
            if self.loadNDI(), self.initializeFind() {
                self.isFinding = true
                HDRLogger.info(category: "Network", "NDI discovery started")
                self.pollSourcesOnce()
            } else {
                HDRLogger.info(category: "Network", "NDI discovery not available (SDK not loaded)")
            }
        }
    }

    /// Stop discovering. Safe to call when not finding.
    public func stopFinding() {
        queue.sync {
            guard isFinding else { return }
            destroyFind()
            isFinding = false
            HDRLogger.info(category: "Network", "NDI discovery stopped")
        }
    }

    /// Current list of discovered sources. Returns empty if NDI SDK not loaded or discovery not started.
    public func currentSources() -> [NDISourceInfo] {
        queue.sync { getCurrentSourcesLocked() }
    }

    /// Refresh sources once and notify delegate/callback. Call from discovery queue.
    private func pollSourcesOnce() {
        let sources = getCurrentSourcesLocked()
        if let delegate = delegate {
            delegate.ndiDiscovery(self, didUpdateSources: sources)
        }
        notifySources?(sources)
    }

    private func getCurrentSourcesLocked() -> [NDISourceInfo] {
        guard let f = ndiFuncs, let pGetSources = f.find_get_current_sources, let instance = findInstance else { return [] }
        typealias GetSourcesFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?) -> UnsafeRawPointer?
        let getSources = unsafeBitCast(pGetSources, to: GetSourcesFn.self)
        var count: UInt32 = 0
        guard let sourcesPtr = getSources(instance, &count), count > 0 else { return [] }
        let ptr = sourcesPtr.assumingMemoryBound(to: NDIlib_source_t.self)
        let buffer = UnsafeBufferPointer<NDIlib_source_t>(start: ptr, count: Int(count))
        return buffer.map { s -> NDISourceInfo in
            let name = s.p_ndi_name.map { String(cString: $0) } ?? ""
            let url = s.p_url_address.map { String(cString: $0) } ?? ""
            return NDISourceInfo(name: name, urlAddress: url)
        }
    }

    // MARK: - NDI dynamic loading

    private static let libNames = [
        "libndi.dylib",
        "libndi.5.dylib",
        "libndi.4.dylib",
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi.dylib",
    ]

    private func loadNDI() -> Bool {
        if ndiFuncs != nil { return true }
        for name in Self.libNames {
            let handle = dlopen(name, RTLD_NOW)
            guard let handle = handle else { continue }
            guard let pInit = dlsym(handle, "NDIlib_initialize"),
                  let pDestroy = dlsym(handle, "NDIlib_destroy"),
                  let pFindCreate = dlsym(handle, "NDIlib_find_create_v2"),
                  let pFindDestroy = dlsym(handle, "NDIlib_find_destroy"),
                  let pGetSources = dlsym(handle, "NDIlib_find_get_current_sources") else {
                dlclose(handle)
                continue
            }
            var f = NDIFuncs()
            f.initialize = pInit
            f.destroy = pDestroy
            f.find_create_v2 = pFindCreate
            f.find_destroy = pFindDestroy
            f.find_get_current_sources = pGetSources
            ndiLibHandle = handle
            ndiFuncs = f
            return true
        }
        return false
    }

    private func unloadNDI() {
        if findInstance != nil { destroyFind() }
        if let h = ndiLibHandle {
            dlclose(h)
            ndiLibHandle = nil
        }
        ndiFuncs = nil
    }

    private func initializeFind() -> Bool {
        guard let f = ndiFuncs, let pInit = f.initialize, let pCreate = f.find_create_v2 else { return false }
        typealias InitFn = @convention(c) () -> Bool
        typealias FindCreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        if !unsafeBitCast(pInit, to: InitFn.self)() { return false }
        var options = NDIlib_find_create_t()
        findInstance = withUnsafePointer(to: &options) { unsafeBitCast(pCreate, to: FindCreateFn.self)($0) }
        return findInstance != nil
    }

    private func destroyFind() {
        guard let f = ndiFuncs, let instance = findInstance else { return }
        if let pFindDestroy = f.find_destroy {
            typealias FindDestroyFn = @convention(c) (OpaquePointer?) -> Void
            unsafeBitCast(pFindDestroy, to: FindDestroyFn.self)(instance)
        }
        if let pDestroy = f.destroy {
            typealias DestroyFn = @convention(c) () -> Void
            unsafeBitCast(pDestroy, to: DestroyFn.self)()
        }
        findInstance = nil
    }
}

// MARK: - NDI C ABI types (minimal for find/sources)

private struct NDIlib_find_create_t {
    var show_local_sources: Bool = false
    var p_groups: UnsafePointer<CChar>?
    var p_extra_ips: UnsafePointer<CChar>?
}

private struct NDIlib_source_t {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_url_address: UnsafePointer<CChar>?
}
