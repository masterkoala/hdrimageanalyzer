import Foundation
import Metal
import Logging
import Common

/// Pixel format for frame buffer (matches DeckLink BMDPixelFormat raw values for handoff from Capture).
public typealias FramePixelFormat = UInt32

/// A single slot in the triple buffer: GPU-visible buffer and metadata.
public struct FrameSlot {
    public let buffer: MTLBuffer
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let pixelFormat: FramePixelFormat
    public let bufferLength: Int
}

/// MT-002: Triple-buffered frame manager. Three slots for capture frames; Capture (or app) submits
/// frame bytes, pipeline consumes the latest via `getLatestFrame()`.
/// Thread-safe for single producer (capture) and single consumer (pipeline).
public final class TripleBufferedFrameManager {
    private let device: MTLDevice
    private let logCategory = "Metal.FrameManager"
    private let lock = NSLock()

    private var slots: [MTLBuffer?]
    private var slotMeta: [(width: Int, height: Int, rowBytes: Int, format: FramePixelFormat)]
    private var writeIndex: Int
    private var latestReadyIndex: Int?
    private let slotCount = 3
    /// INT-003: Staging buffer for submitFrame; copy from capture into staging without lock, then copy to slot under lock to shorten lock hold.
    private var stagingBuffer: MTLBuffer?
    private var stagingLength: Int = 0

    public init(device: MTLDevice) {
        self.device = device
        self.slots = (0..<slotCount).map { _ in nil }
        self.slotMeta = (0..<slotCount).map { _ in (0, 0, 0, 0) }
        self.writeIndex = 0
        self.latestReadyIndex = nil
    }

    /// Call from capture callback: copy frame bytes into the next slot and mark it ready.
    /// Reallocates slot buffer if size (rowBytes * height) exceeds current capacity.
    /// INT-003: Copy from capture into staging buffer first (no lock), then under lock copy to slot to shorten lock hold.
    public func submitFrame(bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, pixelFormat: FramePixelFormat) {
        let length = rowBytes * height
        if stagingLength < length {
            stagingBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            stagingLength = stagingBuffer != nil ? length : 0
        }
        guard let staging = stagingBuffer, staging.length >= length else {
            HDRLogger.error(category: logCategory, "Failed to allocate staging buffer length=\(length)")
            return
        }
        staging.contents().copyMemory(from: bytes, byteCount: length)
        // Allocate outside lock so getLatestFrame() on main thread is not blocked by makeBuffer (avoids UI freeze).
        lock.lock()
        let idx = writeIndex
        let existingBuf = slots[idx]
        let needAlloc = existingBuf == nil || existingBuf!.length < length
        lock.unlock()
        var buf: MTLBuffer? = existingBuf
        if needAlloc {
            buf = device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard let buffer = buf, buffer.length >= length else {
            HDRLogger.error(category: logCategory, "Failed to allocate frame buffer length=\(length)")
            return
        }
        lock.lock()
        slots[idx] = buffer
        slotMeta[idx] = (width, height, rowBytes, pixelFormat)
        buffer.contents().copyMemory(from: staging.contents(), byteCount: length)
        latestReadyIndex = idx
        writeIndex = (idx + 1) % slotCount
        lock.unlock()
    }

    /// Returns the most recently submitted frame slot, or nil if none. Safe to call from pipeline thread.
    public func getLatestFrame() -> FrameSlot? {
        lock.lock()
        guard let idx = latestReadyIndex,
              let buf = slots[idx] else {
            lock.unlock()
            return nil
        }
        let meta = slotMeta[idx]
        let slot = FrameSlot(
            buffer: buf,
            width: meta.width,
            height: meta.height,
            rowBytes: meta.rowBytes,
            pixelFormat: meta.format,
            bufferLength: buf.length
        )
        lock.unlock()
        return slot
    }

    /// Number of slots (3).
    public var bufferCount: Int { slotCount }

    /// MT-011: Release buffers for slots not currently in use (keeps only the latest-ready slot). Frees GPU memory under pressure; slots reallocate on next submitFrame.
    public func releaseUnusedSlots() {
        lock.lock()
        guard let keepIdx = latestReadyIndex else {
            lock.unlock()
            return
        }
        for i in 0..<slotCount where i != keepIdx {
            slots[i] = nil
        }
        lock.unlock()
        HDRLogger.info(category: logCategory, "Memory pressure: released unused triple-buffer slots (kept slot \(keepIdx))")
    }
}
