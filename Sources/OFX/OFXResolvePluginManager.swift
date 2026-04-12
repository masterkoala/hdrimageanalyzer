import Foundation
import Common
import Logging

/// Manages OFX plugins for DaVinci Resolve integration.
/// Provides plugin discovery, loading, and lifecycle management.
public final class OFXResolvePluginManager {
    public static let shared = OFXResolvePluginManager()

    internal let logCategory = "OFX.PluginManager"
    private var loadedPlugins: [String: OFXResolvePlugin] = [:]
    private var activeCaptures: [String: OFXResolveInputCapture] = [:]
    private let pluginsDirectory: URL

    // Resolve OFX search paths on macOS
    private let resolveOFXPaths: [URL] = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return [
            appSupport.appendingPathComponent("Blackmagic Design/DaVinci Resolve/OFX"),
            appSupport.appendingPathComponent("Blackmagic Design/DaVinci Resolve Support/OFX"),
            URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/OFX"),
            URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve Support/OFX"),
        ]
    }()

    private init() {
        // Create HDRImageAnalyzerPro OFX plugins directory if needed
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.pluginsDirectory = appSupport.appendingPathComponent("HDRImageAnalyzerPro/OFXPlugins", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
            HDRLogger.debug(category: logCategory, message: "Initialized OFX Plugin Manager at \(pluginsDirectory.path)")
        } catch {
            HDRLogger.error(category: logCategory, message: "Failed to create plugins directory: \(error)")
        }

        // Auto-discover installed HDRImageAnalyzerPro plugins
        self.discoverInstalledPlugins()
    }

    // MARK: - Plugin Management

    /// Register a new OFX plugin for Resolve integration
    public func registerPlugin(_ plugin: OFXResolvePlugin) -> Bool {
        guard !loadedPlugins.keys.contains(plugin.pluginID) else {
            HDRLogger.warning(category: logCategory, message: "Plugin \(plugin.pluginID) already registered")
            return false
        }

        do {
            try plugin.createPluginBundle()
            loadedPlugins[plugin.pluginID] = plugin
            HDRLogger.info(category: logCategory, message: "Registered OFX plugin: \(plugin.displayName) v\(plugin.version)")
            return true
        } catch {
            HDRLogger.error(category: logCategory, message: "Failed to create plugin bundle for \(plugin.pluginID): \(error)")
            return false
        }
    }

    /// Unregister an OFX plugin and clean up its files
    public func unregisterPlugin(_ pluginID: String) -> Bool {
        guard let plugin = loadedPlugins[pluginID] else { return false }

        // Stop any active capture using this plugin
        stopInputCapture(pluginID: pluginID)

        do {
            try FileManager.default.removeItem(atPath: plugin.bundlePath)
            loadedPlugins.removeValue(forKey: pluginID)
            HDRLogger.info(category: logCategory, message: "Unregistered OFX plugin: \(plugin.displayName)")
            return true
        } catch {
            HDRLogger.error(category: logCategory, message: "Failed to remove plugin bundle: \(error)")
            return false
        }
    }

    /// Get registered plugin by ID
    public func getPlugin(_ pluginID: String) -> OFXResolvePlugin? {
        return loadedPlugins[pluginID]
    }

    /// List all registered plugins
    public func listRegisteredPlugins() -> [OFXResolvePlugin] {
        return Array(loadedPlugins.values)
    }

    // MARK: - Input Capture Management

    /// Start video input capture from a registered OFX plugin
    public func startInputCapture(
        pluginID: String,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 29.97
    ) -> Bool {
        guard let plugin = loadedPlugins[pluginID] else {
            HDRLogger.error(category: logCategory, message: "Plugin \(pluginID) not found")
            return false
        }

        // Create or reuse capture instance
        let capture: OFXResolveInputCapture
        if let existing = activeCaptures[pluginID] {
            capture = existing
        } else {
            capture = OFXResolveInputCapture()
            activeCaptures[pluginID] = capture
        }

        // Configure capture parameters
        _ = capture.configureWithBasicParams(width: width, height: height, frameRate: frameRate)

        if capture.startCapture() {
            HDRLogger.info(category: logCategory, message: "Started input capture for \(plugin.displayName): \(width)x\(height) @ \(frameRate)fps")
            return true
        } else {
            HDRLogger.error(category: logCategory, message: "Failed to start input capture for \(plugin.displayName)")
            return false
        }
    }

    /// Stop video input capture from a registered OFX plugin
    @discardableResult
    public func stopInputCapture(pluginID: String) -> Bool {
        guard let capture = activeCaptures[pluginID] else { return false }

        capture.stopCapture()
        activeCaptures.removeValue(forKey: pluginID)
        HDRLogger.info(category: logCategory, message: "Stopped input capture for \(pluginID)")
        return true
    }

    /// Check if a capture session is active
    public func isInputActive(pluginID: String) -> Bool {
        guard let capture = activeCaptures[pluginID] else { return false }
        return capture.isCapturing
    }

    // MARK: - Plugin Discovery

    /// Discover OFX plugins installed in Resolve's OFX directory
    @discardableResult
    public func discoverInstalledPlugins() -> [String] {
        var discoveredIDs: [String] = []

        for path in resolveOFXPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in contents {
                if file.pathExtension.lowercased() == "ofx" || file.lastPathComponent.hasSuffix("OFXPlugin") {
                    let pluginID = file.deletingPathExtension().lastPathComponent
                    discoveredIDs.append(pluginID)
                }
            }
        }

        if !discoveredIDs.isEmpty {
            HDRLogger.info(category: logCategory, message: "Discovered \(discoveredIDs.count) OFX plugins from Resolve directories")
        }

        return discoveredIDs
    }

    // MARK: - Callback Wrappers

    private func handleCaptureFrame(pluginID: String) -> OFXFramePixelBufferHandler {
        return { [weak self] pixelBuffer, width, height in
            guard self != nil else { return }
            HDRLogger.debug(category: "OFX.Capture", message: "\(pluginID): Frame received \(width)x\(height)")
        }
    }

    private func handleFormatChange(pluginID: String) -> OFXFormatChangeHandler {
        return { [weak self] width, height, frameRate in
            guard let strongSelf = self else { return }
            HDRLogger.info(category: "OFX.FormatChange", message: "\(pluginID): \(width)x\(height) @ \(frameRate)")

            DispatchQueue.main.async {
                strongSelf.onFormatChange?(width, height, frameRate)
            }
        }
    }

    private func handleSignalStateChange(pluginID: String) -> OFXSignalStateHandler {
        return { [weak self] state in
            guard let strongSelf = self else { return }
            HDRLogger.info(category: "OFX.Signal", message: "\(pluginID): Signal state changed to \(state)")

            if strongSelf.onSignalStateChange != nil {
                DispatchQueue.main.async {
                    strongSelf.onSignalStateChange?(state)
                }
            }
        }
    }

    private func handleTimecode(pluginID: String) -> OFXTimecodeHandler {
        return { [weak self] timecode in
            guard let strongSelf = self else { return }
            HDRLogger.debug(category: "OFX.Timecode", message: "\(pluginID): \(timecode)")

            if strongSelf.onTimecode != nil {
                DispatchQueue.main.async {
                    strongSelf.onTimecode?(timecode)
                }
            }
        }
    }

    // MARK: - External Callbacks (for capture session integration)

    private var onFormatChange: OFXFormatChangeHandler?
    private var onSignalStateChange: OFXSignalStateHandler?
    private var onTimecode: OFXTimecodeHandler?

    /// Set external callback handlers for format changes, signal state, and timecode
    public func setCallbacks(
        onFormatChange: @escaping OFXFormatChangeHandler,
        onSignalState: @escaping OFXSignalStateHandler,
        onTimecode: @escaping OFXTimecodeHandler
    ) {
        self.onFormatChange = onFormatChange
        self.onSignalStateChange = onSignalState
        self.onTimecode = onTimecode
    }

    /// Get all active capture session identifiers
    public func activeCaptureIdentifiers() -> [String] {
        return Array(activeCaptures.keys)
    }
}
