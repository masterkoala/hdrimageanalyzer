import SwiftUI
import AppKit
import Logging
import Common
import Scopes

// MARK: - UI-010 Preferences window (General, Display, Scopes, Audio, Network)

private enum PreferencesTab: String, CaseIterable {
    case general = "General"
    case display = "Display"
    case scopes = "Scopes"
    case audio = "Audio"
    case network = "Network"

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "display"
        case .scopes: return "waveform.path"
        case .audio: return "speaker.wave.2"
        case .network: return "network"
        }
    }
}

/// Root Preferences view with tabbed panes. Shown in Settings window (Cmd+,).
/// Optional initialTabIdentifier: "General", "Display", "Scopes", "Audio", "Network" — for programmatic focus (e.g. Display Options menu).
public struct PreferencesView: View {
    @State private var selectedTab: PreferencesTab = .general
    private let initialTabIdentifier: String?

    public init(initialTabIdentifier: String? = nil) {
        self.initialTabIdentifier = initialTabIdentifier
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPreferencesPane()
                .tabItem { Label(PreferencesTab.general.rawValue, systemImage: PreferencesTab.general.systemImage) }
                .tag(PreferencesTab.general)

            DisplayPreferencesPane()
                .tabItem { Label(PreferencesTab.display.rawValue, systemImage: PreferencesTab.display.systemImage) }
                .tag(PreferencesTab.display)

            ScopesPreferencesPane()
                .tabItem { Label(PreferencesTab.scopes.rawValue, systemImage: PreferencesTab.scopes.systemImage) }
                .tag(PreferencesTab.scopes)

            AudioPreferencesPane()
                .tabItem { Label(PreferencesTab.audio.rawValue, systemImage: PreferencesTab.audio.systemImage) }
                .tag(PreferencesTab.audio)

            NetworkPreferencesPane()
                .tabItem { Label(PreferencesTab.network.rawValue, systemImage: PreferencesTab.network.systemImage) }
                .tag(PreferencesTab.network)
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear {
            if let id = initialTabIdentifier, let tab = PreferencesTab(rawValue: id) {
                selectedTab = tab
            }
        }
    }
}

// MARK: - General

private struct GeneralPreferencesPane: View {
    @State private var config: AppConfig = AppConfig.current

    var body: some View {
        Form {
            Section("Logging") {
                Picker("Log level", selection: binding(\.logLevel)) {
                    ForEach(LogLevel.allCases, id: \.rawValue) { level in
                        Text(displayName(for: level)).tag(level)
                    }
                }
            }
            Section("Default color space") {
                Picker("Color space", selection: binding(\.defaultColorSpace)) {
                    Text("Rec.709").tag(Common.ColorSpace.rec709)
                    Text("Rec.2020").tag(Common.ColorSpace.rec2020)
                    Text("P3").tag(Common.ColorSpace.p3)
                    Text("PQ").tag(Common.ColorSpace.pq)
                    Text("HLG").tag(Common.ColorSpace.hlg)
                }
            }
            Section("Window") {
                Toggle("Restore window position on launch", isOn: .constant(true))
                    .disabled(true)
                Text("Window state is saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: config) { _, newValue in
            AppConfig.save(newValue)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
    }

    private func displayName(for level: LogLevel) -> String {
        switch level {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .off: return "Off"
        }
    }
}

// MARK: - Display

private struct DisplayPreferencesPane: View {
    @State private var config: AppConfig = AppConfig.current

    var body: some View {
        Form {
            Section("Analysis space") {
                Picker("Gamut for scopes and analysis", selection: binding(\.analysisGamutSpace)) {
                    ForEach(GamutSpace.allCases, id: \.rawValue) { space in
                        Text(space.displayName).tag(space)
                    }
                }
            }
            Section("Display space") {
                Picker("Gamut for display output", selection: binding(\.displayGamutSpace)) {
                    ForEach(GamutSpace.allCases, id: \.rawValue) { space in
                        Text(space.displayName).tag(space)
                    }
                }
            }
            Section {
                Text("Display Options in the menu bar opens runtime display options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: config) { _, newValue in
            AppConfig.save(newValue)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Scopes (UserDefaults keys for optional prefs)

private enum ScopesPrefsKeys {
    static let defaultWaveformScale = "HDRApp.Prefs.Scopes.DefaultWaveformScale"
    static let defaultWaveformMode = "HDRApp.Prefs.Scopes.DefaultWaveformMode"
    static let waveformLogScale = "HDRApp.Prefs.Scopes.WaveformLogScale"
    /// SC-020: Scope intensity. Stored as Double; 0 = use app default.
    static let scopeGamma = "HDRApp.Prefs.Scopes.ScopeGamma"
    static let scopeGain = "HDRApp.Prefs.Scopes.ScopeGain"
}

private struct ScopesPreferencesPane: View {
    @AppStorage(ScopesPrefsKeys.defaultWaveformScale) private var defaultScale: String = "sdrIRE"
    @AppStorage(ScopesPrefsKeys.defaultWaveformMode) private var defaultModeRaw: String = "0"
    @AppStorage(ScopesPrefsKeys.waveformLogScale) private var waveformLogScale: Bool = false
    @AppStorage(ScopesPrefsKeys.scopeGamma) private var scopeGamma: Double = 0.55
    @AppStorage(ScopesPrefsKeys.scopeGain) private var scopeGain: Double = 1.15

    private var currentScale: GraticuleLuminanceScale {
        defaultScale == "hdrPQNits" ? .hdrPQNits : .sdrIRE
    }

    private var currentMode: WaveformMode {
        WaveformMode(rawValue: Int(defaultModeRaw) ?? 0) ?? .luminance
    }

    var body: some View {
        Form {
            Section("Waveform") {
                Picker("Default luminance scale", selection: Binding(
                    get: { currentScale },
                    set: { defaultScale = $0 == .hdrPQNits ? "hdrPQNits" : "sdrIRE" }
                )) {
                    Text("SDR IRE").tag(GraticuleLuminanceScale.sdrIRE)
                    Text("HDR 10k nits").tag(GraticuleLuminanceScale.hdrPQNits)
                }
                Picker("Default waveform mode", selection: Binding(
                    get: { currentMode },
                    set: { defaultModeRaw = String($0.rawValue) }
                )) {
                    ForEach(WaveformMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Default log scale (Y axis)", isOn: $waveformLogScale)
            }
            Section("Scope intensity (SC-020)") {
                HStack {
                    Text("Default gain")
                    Slider(value: $scopeGain, in: 0.5...2.5, step: 0.05)
                    Text(String(format: "%.2f", scopeGain))
                        .frame(width: 36, alignment: .leading)
                        .monospacedDigit()
                }
                HStack {
                    Text("Default gamma")
                    Slider(value: $scopeGamma, in: 0.3...1.0, step: 0.05)
                    Text(String(format: "%.2f", scopeGamma))
                        .frame(width: 36, alignment: .leading)
                        .monospacedDigit()
                }
                Text("Brightness (gain) and phosphor curve (gamma). Apply from main window or restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("These apply to new scope panels and the main waveform scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio (UserDefaults) — AU-011 channel mapping

private enum AudioPrefsKeys {
    static let showRMS = "HDRApp.Prefs.Audio.ShowRMS"
    static let meterBallistics = "HDRApp.Prefs.Audio.MeterBallistics"
    static let channelMappingPreset = AudioChannelMappingPrefsKeys.channelMappingPreset
    static let channelMappingCustomLabels = AudioChannelMappingPrefsKeys.channelMappingCustomLabels
}

private struct AudioPreferencesPane: View {
    @AppStorage(AudioPrefsKeys.showRMS) private var showRMS: Bool = true
    @AppStorage(AudioPrefsKeys.meterBallistics) private var ballistics: String = "fast"
    @AppStorage(AudioPrefsKeys.channelMappingPreset) private var channelMappingPresetRaw: String = AudioChannelMappingPreset.numeric.rawValue
    @AppStorage(AudioPrefsKeys.channelMappingCustomLabels) private var channelMappingCustomLabelsJSON: String = ""

    /// Decode custom labels from JSON; return 16 strings (padded with "1"…"16" if needed).
    private static func decodeCustomLabels(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return (1...AudioChannelMappingConfig.maxChannels).map { "\($0)" }
        }
        var result = Array(arr.prefix(AudioChannelMappingConfig.maxChannels))
        for i in result.count..<AudioChannelMappingConfig.maxChannels {
            result.append("\(i + 1)")
        }
        return result
    }

    private static func encodeCustomLabels(_ labels: [String]) -> String {
        let arr = Array(labels.prefix(AudioChannelMappingConfig.maxChannels))
        guard let data = try? JSONEncoder().encode(arr) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    var body: some View {
        Form {
            Section("Meters") {
                Toggle("Show RMS levels", isOn: $showRMS)
                Picker("Meter ballistics", selection: $ballistics) {
                    Text("Fast").tag("fast")
                    Text("Slow").tag("slow")
                    Text("Peak hold").tag("peakHold")
                }
            }
            Section("Channel mapping (AU-011)") {
                Picker("Label preset", selection: $channelMappingPresetRaw) {
                    ForEach(AudioChannelMappingPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                if (AudioChannelMappingPreset(rawValue: channelMappingPresetRaw) ?? .numeric) == .custom {
                    ChannelMappingCustomLabelsEditor(
                        labelsJSON: $channelMappingCustomLabelsJSON,
                        decode: Self.decodeCustomLabels,
                        encode: Self.encodeCustomLabels
                    )
                }
                Text("Labels used on the 16-channel meter in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Audio meters appear in the main window status area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Custom channel labels editor (16 fields)

private struct ChannelMappingCustomLabelsEditor: View {
    @Binding var labelsJSON: String
    let decode: (String) -> [String]
    let encode: ([String]) -> String

    @State private var labels: [String] = (1...16).map { "\($0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom labels (Ch1–Ch16)")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 6) {
                ForEach(0..<AudioChannelMappingConfig.maxChannels, id: \.self) { index in
                    TextField("Ch\(index + 1)", text: Binding(
                        get: { index < labels.count ? labels[index] : "" },
                        set: { new in
                            var updated = labels
                            if index < updated.count {
                                updated[index] = new
                                labels = updated
                                labelsJSON = encode(updated)
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .onAppear {
            labels = decode(labelsJSON)
        }
        .onChange(of: labelsJSON) { _, newValue in
            labels = decode(newValue)
        }
    }
}

// MARK: - Network (UserDefaults)

private enum NetworkPrefsKeys {
    static let webRemotePort = "HDRApp.Prefs.Network.WebRemotePort"
    static let webRemoteEnabled = "HDRApp.Prefs.Network.WebRemoteEnabled"
    static let ndiEnabled = "HDRApp.Prefs.Network.NDIEnabled"
}

private struct NetworkPreferencesPane: View {
    @AppStorage(NetworkPrefsKeys.webRemoteEnabled) private var webRemoteEnabled: Bool = false
    @AppStorage(NetworkPrefsKeys.webRemotePort) private var webRemotePort: Int = 8765
    @AppStorage(NetworkPrefsKeys.ndiEnabled) private var ndiEnabled: Bool = false

    var body: some View {
        Form {
            Section("Web remote") {
                Toggle("Enable web remote control", isOn: $webRemoteEnabled)
                HStack {
                    Text("Port")
                    TextField("Port", value: $webRemotePort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .disabled(!webRemoteEnabled)
            }
            Section("NDI") {
                Toggle("Enable NDI receive", isOn: $ndiEnabled)
                Text("NDI source selection is in the Input menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
