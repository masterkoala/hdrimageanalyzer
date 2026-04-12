import Foundation

/// Named preset save/load (roadmap F-011). Persisted via UserDefaults.
public struct Preset: Codable {
    public var name: String
    public var config: AppConfig
    public init(name: String, config: AppConfig) {
        self.name = name
        self.config = config
    }
}

public enum PresetManager {
    private static let key = "HDRPresets"

    public static func save(_ preset: Preset) {
        var all = loadAll()
        all[preset.name] = preset.config
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func load(name: String) -> AppConfig? {
        loadAll()[name]
    }

    public static func loadAll() -> [String: AppConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: AppConfig].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func delete(name: String) {
        var all = loadAll()
        all.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func presetNames() -> [String] {
        Array(loadAll().keys).sorted()
    }
}
