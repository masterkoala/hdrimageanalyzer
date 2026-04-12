import Foundation
import Logging
import Common

// MARK: - NDI video receive and decode pipeline (Phase 9, NET-002)
// Uses NDI SDK recv API via dynamic loading. Decode is performed by the NDI library;
// we receive uncompressed video frames (e.g. UYVY, P216) and expose them as NDIVideoFrame.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Function pointers for NDI recv API (resolved via dlsym).
private struct NDIRecvFuncs {
    var initialize: UnsafeMutableRawPointer?
    var destroy: UnsafeMutableRawPointer?
    var recv_create_v3: UnsafeMutableRawPointer?
    var recv_destroy: UnsafeMutableRawPointer?
    var recv_connect: UnsafeMutableRawPointer?
    var recv_capture_v2: UnsafeMutableRawPointer?
    var recv_free_video_v2: UnsafeMutableRawPointer?
    var recv_free_audio_v2: UnsafeMutableRawPointer?
}

/// C ABI: NDI source for connect (must match NDIlib_source_t).
private struct NDIlib_source_t {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_url_address: UnsafePointer<CChar>?
}

/// C ABI: NDI recv create options (NULL or zeros for defaults).
private struct NDIlib_recv_create_t {
    var source_to_connect_to: NDIlib_source_t?
    var color_format: Int32 = 0
    var bandwidth: Int32 = 0
    var allow_video_fields: Bool = false
    var p_ndi_recv_name: UnsafePointer<CChar>?
}

/// C ABI: NDI video frame v2 (filled by NDIlib_recv_capture; must match SDK layout).
private struct NDIlib_video_frame_v2_t {
    var xres: Int32
    var yres: Int32
    var FourCC: UInt32
    var frame_rate_N: Int32
    var frame_rate_D: Int32
    var picture_aspect_ratio: Float
    var frame_format_type: Int32
    var timecode: Int64
    var p_data: UnsafeMutablePointer<UInt8>?
    var line_stride_in_bytes: Int32
    var p_metadata: UnsafeMutablePointer<CChar>?
    var timestamp: Int64
}

/// C ABI: NDI audio frame v2 (filled by NDIlib_recv_capture_v2; must match SDK layout).
private struct NDIlib_audio_frame_v2_t {
    var sample_rate: Int32
    var no_channels: Int32
    var no_samples: Int32
    var channel_stride_in_bytes: Int32
    var p_data: UnsafeMutablePointer<Float>?
    var timecode: Int64
    var timestamp: Int64
}

private let NDIlib_frame_type_none: UInt32 = 0
private let NDIlib_frame_type_video: UInt32 = 1
private let NDIlib_frame_type_audio: UInt32 = 2

/// Receives and decodes NDI video from a selected source. Thread-safe; runs on internal queue.
public final class NDIVideoReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HDRImageAnalyzerPro.NDIVideoReceiver", qos: .userInitiated)
    private var recvInstance: OpaquePointer?
    private var ndiLibHandle: UnsafeMutableRawPointer?
    private var ndiRecvFuncs: NDIRecvFuncs?
    private weak var delegate: NDIVideoReceiverDelegate?
    private weak var audioDelegate: NDIAudioReceiverDelegate?

    public init() {}

    deinit {
        disconnect()
        unloadNDI()
    }

    public func setDelegate(_ delegate: NDIVideoReceiverDelegate?) {
        queue.async { [weak self] in
            self?.delegate = delegate
        }
    }

    /// Set delegate for NDI audio frames (NET-003). Called on receiver queue.
    public func setAudioDelegate(_ delegate: NDIAudioReceiverDelegate?) {
        queue.async { [weak self] in
            self?.audioDelegate = delegate
        }
    }

    /// Connect to an NDI source. No-op if SDK not loaded. Disconnects from previous source.
    public func connect(to source: NDISourceInfo) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.disconnectLocked()
            guard self.loadNDI(), let recv = self.createRecv() else {
                HDRLogger.info(category: "Network", "NDI receiver not available (SDK not loaded)")
                return
            }
            self.recvInstance = recv
            source.name.withCString { namePtr in
                source.urlAddress.withCString { urlPtr in
                    var src = NDIlib_source_t(p_ndi_name: namePtr, p_url_address: urlPtr)
                    withUnsafePointer(to: &src) { srcPtr in
                        typealias ConnectFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
                        if let pConnect = self.ndiRecvFuncs?.recv_connect {
                            unsafeBitCast(pConnect, to: ConnectFn.self)(recv, srcPtr)
                        }
                    }
                }
            }
            HDRLogger.info(category: "Network", "NDI receiver connected to \(source.name)")
        }
    }

    /// Disconnect from current source and destroy receiver.
    public func disconnect() {
        queue.sync { disconnectLocked() }
    }

    private func disconnectLocked() {
        guard let recv = recvInstance, let f = ndiRecvFuncs else { return }
        if let pDestroy = f.recv_destroy {
            typealias RecvDestroyFn = @convention(c) (OpaquePointer?) -> Void
            unsafeBitCast(pDestroy, to: RecvDestroyFn.self)(recv)
        }
        recvInstance = nil
        HDRLogger.info(category: "Network", "NDI receiver disconnected")
    }

    /// Capture one video frame (with optional timeout). Returns owned copy of frame data, or nil.
    /// Call from any thread; runs on receiver queue and blocks up to timeoutMs.
    public func captureVideoFrame(timeoutMs: UInt32 = 1000) -> NDIVideoFrame? {
        queue.sync { captureVideoFrameLocked(timeoutMs: timeoutMs) }
    }

    private func captureVideoFrameLocked(timeoutMs: UInt32) -> NDIVideoFrame? {
        guard let recv = recvInstance, let f = ndiRecvFuncs,
              let pCapture = f.recv_capture_v2, let pFree = f.recv_free_video_v2 else { return nil }
        typealias CaptureFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> UInt32
        typealias FreeVideoFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        var videoFrame = NDIlib_video_frame_v2_t(
            xres: 0, yres: 0, FourCC: 0, frame_rate_N: 0, frame_rate_D: 0,
            picture_aspect_ratio: 0, frame_format_type: 0, timecode: 0,
            p_data: nil, line_stride_in_bytes: 0, p_metadata: nil, timestamp: 0
        )
        let frameType = withUnsafeMutablePointer(to: &videoFrame) { vPtr in
            unsafeBitCast(pCapture, to: CaptureFn.self)(recv, vPtr, nil, nil, timeoutMs)
        }
        defer {
            withUnsafeMutablePointer(to: &videoFrame) { vPtr in
                unsafeBitCast(pFree, to: FreeVideoFn.self)(recv, vPtr)
            }
        }
        guard frameType == NDIlib_frame_type_video,
              let pData = videoFrame.p_data,
              videoFrame.xres > 0, videoFrame.yres > 0,
              videoFrame.line_stride_in_bytes > 0 else { return nil }
        let width = Int(videoFrame.xres)
        let height = Int(videoFrame.yres)
        let stride = Int(videoFrame.line_stride_in_bytes)
        let length = stride * height
        let data = Data(bytes: pData, count: length)
        let frame = NDIVideoFrame(
            width: width,
            height: height,
            lineStrideBytes: stride,
            fourCC: videoFrame.FourCC,
            pixelData: data
        )
        return frame
    }

    /// Capture one audio frame (multi-channel planar float32). Returns owned copy, or nil.
    /// Call from any thread; runs on receiver queue. Uses same connection as video (NET-003).
    public func captureAudioFrame(timeoutMs: UInt32 = 1000) -> NDIAudioFrame? {
        queue.sync { captureAudioFrameLocked(timeoutMs: timeoutMs) }
    }

    private func captureAudioFrameLocked(timeoutMs: UInt32) -> NDIAudioFrame? {
        guard let recv = recvInstance, let f = ndiRecvFuncs,
              let pCapture = f.recv_capture_v2, let pFreeAudio = f.recv_free_audio_v2 else { return nil }
        typealias CaptureFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> UInt32
        typealias FreeAudioFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        var audioFrame = NDIlib_audio_frame_v2_t(
            sample_rate: 0, no_channels: 0, no_samples: 0, channel_stride_in_bytes: 0,
            p_data: nil, timecode: 0, timestamp: 0
        )
        let frameType = withUnsafeMutablePointer(to: &audioFrame) { aPtr in
            unsafeBitCast(pCapture, to: CaptureFn.self)(recv, nil, aPtr, nil, timeoutMs)
        }
        defer {
            withUnsafeMutablePointer(to: &audioFrame) { aPtr in
                unsafeBitCast(pFreeAudio, to: FreeAudioFn.self)(recv, aPtr)
            }
        }
        guard frameType == NDIlib_frame_type_audio,
              let pData = audioFrame.p_data,
              audioFrame.no_channels > 0,
              audioFrame.no_samples > 0,
              audioFrame.channel_stride_in_bytes > 0 else { return nil }
        let channelCount = Int(audioFrame.no_channels)
        let stride = Int(audioFrame.channel_stride_in_bytes)
        let length = channelCount * stride
        let data = Data(bytes: pData, count: length)
        return NDIAudioFrame(
            sampleRate: Int(audioFrame.sample_rate),
            channelCount: channelCount,
            samplesPerChannel: Int(audioFrame.no_samples),
            channelStrideBytes: stride,
            sampleData: data,
            timecode: audioFrame.timecode,
            timestamp: audioFrame.timestamp
        )
    }

    /// Start a loop that captures audio and delivers frames to the audio delegate on the receiver queue (NET-003).
    public func startAudioReceiveLoop(timeoutMs: UInt32 = 100) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.audioReceiveLoopRunning = true
            self.runAudioReceiveLoop(timeoutMs: timeoutMs)
        }
    }

    /// Stop the audio receive loop.
    public func stopAudioReceiveLoop() {
        queue.async { [weak self] in
            self?.audioReceiveLoopRunning = false
        }
    }

    private var audioReceiveLoopRunning = false

    private func runAudioReceiveLoop(timeoutMs: UInt32) {
        guard audioReceiveLoopRunning, let frame = captureAudioFrameLocked(timeoutMs: timeoutMs) else {
            if audioReceiveLoopRunning {
                queue.async { [weak self] in self?.runAudioReceiveLoop(timeoutMs: timeoutMs) }
            }
            return
        }
        audioDelegate?.ndiAudioReceiver(self, didReceiveFrame: frame)
        queue.async { [weak self] in self?.runAudioReceiveLoop(timeoutMs: timeoutMs) }
    }

    /// Start a loop that captures video and delivers frames to the delegate on the receiver queue.
    /// Call stopReceiveLoop() to stop. Only one loop per receiver.
    public func startReceiveLoop(timeoutMs: UInt32 = 100) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.receiveLoopRunning = true
            self.runReceiveLoop(timeoutMs: timeoutMs)
        }
    }

    /// Stop the receive loop.
    public func stopReceiveLoop() {
        queue.async { [weak self] in
            self?.receiveLoopRunning = false
        }
    }

    private var receiveLoopRunning = false

    private func runReceiveLoop(timeoutMs: UInt32) {
        guard receiveLoopRunning, let frame = captureVideoFrameLocked(timeoutMs: timeoutMs) else {
            if receiveLoopRunning {
                queue.async { [weak self] in self?.runReceiveLoop(timeoutMs: timeoutMs) }
            }
            return
        }
        delegate?.ndiVideoReceiver(self, didReceiveFrame: frame)
        queue.async { [weak self] in self?.runReceiveLoop(timeoutMs: timeoutMs) }
    }

    // MARK: - NDI dynamic loading (recv)

    private static let libNames = [
        "libndi.dylib",
        "libndi.5.dylib",
        "libndi.4.dylib",
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi.dylib",
    ]

    private func loadNDI() -> Bool {
        if ndiRecvFuncs != nil { return true }
        for name in Self.libNames {
            let handle = dlopen(name, RTLD_NOW)
            guard let handle = handle else { continue }
            guard let pInit = dlsym(handle, "NDIlib_initialize"),
                  let pDestroy = dlsym(handle, "NDIlib_destroy"),
                  let pRecvCreate = dlsym(handle, "NDIlib_recv_create_v3"),
                  let pRecvDestroy = dlsym(handle, "NDIlib_recv_destroy"),
                  let pRecvConnect = dlsym(handle, "NDIlib_recv_connect"),
                  let pRecvCapture = dlsym(handle, "NDIlib_recv_capture_v2"),
                  let pRecvFreeVideo = dlsym(handle, "NDIlib_recv_free_video_v2"),
                  let pRecvFreeAudio = dlsym(handle, "NDIlib_recv_free_audio_v2") else {
                dlclose(handle)
                continue
            }
            var f = NDIRecvFuncs()
            f.initialize = pInit
            f.destroy = pDestroy
            f.recv_create_v3 = pRecvCreate
            f.recv_destroy = pRecvDestroy
            f.recv_connect = pRecvConnect
            f.recv_capture_v2 = pRecvCapture
            f.recv_free_video_v2 = pRecvFreeVideo
            f.recv_free_audio_v2 = pRecvFreeAudio
            ndiLibHandle = handle
            ndiRecvFuncs = f
            typealias InitFn = @convention(c) () -> Bool
            if !unsafeBitCast(pInit, to: InitFn.self)() {
                dlclose(handle)
                ndiLibHandle = nil
                ndiRecvFuncs = nil
                continue
            }
            return true
        }
        return false
    }

    private func unloadNDI() {
        if recvInstance != nil { disconnectLocked() }
        if let h = ndiLibHandle {
            if let f = ndiRecvFuncs, let pDestroy = f.destroy {
                typealias DestroyFn = @convention(c) () -> Void
                unsafeBitCast(pDestroy, to: DestroyFn.self)()
            }
            dlclose(h)
            ndiLibHandle = nil
        }
        ndiRecvFuncs = nil
    }

    private func createRecv() -> OpaquePointer? {
        guard let f = ndiRecvFuncs, let pCreate = f.recv_create_v3 else { return nil }
        typealias RecvCreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        return unsafeBitCast(pCreate, to: RecvCreateFn.self)(nil)
    }
}
