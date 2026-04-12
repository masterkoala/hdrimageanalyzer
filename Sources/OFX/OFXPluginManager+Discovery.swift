import Foundation
import Common
import Logging

/// Extensions to OFXPluginManager for plugin discovery and installation
public extension OFXPluginManager {
    // MARK: - Plugin Discovery

    /// Discovers installed OFX plugins in Resolve's expected locations
    public func discoverInstalledPlugins() -> [OFXResolvePlugin] {
        var foundPlugins: [OFXResolvePlugin] = []

        let resolvePaths = possibleResolveOFXPaths()

        for path in resolvePaths {
            let directoryURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
                continue
            }

            for item in contents where item.pathExtension == "plugin" {
                // Look for our installed plugins first
                if let plugin = self.findHDRAnalyzerProPlugin(at: item) {
                    foundPlugins.append(plugin)
                }
            }
        }

        HDRLogger.info(category: logCategory, message: "Discovered \(foundPlugins.count) OFX plugins")
        return foundPlugins
    }

    /// Installs the HDRImageAnalyzerPro OFX plugin for DaVinci Resolve
    /// - Parameter targetDirectory: Optional custom installation path
    /// - Returns: Boolean indicating success
    public func installOFXPlugin(targetDirectory: String? = nil) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HDRImageAnalyzerPro", isDirectory: true)
            .appendingPathComponent("OFXPlugins", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            // Create the main input plugin
            let inputPlugin = OFXResolvePlugin(
                id: "com.hdrimageanalyzerpro.resolve.input",
                displayName: "HDRImagePro Resolve Input",
                version: "1.0.0",
                formats: [.RGB8, .v210],
                resolution: .HD_1080p30,
                isInput: true
            )

            let installPath = appSupport.appendingPathComponent(inputPlugin.pluginID)
            try FileManager.default.createDirectory(at: installPath, withIntermediateDirectories: true)

            // Create plugin Info.plist
            let infoPlist = createPluginInfoPlist(
                id: inputPlugin.pluginID,
                name: inputPlugin.displayName,
                version: inputPlugin.version
            )

            try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
                .write(to: installPath.appendingPathExtension("plist"), options: .atomic)

            // Create plugin registration file for HDRImageAnalyzerPro
            let registrationData = [
                "pluginId": inputPlugin.pluginID,
                "displayName": inputPlugin.displayName,
                "version": inputPlugin.version,
                "isInputPlugin": true,
                "supportedFormats": inputPlugin.supportedPixelFormats.map { $0.resolveString() },
                "defaultResolution": "\(inputPlugin.defaultResolution.width)x\(inputPlugin.defaultResolution.height)@\(inputPlugin.defaultResolution.frameRate)"
            ] as [String: Any]

            let registrationURL = appSupport.appendingPathComponent("\(inputPlugin.pluginID).json")
            try JSONSerialization.data(withJSONObject: registrationData, options: [])
                .write(to: registrationURL, options: .atomic)

            HDRLogger.info(category: logCategory, message: "Installed OFX plugin \(inputPlugin.displayName) to \(appSupport.path)")

            return true
        } catch {
            HDRLogger.error(category: logCategory, message: "Failed to install OFX plugin: \(error)")
            return false
        }
    }

    /// Removes the HDRImageAnalyzerPro OFX plugin from Resolve
    public func uninstallOFXPlugin() -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HDRImageAnalyzerPro", isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: appSupport.path) {
                try FileManager.default.removeItem(at: appSupport)
                HDRLogger.info(category: logCategory, message: "Uninstalled OFX plugins")
                return true
            }
            return false
        } catch {
            HDRLogger.error(category: logCategory, message: "Failed to uninstall OFX plugin: \(error)")
            return false
        }
    }

    /// Lists all discovered installed plugins with their status
    public func listInstalledPlugins() -> [PluginInfo] {
        let discovered = discoverInstalledPlugins()

        return discovered.map { plugin in
            PluginInfo(
                pluginId: plugin.pluginID,
                displayName: plugin.displayName,
                version: plugin.version,
                isActive: true,
                isInputPlugin: plugin.isInputPlugin
            )
        }
    }

    /// Checks if a specific plugin is installed and active
    public func isPluginInstalled(_ pluginId: String) -> Bool {
        return discoverInstalledPlugins().contains { $0.pluginID == pluginId }
    }

    // MARK: - Private Helpers

    private func possibleResolveOFXPaths() -> [String] {
        return [
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/OFX",
            "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Plugins/VFX/OFX",
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Blackmagic Design/DaVinci Resolve/OFX").path,
            Bundle.main.bundlePath + "/Contents/Resources/OFX"
        ]
    }

    private func findHDRAnalyzerProPlugin(at url: URL) -> OFXResolvePlugin? {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")

        if FileManager.default.fileExists(atPath: infoPlistURL.path) {
            guard let plistData = try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoPlistURL), options: [], format: nil),
                  let dict = plistData as? [String: Any],
                  let cfBundleIdentifier = dict["CFBundleIdentifier"] as? String,
                  cfBundleIdentifier.hasSuffix("HDRImageAnalyzerPro") else {
                return nil
            }

            // Return a placeholder - actual plugin would load from here
            return OFXResolvePlugin(
                id: cfBundleIdentifier,
                displayName: dict["CFBundleName"] as? String ?? "Unknown Plugin",
                version: dict["CFBundleShortVersionString"] as? String ?? "unknown"
            )
        }

        // Check JSON registration files in the app support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HDRImageAnalyzerPro", isDirectory: true)

        do {
            let jsonFiles = try FileManager.default.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            for jsonFile in jsonFiles {
                guard let data = try? Data(contentsOf: jsonFile),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pluginId = dict["pluginId"] as? String else {
                    continue
                }

                return OFXResolvePlugin(
                    id: pluginId,
                    displayName: dict["displayName"] as? String ?? "Unknown Plugin",
                    version: dict["version"] as? String ?? "unknown",
                    isInput: dict["isInputPlugin"] as? Bool ?? true
                )
            }
        } catch {
            HDRLogger.debug(category: logCategory, message: "No JSON plugin files found")
        }

        return nil
    }

    private func createPluginInfoPlist(id: String, name: String, version: String) -> [String: Any] {
        return [
            "CFBundleIdentifier": "com.blackmagic-design.OFX.PlugIns.\(id)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1"
        ]
    }
}

/// Information about an installed OFX plugin
public struct PluginInfo: CustomStringConvertible {
    public let pluginId: String
    public var displayName: String
    public let version: String
    public let isActive: Bool
    public let isInputPlugin: Bool

    public var description: String {
        "Plugin: \(displayName) v\(version) (\(pluginId)) - \(isActive ? "Active" : "Inactive") - \(isInputPlugin ? "Input" : "Filter")"
    }
}
