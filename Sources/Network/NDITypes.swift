import Foundation

// MARK: - NDI source (Phase 9, NET-001)

/// Discovered NDI source: name and URL for connection.
public struct NDISourceInfo: Sendable, Equatable {
    public let name: String
    public let urlAddress: String

    public init(name: String, urlAddress: String) {
        self.name = name
        self.urlAddress = urlAddress
    }
}

/// Delegate for NDI discovery updates (sources added/removed).
public protocol NDIDiscoveryDelegate: AnyObject, Sendable {
    func ndiDiscovery(_ discovery: NDIDiscovery, didUpdateSources sources: [NDISourceInfo])
}

// MARK: - NDI video frame (Phase 9, NET-002)

/// Decoded NDI video frame: owned copy of pixel data for pipeline or display.
/// FourCC matches NDI (e.g. UYVY 0x55595659, RGBA 0x52474241). Use pixelFormatFourCC for Metal FramePixelFormat.
public struct NDIVideoFrame: Sendable {
    public let width: Int
    public let height: Int
    public let lineStrideBytes: Int
    /// NDI FourCC as UInt32 (e.g. UYVY, RGBA).
    public let fourCC: UInt32
    public let pixelData: Data

    public init(width: Int, height: Int, lineStrideBytes: Int, fourCC: UInt32, pixelData: Data) {
        self.width = width
        self.height = height
        self.lineStrideBytes = lineStrideBytes
        self.fourCC = fourCC
        self.pixelData = pixelData
    }

    /// Same as fourCC; use when submitting to pipeline as FramePixelFormat.
    public var pixelFormatFourCC: UInt32 { fourCC }
}

/// Delegate for NDI receiver video frames (called on receiver queue).
public protocol NDIVideoReceiverDelegate: AnyObject, Sendable {
    func ndiVideoReceiver(_ receiver: NDIVideoReceiver, didReceiveFrame frame: NDIVideoFrame)
}

// MARK: - NDI audio frame (Phase 9, NET-003)

/// Decoded NDI audio frame: multi-channel planar float32 (owned copy).
/// NDI uses planar layout: channel_stride_in_bytes per channel, sample_rate and no_samples per channel.
public struct NDIAudioFrame: Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let samplesPerChannel: Int
    /// Bytes per channel (stride); typically no_samples * 4 (float32).
    public let channelStrideBytes: Int
    public let sampleData: Data
    public let timecode: Int64
    public let timestamp: Int64

    public init(sampleRate: Int, channelCount: Int, samplesPerChannel: Int, channelStrideBytes: Int, sampleData: Data, timecode: Int64, timestamp: Int64) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samplesPerChannel = samplesPerChannel
        self.channelStrideBytes = channelStrideBytes
        self.sampleData = sampleData
        self.timecode = timecode
        self.timestamp = timestamp
    }
}

/// Delegate for NDI receiver audio frames (called on receiver queue).
public protocol NDIAudioReceiverDelegate: AnyObject, Sendable {
    func ndiAudioReceiver(_ receiver: NDIVideoReceiver, didReceiveFrame frame: NDIAudioFrame)
}
