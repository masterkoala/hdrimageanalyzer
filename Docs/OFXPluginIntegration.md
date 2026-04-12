# OFX Plugin Integration for DaVinci Resolve

This document describes the OFX (OpenFX) plugin integration that enables HDRImageAnalyzerPro to capture video signal from DaVinci Resolve when no DeckLink hardware is present.

## Overview

The **OFXResolveInputCapture** module provides a software-based input source that bridges HDRImageAnalyzerPro with DaVinci Resolve's OFX pipeline. This allows you to:

- Use HDRImageAnalyzerPro without physical DeckLink capture cards
- Capture signal from Resolve's timeline or media storage
- Generate test patterns for calibration and testing
- Simulate various video formats and resolutions

## Architecture

### Components

| Module | Description |
|--------|-------------|
| `OFXResolveInputCapture` | Core class that manages OFX input simulation |
| `OFXResolvePlugin` | Plugin definition and metadata management |
| `OFXPluginManager+Discovery` | Discovery, installation, and uninstallation logic |
| `SwiftOFXBridge.h` | Objective-C bridge for future native OFX SDK integration |
| `OFXInputSourcePanel` | SwiftUI UI panel for selecting software inputs |

### Data Flow

```
┌─────────────────────┐     ┌──────────────────────────┐     ┌─────────────────────┐
│   DaVinci Resolve   │ ←→  │   OFXResolveInputCapture │ →→→ │   HDRAnalyzerPro    │
│   (OFX Pipeline)    │     │         (Simulation)      │     │   Capture Pipeline  │
└─────────────────────┘     └──────────────────────────┘     └─────────────────────┘
```

## Usage

### 1. Install the OFX Plugin

The plugin can be installed automatically from within the application:

```swift
let manager = OFXPluginManager.shared
manager.installOFXPlugin(targetDirectory: nil) // Installs to Application Support
```

Or via command line:
```bash
# Install using app's entry point
HDRAnalyzerProApp --install-ofx-plugin
```

The plugin is installed to:
```
~/Library/Application Support/HDRImageAnalyzerPro/OFXPlugins/com.hdrimageanalyzerpro.resolve.input/
```

### 2. Configure Capture Source

Select the OFX input source in the UI panel or programmatically:

```swift
let captureSource = OFXSoftwareInputSource(
    id: "ofx_resolve_input",
    name: "DaVinci Resolve OFX Input",
    isPhysicalDevice: false,
    ofxPluginId: "com.hdrimageanalyzerpro.resolve.input"
)

// Configure capture parameters
captureSource.configureCapture(
    width: 1920,
    height: 1080,
    frameRate: 29.97,
    pixelFormat: .rgb8
)

// Start capture
captureSource.startCapture()
```

### 3. Use Test Pattern Generator

For calibration without external input:

```swift
let testPattern = OFXSoftwareInputSource(
    id: "test_pattern_generator",
    name: "Test Pattern Generator",
    enableSimulation: true
)

testPattern.configureCapture(
    width: 1920,
    height: 1080,
    frameRate: 30.0,
    pixelFormat: .rgb8
)

testPattern.startCapture()
```

### 4. Check Plugin Status

```swift
let manager = OFXPluginManager.shared
if manager.isPluginInstalled("com.hdrimageanalyzerpro.resolve.input") {
    print("OFX plugin is installed and active")
} else {
    print("OFX plugin not installed")
}
```

## Supported Formats

| Format | Pixel Format | Description |
|--------|-------------|-------------|
| RGB8 | `kCVPixelFormatType_32BGRA` | 8-bit per channel RGBA (standard) |
| v210 | `OFX::PIXF_YCBCR709_10BIT` | 10-bit YUV 4:2:2 packed |
| RGB12LE | `OFX::PIXF_RGB16_LE` | 12-bit RGB Little-Endian |
| RGB12BE | `OFX::PIXF_RGB16_BE` | 12-bit RGB Big-Endian |

## Resolutions

The following resolutions are supported:

- HD 720p30 / HD 720p60
- Full HD 1080p24 / 1080p30 / 1080p60
- UHD 4K p24 / 4K p30

## Plugin Manifest Structure

When installed, the plugin includes:

```json
{
  "pluginId": "com.hdrimageanalyzerpro.resolve.input",
  "displayName": "HDRImagePro Resolve Input",
  "version": "1.0.0",
  "isInputPlugin": true,
  "supportedFormats": ["OFX::PIXF_RGBA32", "OFX::PIXF_YCBCR709_10BIT"],
  "defaultResolution": "1920x1080@29.97"
}
```

## Development Notes

### Testing Without Resolve

To test the OFX input without an actual DaVinci Resolve instance:

1. Use the **Test Pattern Generator** mode (always available)
2. Generate synthetic frames using `generateTestPattern()` method
3. Simulate timecode updates for testing capture timing

### Adding to DeckLinkDeviceManager

The existing `DeckLinkDeviceManager` now includes methods for OFX integration:

- `availableCaptureSources` - Returns all sources including software inputs
- `getPrimaryCaptureSource()` - Returns best available input (hardware > OFX > simulation)

```swift
let deviceManager = DeckLinkDeviceManager()
if let primarySource = deviceManager.getPrimaryCaptureSource() {
    // Use the source regardless of type
    startCapture(from: primarySource)
}
```

### UI Integration

The `OFXInputSourcePanel` provides a SwiftUI view for selecting software inputs. Add it to your main view hierarchy:

```swift
VStack {
    InputSourceSelectionPanel(state: captureState)  // For hardware DeckLink
    OFXInputSourcePanel(state: captureState)        // For software inputs
}
```

## Future Enhancements

1. **Native OFX SDK Integration** - Direct bidirectional communication with Resolve's actual OFX pipeline
2. **Multi-Plugin Support** - Allow multiple OFX plugins to be active simultaneously
3. **Audio Input from Resolve** - Capture audio stream alongside video
4. **Real-time Metadata** - Pass HDR metadata (PQ, HLG) through the OFX bridge

## Troubleshooting

### Plugin Not Detected

```bash
# Check if plugin files exist
ls ~/Library/Application\ Support/HDRImageAnalyzerPro/OFXPlugins/

# Verify JSON registration file
cat ~/Library/Application\ Support/HDRImageAnalyzerPro/OFXPlugins/com.hdrimageanalyzerpro.resolve.input.json
```

### Capture Not Starting

Check logs for errors:
```swift
HDRLogger.info(category: "OFX", message: "Debug capture state")
print("Signal State:", captureSource.currentSignalState)
print("Is Capturing:", captureSource.isCapturing)
```

## References

- [OpenFX (OFX) Format Specification](https://www.blackmagicdesign.com/products/davinciresolve/mac-os/)
- [DeckLink API Reference](https://www.blackmagicdesign.com/support)
- HDRImageAnalyzerPro Project Documentation
