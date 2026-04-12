import Foundation

/// Represents an OFX plugin that can capture from DaVinci Resolve's OFX pipeline.
public struct OFXResolvePlugin {
    /// Unique identifier for this plugin
    public let pluginID: String

    /// Display name shown in DaVinci Resolve's OFX panel
    public var displayName: String

    /// Plugin version string
    public var version: String

    /// Supported pixel formats (matches DeckLinkPixelFormat mapping)
    public var supportedPixelFormats: [OFXPixelFormat]

    /// Default resolution when no external signal detected
    public var defaultResolution: Resolution

    /// Whether this plugin acts as input source
    public let isInputPlugin: Bool

    /// Optional manufacturer ID for Resolve categorization
    public var manufacturerID: String?

    // MARK: - Initialization

    public init(
        id: String,
        displayName: String,
        version: String = "1.0.0",
        formats: [OFXPixelFormat] = [.RGB8],
        resolution: Resolution = .HD_1080p30,
        isInput: Bool = true,
        manufacturerID: String? = nil
    ) {
        self.pluginID = id
        self.displayName = displayName
        self.version = version
        self.supportedPixelFormats = formats
        self.defaultResolution = resolution
        self.isInputPlugin = isInput
        self.manufacturerID = manufacturerID
    }

    // MARK: - Plugin Info

    /// Returns the plugin's manifest structure for Resolve
    public func manifest() -> [String: Any] {
        var manifest: [String: Any] = [
            "pluginId": pluginID,
            "name": displayName,
            "version": version,
            "category": isInputPlugin ? "OFX::kVizInput" : "OFX::kVizFilter",
            "manufacturerName": manufacturerID ?? "HDRImageAnalyzerPro",
            "supportsMultiInstance": false,
            "supportsRetiming": true
        ]

        if !supportedPixelFormats.isEmpty {
            manifest["pixelFormats"] = supportedPixelFormats.map { $0.resolveString() }
        }

        return manifest
    }

    /// Path to the plugin bundle on disk
    public var bundlePath: String {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HDRImageAnalyzerPro", isDirectory: true)
            .appendingPathComponent("OFXPlugins", isDirectory: true)

        return applicationSupport.appendingPathComponent(pluginID, isDirectory: false).path
    }

    /// Creates the plugin bundle structure for Resolve
    public func createPluginBundle() throws -> Bool {
        let url = URL(fileURLWithPath: bundlePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Create Info.plist for macOS app
        let infoPlist = [
            "CFBundleIdentifier": "com.blackmagic-design.OFX.PlugIns.\(pluginID)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName,
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1"
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )

        try plistData.write(to: url.appendingPathExtension("plist"), options: .atomic)

        return true
    }

    /// Path to the plugin's shared library (.so)
    public func libraryPath() -> String {
        return bundlePath
    }
}

/// Supported pixel formats for OFX input
public enum OFXPixelFormat {
    case RGB8       // 32-bit BGRA (bmdFormat8BitBGRA)
    case v210       // 10-bit YUV 4:2:2 packed (bmdFormat10BitYUV)
    case RGB12LE    // 12-bit RGB Little-Endian (bmdFormat12BitRGBLE)
    case RGB12BE    // 12-bit RGB Big-Endian (bmdFormat12BitRGB)

    /// Resolves to Resolve OFX format string
    public func resolveString() -> String {
        switch self {
        case .RGB8: return "OFX::PIXF_RGBA32"
        case .v210: return "OFX::PIXF_YCBCR709_10BIT"
        case .RGB12LE: return "OFX::PIXF_RGB16_LE"
        case .RGB12BE: return "OFX::PIXF_RGB16_BE"
        }
    }
}

/// Video resolution presets compatible with Resolve's OFX input
public struct Resolution: CustomStringConvertible, Hashable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let name: String

    public var description: String { "\(width)x\(height) @ \(frameRate)fps" }

    // MARK: - Presets

    public static let HD_720p30 = Resolution(width: 1280, height: 720, frameRate: 30.0, name: "HD 720p30")
    public static let HD_720p60 = Resolution(width: 1280, height: 720, frameRate: 60.0, name: "HD 720p60")
    public static let HD_1080p24 = Resolution(width: 1920, height: 1080, frameRate: 23.976, name: "Full HD 1080p24")
    public static let HD_1080p30 = Resolution(width: 1920, height: 1080, frameRate: 29.97, name: "Full HD 1080p30")
    public static let HD_1080p60 = Resolution(width: 1920, height: 1080, frameRate: 59.94, name: "Full HD 1080p60")
    public static let UHD_4K_p24 = Resolution(width: 3840, height: 2160, frameRate: 23.976, name: "UHD 4K p24")
    public static let UHD_4K_p30 = Resolution(width: 3840, height: 2160, frameRate: 29.97, name: "UHD 4K p30")
}
