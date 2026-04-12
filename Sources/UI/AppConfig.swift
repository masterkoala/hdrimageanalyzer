import Foundation
import Logging
import Common

/// Configuration management: UserDefaults + Codable (roadmap F-010). Equatable for SwiftUI onChange (UI-010).
public struct AppConfig: Codable, Equatable {
    public var lastWindowFrame: String?
    public var selectedDeviceID: String?
    public var defaultColorSpace: ColorSpace = .rec709
    /// UI-008: Gamut space for analysis (scopes, gamut checks). CS-004.
    public var analysisGamutSpace: GamutSpace = .rec709
    /// UI-008: Gamut space for display output. CS-004.
    public var displayGamutSpace: GamutSpace = .rec709
    public var logLevel: LogLevel = .info

    /// UI-011: Layout preset — quadrant content raw values (e.g. "Video", "Waveform").
    public var layoutQuadrant1: String?
    public var layoutQuadrant2: String?
    public var layoutQuadrant3: String?
    public var layoutQuadrant4: String?

    public static var current: AppConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "AppConfig"),
                  let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                return AppConfig()
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "AppConfig")
            }
        }
    }

    public static func save(_ config: AppConfig) {
        current = config
    }
}
