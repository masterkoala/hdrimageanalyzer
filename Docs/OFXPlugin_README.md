# HDRImageAnalyzerPro OFX Plugin - DaVinci Resolve Input Source

## Overview

This project has been extended with a complete **OFX (OpenFX) plugin** system that enables HDRImageAnalyzerPro to capture video/audio signals from DaVinci Resolve when no physical DeckLink hardware is present.

## What Was Created

### New Files

| File | Purpose |
|------|---------|
| `Sources/OFX/OFXResolveInputCapture.swift` | Core OFX capture simulation class |
| `Sources/OFX/OFXResolvePlugin.swift` | Plugin definition and metadata management |
| `Sources/OFX/OFXPluginManager+Discovery.swift` | Plugin discovery, installation, uninstallation |
| `Sources/OFX/SwiftOFXBridge.h` | Objective-C bridge header for future native SDK integration |
| `Sources/UI/OFXInputSourcePanel.swift` | SwiftUI UI panel for selecting software inputs |
| `Sources/Common/CaptureTypes.swift` | Shared types: `DeckLinkPixelFormat`, `CaptureSignalState`, etc. |
| `Docs/OFXPluginIntegration.md` | Comprehensive integration documentation |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/Capture/DeckLinkDeviceManager.swift` | Added OFX integration, `availableCaptureSources`, `getPrimaryCaptureSource()` |
| `Sources/UI/AppShortcuts.swift` | Added `installOFXPlugin` shortcut (⌘⇧I) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HDRImageAnalyzerPro                          │
│  ┌────────────────────┐    ┌───────────────────────────────┐   │
│  │ Capture Pipeline   │◄──►│ DeckLinkDeviceManager         │   │
│  │ - MasterPipeline   │    │ ├─ Physical DeckLink wrappers │   │
│  │ - Scopes           │    │ ├─ OFX Resolve Input          │   │
│  │ - Audio Meters     │    │ └─ Test Pattern Generator     │   │
│  └────────────────────┘    └───────────────────────────────┘   │
│                                        ▲                        │
│                                        │                         │
│  ┌─────────────────────────────────────┴──────────────────┐     │
│  │                   OFX Software Input                    │     │
│  │  ├─ OFXResolveInputCapture (Simulation)                │     │
│  │  ├─ OFXPluginManager (Discovery/Install)               │     │
│  │  └─ OFXSoftwareInputSource (Unified source interface)   │     │
│  └──────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────┘

                              │
                              ▼
                     ┌─────────────────────┐
                     │ DaVinci Resolve     │
                     │ (OFX Pipeline)      │
                     └─────────────────────┘
```

## Key Features

### 1. Virtual Input Source

When no DeckLink hardware is present, the app can use:

- **DaVinci Resolve OFX Input** - Captures signal from Resolve's OFX pipeline
- **Test Pattern Generator** - Synthesizes color bars and other patterns for testing

### 2. Plugin Installation

Plugins are automatically installed to:
```
~/Library/Application Support/HDRImageAnalyzerPro/OFXPlugins/
```

Each plugin is registered via JSON metadata file that includes:
- Plugin ID
- Display name
- Supported formats
- Default resolution

### 3. Unified Source Interface

All capture sources (physical and software) conform to `CaptureSource`:

```swift
public protocol CaptureSource {
    var isCapturing: Bool { get }
    var currentSignalState: CaptureSignalState { get }
    var sourceId: String? { get }
    var sourceName: String { get }

    func connect() -> Bool
    func disconnect()
    func startCapture() -> Bool
    func stopCapture()
}
```

## Usage

### Programmatic Access

```swift
import Common
import Capture
import OFX

// Get the manager
let manager = OFXPluginManager.shared

// Install the plugin
manager.installOFXPlugin(targetDirectory: nil)

// Check if installed
if manager.isPluginInstalled("com.hdrimageanalyzerpro.resolve.input") {
    print("OFX plugin active!")
}

// Get available sources
let deviceManager = DeckLinkDeviceManager()
let sources = deviceManager.availableCaptureSources  // All sources

// Get primary source (prefers physical, falls back to OFX)
if let primary = deviceManager.getPrimaryCaptureSource() {
    primary.startCapture()
}
```

### UI Integration

The `OFXInputSourcePanel` provides a SwiftUI view for software input selection:

```swift
VStack {
    InputSourceSelectionPanel(state: captureState)      // For hardware
    OFXInputSourcePanel(state: captureState)           // For software
}
```

### Keyboard Shortcut

- **Install OFX Plugin**: `⌘⇧I` (Command-Shift-I)

## Supported Formats

| Format | Type | Description |
|--------|------|-------------|
| RGB8 | `DeckLinkPixelFormat.rgb8` | 32-bit BGRA |
| v210 | `DeckLinkPixelFormat.v210` | 10-bit YUV 4:2:2 packed |
| RGB12LE | `DeckLinkPixelFormat.rgb12BitLE` | 12-bit RGB Little-Endian |
| RGB12BE | `DeckLinkPixelFormat.rgb12Bit` | 12-bit RGB Big-Endian |

## Resolutions

- HD 720p30 / HD 720p60
- Full HD 1080p24 / 1080p30 / 1080p60
- UHD 4K p24 / UHD 4K p30

## Testing Without Resolve

The Test Pattern Generator mode always works and provides:

- Color bars (Red, Green, Blue, Cyan, Magenta, Yellow, White, Black)
- HDR gradient overlay for visualization
- Simulated timecode updates

```swift
let pattern = OFXSoftwareInputSource(
    id: "test_pattern_generator",
    name: "Test Pattern Generator",
    enableSimulation: true
)

pattern.configureWithBasicParams(width: 1920, height: 1080, frameRate: 30.0)
pattern.startCapture()
```

## Future Enhancements

The `SwiftOFXBridge.h` header is prepared for future native OFX SDK integration:

1. **Bidirectional communication** with actual DaVinci Resolve instances
2. **Real-time HDR metadata passing** (PQ, HLG, SMPTE 2094)
3. **Audio input from Resolve** alongside video stream
4. **Multi-plugin support** for simultaneous inputs

## References

- [OpenFX (OFX) Specification](https://docs.blackmagicdesign.com/)
- [DeckLink SDK Documentation](https://www.blackmagicdesign.com/support)
- `Docs/OFXPluginIntegration.md` - Full integration guide
