import Foundation
import SwiftUI

/// Central keyboard shortcut registry (UI-006). Defaults for all menu actions; optional UserDefaults overrides for customization.
public enum AppShortcuts {
    private static let overridesKey = "HDRApp.KeyboardShortcutOverrides"

    /// Identifiers for every command that has a shortcut (wired to UI-005 menus).
    public enum Action: String, CaseIterable, Codable {
        case openPresets
        case export
        case takeScreenshot
        case takeScopeScreenshot
        case copyScreenshotToPasteboard
        case enterFullScreen
        case zoomIn
        case zoomOut
        case actualSize
        case openDevicePicker
        case openFormatPicker
        case scopeType
        case colorspace
        case displayOptions
        case help
        case installOFXPlugin
    }

    /// Default key equivalent (single character) and modifier set per action.
    private static func defaultKeyAndModifiers(for action: Action) -> (Character, EventModifiers) {
        switch action {
        case .openPresets: return ("o", .command)
        case .export: return ("e", .command)
        case .takeScreenshot: return ("3", [.command, .shift])
        case .takeScopeScreenshot: return ("4", [.command, .shift])
        case .copyScreenshotToPasteboard: return ("c", [.command, .shift])
        case .enterFullScreen: return ("f", [.command, .control])
        case .zoomIn: return ("+", .command)
        case .zoomOut: return ("-", .command)
        case .actualSize: return ("0", .command)
        case .openDevicePicker: return ("d", [.command, .shift])
        case .openFormatPicker: return ("m", [.command, .shift])
        case .scopeType: return ("s", [.command, .shift])
        case .colorspace: return ("k", [.command, .shift])
        case .displayOptions: return ("i", [.command, .shift])
        case .help: return ("?", .command)
        case .installOFXPlugin: return ("i", [.command, .shift])
        }
    }

    /// Returns the effective keyboard shortcut for the action (override from UserDefaults or default).
    public static func shortcut(for action: Action) -> KeyboardShortcut {
        let (defKey, defMod) = defaultKeyAndModifiers(for: action)
        guard let overrides = loadOverrides(),
              let entry = overrides[action.rawValue],
              let keyChar = entry["key"]?.first,
              let mods = parseModifiers(entry["modifiers"]) else {
            return KeyboardShortcut(KeyEquivalent(defKey), modifiers: defMod)
        }
        return KeyboardShortcut(KeyEquivalent(keyChar), modifiers: mods)
    }

    /// Override shortcut for an action (persisted to UserDefaults). Pass nil to restore default.
    public static func setOverride(_ key: Character?, modifiers: EventModifiers?, for action: Action) {
        var overrides = loadOverrides() ?? [:]
        if let key = key, let modifiers = modifiers {
            overrides[action.rawValue] = [
                "key": String(key),
                "modifiers": stringFromModifiers(modifiers)
            ]
        } else {
            overrides.removeValue(forKey: action.rawValue)
        }
        saveOverrides(overrides)
    }

    /// Reset all overrides to defaults.
    public static func resetAllOverrides() {
        UserDefaults.standard.removeObject(forKey: overridesKey)
    }

    public static func hasOverrides() -> Bool {
        (loadOverrides() ?? [:]).isEmpty == false
    }

    private static func loadOverrides() -> [String: [String: String]]? {
        guard let data = UserDefaults.standard.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func saveOverrides(_ overrides: [String: [String: String]]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: overridesKey)
    }

    private static func stringFromModifiers(_ m: EventModifiers) -> String {
        var parts: [String] = []
        if m.contains(.command) { parts.append("command") }
        if m.contains(.shift) { parts.append("shift") }
        if m.contains(.option) { parts.append("option") }
        if m.contains(.control) { parts.append("control") }
        return parts.joined(separator: ",")
    }

    private static func parseModifiers(_ s: String?) -> EventModifiers? {
        guard let s = s, !s.isEmpty else { return nil }
        var mods: EventModifiers = []
        for part in s.split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces).lowercased() {
            case "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "option": mods.insert(.option)
            case "control": mods.insert(.control)
            default: break
            }
        }
        return mods.isEmpty ? nil : mods
    }
}
