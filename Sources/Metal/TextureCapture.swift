// MT-013: Screenshot capture from MTLTexture — copy to CPU (blit to shared buffer), CGImage/NSImage, save PNG/JPEG or pasteboard.

import Foundation
import Metal
import CoreGraphics
import ImageIO
import AppKit
import Logging
import Common

/// Output format for saving screenshots.
public enum ScreenshotFormat: String {
    case png = "png"
    case jpeg = "jpeg"
}

/// MT-013: Captures a screenshot from an MTLTexture (e.g. current display or scope texture).
/// Copies texture to CPU via blit to shared buffer, then creates CGImage for save/pasteboard.
public enum TextureCapture {

    private static let logCategory = "Metal.TextureCapture"

    /// Capture a 2D texture to a CGImage. Supports .bgra8Unorm and .rgba32Float (converted to 8-bit).
    /// Uses blit to shared buffer so it works with private or shared textures.
    /// - Parameters:
    ///   - device: MTLDevice used to create a command queue and buffer.
    ///   - commandQueue: Queue used for the blit (will commit and wait).
    ///   - texture: Source 2D texture (bgra8Unorm or rgba32Float).
    /// - Returns: CGImage or nil on failure.
    public static func captureScreenshot(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        texture: MTLTexture
    ) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0, texture.depth == 1 else {
            HDRLogger.error(category: logCategory, "captureScreenshot: invalid texture dimensions or depth")
            return nil
        }

        switch texture.pixelFormat {
        case .bgra8Unorm:
            return captureBGRAToImage(device: device, commandQueue: commandQueue, texture: texture, width: width, height: height)
        case .rgba32Float:
            return captureFloatToImage(device: device, commandQueue: commandQueue, texture: texture, width: width, height: height)
        default:
            HDRLogger.error(category: logCategory, "captureScreenshot: unsupported pixel format \(texture.pixelFormat.rawValue); use bgra8Unorm or rgba32Float")
            return nil
        }
    }

    /// Copy texture to shared buffer via blit, then build CGImage from BGRA bytes.
    private static func captureBGRAToImage(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        texture: MTLTexture,
        width: Int,
        height: Int
    ) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bufferLength = bytesPerRow * height

        guard let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else {
            HDRLogger.error(category: logCategory, "captureScreenshot: failed to create buffer or blit encoder")
            return nil
        }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferLength
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else {
            HDRLogger.error(category: logCategory, "captureScreenshot: blit command buffer status \(cmdBuf.status.rawValue)")
            return nil
        }

        return makeCGImageFromBGRA(buffer: buffer.contents(), width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// Copy rgba32Float texture to shared buffer, convert to 8-bit on CPU, then build CGImage.
    private static func captureFloatToImage(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        texture: MTLTexture,
        width: Int,
        height: Int
    ) -> CGImage? {
        let bytesPerPixel = 16 // 4 floats
        let bytesPerRow = width * bytesPerPixel
        let bufferLength = bytesPerRow * height

        guard let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else {
            HDRLogger.error(category: logCategory, "captureScreenshot: failed to create buffer or blit encoder for float texture")
            return nil
        }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferLength
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else {
            HDRLogger.error(category: logCategory, "captureScreenshot: float blit command buffer status \(cmdBuf.status.rawValue)")
            return nil
        }

        // Convert float RGBA (0–1) to BGRA 8-bit in a new buffer for CGImage.
        let outBytesPerRow = width * 4
        let outLength = outBytesPerRow * height
        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outLength)
        defer { outBuffer.deallocate() }

        buffer.contents().withMemoryRebound(to: Float.self, capacity: width * height * 4) { floats in
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let r = UInt8(min(255, max(0, Int(floats[i + 0] * 255))))
                    let g = UInt8(min(255, max(0, Int(floats[i + 1] * 255))))
                    let b = UInt8(min(255, max(0, Int(floats[i + 2] * 255))))
                    let a = UInt8(min(255, max(0, Int(floats[i + 3] * 255))))
                    let outIdx = (y * width + x) * 4
                    outBuffer[outIdx + 0] = b
                    outBuffer[outIdx + 1] = g
                    outBuffer[outIdx + 2] = r
                    outBuffer[outIdx + 3] = a
                }
            }
        }

        return makeCGImageFromBGRA(buffer: outBuffer, width: width, height: height, bytesPerRow: outBytesPerRow)
    }

    /// Build CGImage from BGRA 8-bit data. Converts to RGBA for CGImage (swap R/B) so colors are correct.
    private static func makeCGImageFromBGRA(
        buffer: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        // Copy BGRA -> RGBA so CoreGraphics interprets colors correctly.
        let count = bytesPerRow * height
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { rgba.deallocate() }
        let src = buffer.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: count, by: 4) {
            rgba[i + 0] = src[i + 2] // R
            rgba[i + 1] = src[i + 1] // G
            rgba[i + 2] = src[i + 0] // B
            rgba[i + 3] = src[i + 3] // A
        }

        guard let provider = CGDataProvider(data: Data(bytes: rgba, count: count) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Encode CGImage to JPEG Data in memory (e.g. for NET-006 scope stream). Quality 0...1.
    public static func encodeToJPEGData(_ image: CGImage, quality: Float = 0.85) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Save CGImage to file as PNG or JPEG.
    public static func saveScreenshot(_ image: CGImage, to url: URL, format: ScreenshotFormat) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.rawValue as CFString, 1, nil) else {
            HDRLogger.error(category: logCategory, "saveScreenshot: failed to create image destination for \(url.path)")
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            HDRLogger.error(category: logCategory, "saveScreenshot: failed to write \(url.path)")
            return false
        }
        HDRLogger.info(category: logCategory, "Screenshot saved to \(url.path)")
        return true
    }

    /// Copy CGImage to the general pasteboard (NSPasteboard.general).
    public static func copyScreenshotToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
        HDRLogger.info(category: logCategory, "Screenshot copied to pasteboard")
    }

    // MARK: - SC-021: Pixel Picker — read single pixel from texture

    /// Reads a single pixel at (x, y) from a bgra8Unorm texture. Coordinates must be in bounds.
    /// - Returns: (B, G, R, A) in 0...255, or nil on failure.
    public static func samplePixel(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        texture: MTLTexture,
        x: Int,
        y: Int
    ) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard texture.pixelFormat == .bgra8Unorm,
              x >= 0, x < texture.width,
              y >= 0, y < texture.height else {
            return nil
        }
        let bytesPerPixel = 4
        let bufferLength = bytesPerPixel

        guard let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else {
            return nil
        }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerPixel,
            destinationBytesPerImage: bufferLength
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else { return nil }

        let ptr = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return (ptr[0], ptr[1], ptr[2], ptr[3])
    }
}
