import Foundation
import Metal
import CoreVideo
import Logging
import Common

/// DL-005: Zero-copy CVPixelBuffer → MTLTexture via CVMetalTextureCache (IOSurface-backed pixel buffers map directly to Metal textures).
/// Create one cache per MTLDevice; call `texture(from:)` per frame. Texture is valid until next call or cache flush.
public final class CVPixelBufferTextureCache {
    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private let logCategory = "Metal.CVPixelBufferTextureCache"

    public init(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        let err = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        if err != kCVReturnSuccess {
            HDRLogger.error(category: logCategory, "CVMetalTextureCacheCreate failed: \(err)")
        }
        self.cache = cache
    }

    /// Returns an MTLTexture wrapping the CVPixelBuffer's IOSurface (zero-copy when buffer is IOSurface-backed). Returns nil on unsupported format or cache failure.
    /// Caller must use the texture before the next call to this method or before flushing the cache.
    public func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let mtlFormat: MTLPixelFormat
        switch format {
        case kCVPixelFormatType_32BGRA:
            mtlFormat = .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            mtlFormat = .rgba16Float
        case kCVPixelFormatType_422YpCbCr8:
            mtlFormat = .r8Unorm
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            mtlFormat = .r8Unorm
        default:
            HDRLogger.debug(category: logCategory, "Unsupported CVPixelBuffer format: \(format)")
            return nil
        }

        var cvTexture: CVMetalTexture?
        let err = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &cvTexture
        )
        if err != kCVReturnSuccess {
            HDRLogger.error(category: logCategory, "CVMetalTextureCacheCreateTextureFromImage failed: \(err)")
            return nil
        }
        guard let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Flush the cache (e.g. on format change or teardown).
    public func flush() {
        cache.map { CVMetalTextureCacheFlush($0, 0) }
    }
}
