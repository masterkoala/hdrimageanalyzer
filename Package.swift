// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HDRImageAnalyzerPro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HDRAnalyzerProApp", targets: ["HDRAnalyzerProApp"]),
        .library(name: "HDRImageAnalyzerPro", type: .dynamic, targets: ["Capture", "MetalEngine", "Scopes", "Color", "Audio", "Metadata", "HDRUI", "Network"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // MARK: - Foundation (no internal deps)
        .target(name: "Common", dependencies: [], path: "Sources/Common"),
        .target(name: "Logging", dependencies: [], path: "Sources/Logging"),

        // MARK: - OFX Integration
        .target(name: "OFX", dependencies: ["Common", "Logging"], path: "Sources/OFX"),

        // MARK: - DeckLink (C++ bridge + Swift)
        .target(
            name: "DeckLinkBridge",
            dependencies: [],
            path: "Sources/Capture/Bridge",
            exclude: ["DeckLinkBridge.h"],
            sources: ["DeckLinkBridge.mm", "DeckLinkAPIDispatch.cpp"],
            publicHeadersPath: ".",
            cxxSettings: [.headerSearchPath("../../../Vendor/DeckLinkSDK/include")]
        ),
        .target(name: "Capture", dependencies: ["Common", "Logging", "DeckLinkBridge"], path: "Sources/Capture", exclude: ["Bridge"]),

        // MARK: - Metal (exclude alternate/legacy implementations; app uses MetalEngine.swift + MasterPipeline.swift only)
        .target(
            name: "MetalEngine",
            dependencies: ["Common", "Logging"],
            path: "Sources/Metal",
            exclude: [
                "FixReport.md",
                "Fix.v2.swift",
                "ShaderCompiler.swift",
                "WorkingMetalEngine.swift",
                "WorkingMasterPipeline.swift",
            ]
        ),

        // MARK: - Scopes, Color, Audio, Metadata
        .target(name: "Scopes", dependencies: ["Common", "Logging", "MetalEngine"], path: "Sources/Scopes"),
        .target(name: "Color", dependencies: ["Common", "Logging"], path: "Sources/Color"),
        .target(name: "Audio", dependencies: ["Common", "Logging", .product(name: "Atomics", package: "swift-atomics")], path: "Sources/Audio"),
        .target(name: "Metadata", dependencies: ["Common", "Logging", "Capture"], path: "Sources/Metadata"),

        // MARK: - UI & Network
        .target(
            name: "HDRUI",
            dependencies: ["Common", "Logging", "MetalEngine", "Capture", "Scopes", "Audio", "Metadata", "Color", "Network", "OFX"],
            path: "Sources/UI"
        ),
        .target(name: "Network", dependencies: ["Common", "Logging"], path: "Sources/Network", resources: [.process("Resources")]),

        // MARK: - App & Dashboard
        .executableTarget(name: "HDRAnalyzerProApp", dependencies: ["Common", "Logging", "HDRUI", "Capture", "MetalEngine", "Audio", "Network", "OFX"], path: "Sources/App", resources: [.process("Resources")], swiftSettings: [.unsafeFlags(["-parse-as-library"])]),

        // MARK: - Tests (F-007: XCTest target per module)
        .testTarget(name: "CommonTests", dependencies: ["Common"], path: "Tests/CommonTests"),
        .testTarget(name: "LoggingTests", dependencies: ["Logging"], path: "Tests/LoggingTests"),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Common"], path: "Tests/CaptureTests"),
        .testTarget(name: "MetalEngineTests", dependencies: ["MetalEngine", "Common"], path: "Tests/MetalEngineTests"),
        .testTarget(name: "ScopesTests", dependencies: ["Scopes"], path: "Tests/ScopesTests", resources: [.process("VisualQAChecklist.md")]),
        .testTarget(name: "ColorTests", dependencies: ["Color"], path: "Tests/ColorTests", resources: [.process("Resources")]),
        .testTarget(name: "AudioTests", dependencies: ["Audio"], path: "Tests/AudioTests"),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"], path: "Tests/MetadataTests"),
        .testTarget(name: "HDRUITests", dependencies: ["HDRUI"], path: "Tests/HDRUITests"),
        .testTarget(name: "NetworkTests", dependencies: ["Network"], path: "Tests/NetworkTests"),
        .testTarget(name: "IntegrationTests", dependencies: ["Capture", "MetalEngine", "Common", "Logging"], path: "Tests/IntegrationTests"),
    ]
)
