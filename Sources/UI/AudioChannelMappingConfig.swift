import Foundation
import SwiftUI

// MARK: - AU-011 Audio channel mapping configuration

/// UserDefaults keys for channel mapping (used by Preferences and MainView).
public enum AudioChannelMappingPrefsKeys {
    public static let channelMappingPreset = "HDRApp.Prefs.Audio.ChannelMappingPreset"
    public static let channelMappingCustomLabels = "HDRApp.Prefs.Audio.ChannelMappingCustomLabels"
}

/// Preset for how source channels are labeled in the meter UI (SDI standard vs custom).
public enum AudioChannelMappingPreset: String, CaseIterable {
    case numeric = "numeric"   // "1" … "16"
    case sdi16 = "sdi16"       // "Ch1" … "Ch16" (SDI 16ch standard)
    case custom = "custom"     // User-defined labels

    public var displayName: String {
        switch self {
        case .numeric: return "Numeric (1–16)"
        case .sdi16: return "SDI 16ch standard"
        case .custom: return "Custom"
        }
    }
}

/// Provides configured channel labels for the 16ch meter (AU-011). Reads from UserDefaults.
public enum AudioChannelMappingConfig {
    public static let maxChannels = 16

    /// Resolve labels from UserDefaults (for use in MainView).
    public static func resolvedLabels() -> [String] {
        let presetRaw = UserDefaults.standard.string(forKey: AudioChannelMappingPrefsKeys.channelMappingPreset) ?? AudioChannelMappingPreset.numeric.rawValue
        let preset = AudioChannelMappingPreset(rawValue: presetRaw) ?? .numeric
        let customJSON = UserDefaults.standard.string(forKey: AudioChannelMappingPrefsKeys.channelMappingCustomLabels) ?? ""
        let customLabels: [String] = (try? JSONDecoder().decode([String].self, from: Data((customJSON.isEmpty ? "[]" : customJSON).utf8))) ?? []
        return labels(for: preset, customLabels: customLabels)
    }

    /// Default labels for preset (no custom).
    public static func labels(for preset: AudioChannelMappingPreset, customLabels: [String]) -> [String] {
        switch preset {
        case .numeric:
            return (1...maxChannels).map { "\($0)" }
        case .sdi16:
            return (1...maxChannels).map { "Ch\($0)" }
        case .custom:
            var result = customLabels
            while result.count < maxChannels {
                result.append("\(result.count + 1)")
            }
            return Array(result.prefix(maxChannels))
        }
    }
}
