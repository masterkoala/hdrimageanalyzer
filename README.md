# HDRImageAnalyzerPro

Swift Package (macOS **14+**) — HDR analysis tooling with Metal, scopes, capture (including DeckLink bridge), and related modules.  
Executable product: **`HDRAnalyzerProApp`**.

## Requirements

- Xcode **15+** (Swift 5.9 toolchain)
- macOS **14+** (see `Package.swift` platforms)

## Build

```bash
swift build -c release
```

Run the app (after a successful build):

```bash
swift run HDRAnalyzerProApp
```

Or open `Package.swift` in Xcode and use the **HDRAnalyzerProApp** scheme.

## Vendor / SDK notes

- **DeckLink**: Headers and samples under `Vendor/DeckLinkSDK/` are used for the capture bridge. If you clone this repo, ensure your use complies with **Blackmagic Design** SDK license terms for redistribution.
- See `Vendor/README.md` and `Docs/` for integration notes.

## Tests

```bash
swift test
```

