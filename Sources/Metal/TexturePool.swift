import Foundation
import Metal
import Logging
import Common

/// MT-003: Texture pool — reuse MTLTexture by width, height, and pixel format.
/// Call `getTexture(width:height:format:)` to obtain a texture; call `returnTexture(_:)` when done.
public final class TexturePool {
    public struct Key: Hashable {
        public let width: Int
        public let height: Int
        public let pixelFormat: MTLPixelFormat

        public init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
        }
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var available: [Key: [MTLTexture]]
    /// MT-011: Max textures to cache per (width, height, format). Reduced under memory pressure.
    private var maxCachedPerKey: Int
    private let logCategory = "Metal.TexturePool"

    /// Default max cached textures per key when memory pressure is normal.
    public static let defaultMaxCachedPerKey = 8

    public init(device: MTLDevice, maxCachedPerKey: Int = defaultMaxCachedPerKey) {
        self.device = device
        self.available = [:]
        self.maxCachedPerKey = max(0, maxCachedPerKey)
    }

    /// MT-011: Set max cached textures per key (e.g. under memory pressure). Use 0 to avoid caching; restore to default when pressure is normal.
    public func setMaxCachedPerKey(_ value: Int) {
        lock.lock()
        maxCachedPerKey = max(0, value)
        lock.unlock()
    }

    /// MT-011: Trim each key's list to at most maxCachedPerKey entries (drops excess).
    public func trimToMax() {
        lock.lock()
        for (key, list) in available {
            if list.count > maxCachedPerKey {
                let keep = list.suffix(maxCachedPerKey)
                available[key] = Array(keep)
            }
        }
        lock.unlock()
    }

    /// Get a texture of the given dimensions and format. Creates a new one if none in pool.
    public func getTexture(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        let key = Key(width: width, height: height, pixelFormat: format)
        lock.lock()
        if var list = available[key], !list.isEmpty {
            let tex = list.removeLast()
            available[key] = list.isEmpty ? nil : list
            lock.unlock()
            return tex
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor()
        descriptor.width = width
        descriptor.height = height
        descriptor.pixelFormat = format
        descriptor.usage = usage
        descriptor.storageMode = .shared
        descriptor.textureType = .type2D

        return device.makeTexture(descriptor: descriptor)
    }

    /// Return a texture to the pool for reuse. Only textures created by this pool (or matching key) should be returned.
    /// MT-011: Drops texture if pool for this key already has maxCachedPerKey entries.
    public func returnTexture(_ texture: MTLTexture) {
        let key = Key(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
        lock.lock()
        var list = available[key] ?? []
        if list.count < maxCachedPerKey {
            list.append(texture)
            available[key] = list
        }
        lock.unlock()
    }

    /// Remove all pooled textures (e.g. on format change or shutdown).
    public func removeAll() {
        lock.lock()
        available.removeAll()
        lock.unlock()
    }
}
