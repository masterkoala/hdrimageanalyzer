// UI-009: LUT file browser and drag-and-drop loading. Depends on CS-011 (CubeLUT), CS-014 (.3dmesh).
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Logging
import Common
import MetalEngine
import Color

// MARK: - LUT load state

/// State for the currently loaded LUT (UI-009). Parsed from .cube (CS-011) or .3dmesh (CS-014); texture created for pipeline (CS-012).
/// CS-013: useTetrahedralInterpolation = true selects highest quality (tetrahedral) LUT interpolation.
public final class LUTLoadState: ObservableObject {
    @Published public var loadedURL: URL?
    @Published public var displayName: String = "No LUT"
    @Published public var lutTexture: MTLTexture?
    @Published public var errorMessage: String?
    @Published public var is3D: Bool = false
    @Published public var lutSize: Int = 0
    /// CS-013: When true, use tetrahedral interpolation (highest quality); otherwise trilinear.
    @Published public var useTetrahedralInterpolation: Bool = false

    private let logCategory = "UI.LUT"

    public init() {}

    /// Load .cube or .3dmesh from URL: parse (CS-011 / CS-014) and create MTLTexture for pipeline. Clears previous load on failure.
    public func load(from url: URL) {
        errorMessage = nil
        let ext = url.pathExtension.lowercased()
        let result: Result<CubeLUT, Error> = ext == "3dmesh"
            ? ThreeDMeshLUTParser.parse(url: url).mapError { $0 as Error }
            : CubeLUTParser.parse(url: url).mapError { $0 as Error }
        switch result {
        case .success(let cube):
            displayName = url.lastPathComponent
            loadedURL = url
            is3D = cube.is3D
            lutSize = cube.size
            guard let device = MetalEngine.shared?.device else {
                errorMessage = "Metal device unavailable"
                lutTexture = nil
                return
            }
            lutTexture = CubeLUTMetalLoader.makeTexture(device: device, cube: cube)
            if lutTexture == nil {
                errorMessage = "Failed to create LUT texture"
            } else {
                HDRLogger.info(category: logCategory, "LUT loaded: \(displayName) (\(cube.size)×\(cube.is3D ? "3D" : "1D"))")
            }
        case .failure(let err):
            loadedURL = nil
            displayName = "No LUT"
            lutTexture = nil
            is3D = false
            lutSize = 0
            errorMessage = lutErrorString(err)
            HDRLogger.error(category: logCategory, "LUT parse failed: \(errorMessage ?? "")")
        }
    }

    public func clear() {
        loadedURL = nil
        displayName = "No LUT"
        lutTexture = nil
        errorMessage = nil
        is3D = false
        lutSize = 0
    }

    private func lutErrorString(_ err: Error) -> String {
        if let cubeErr = err as? CubeLUTError {
            switch cubeErr {
            case .missingSize: return "Missing LUT_3D_SIZE or LUT_1D_SIZE"
            case .invalidDataLine(let line): return "Invalid data line: \(line.prefix(40))..."
            case .insufficientData(let expected, let got): return "Insufficient data: expected \(expected), got \(got)"
            case .fileReadFailed(let url): return "Cannot read file: \(url.lastPathComponent)"
            case .invalidEncoding: return "File is not valid UTF-8"
            }
        }
        if let meshErr = err as? ThreeDMeshLUTError {
            switch meshErr {
            case .invalidMagic: return "Invalid .3dmesh magic"
            case .invalidSize(let n): return "Invalid .3dmesh size: \(n)"
            case .fileTooShort(let got): return "File too short: \(got) bytes"
            case .insufficientData(let expected, let got): return "Insufficient .3dmesh data: expected \(expected), got \(got)"
            case .invalidTable: return "Invalid .3dmesh table"
            case .fileReadFailed(let url, _): return "Cannot read file: \(url.lastPathComponent)"
            }
        }
        return err.localizedDescription
    }
}

// MARK: - LUT file browser view (UI-009)

/// LUT file browser with drag-and-drop and Open panel. Uses CS-011 (.cube) and CS-014 (.3dmesh) parsers; loads texture for pipeline.
public struct LUTBrowserView: View {
    @ObservedObject private var lutState: LUTLoadState
    @State private var isDropTarget = false

    public init(lutState: LUTLoadState) {
        self.lutState = lutState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LUT")
                .font(.headline)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                openButton
                if lutState.loadedURL != nil {
                    clearButton
                }
            }
            dropZone
            if let name = lutState.loadedURL?.lastPathComponent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if lutState.lutSize > 0 {
                        Text("(\(lutState.lutSize)×\(lutState.is3D ? "3D" : "1D"))")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            if lutState.is3D && lutState.loadedURL != nil {
                Toggle(isOn: Binding(
                    get: { lutState.useTetrahedralInterpolation },
                    set: { lutState.useTetrahedralInterpolation = $0 }
                )) {
                    Text("Highest quality (tetrahedral)")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }
            if let err = lutState.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .frame(minWidth: 280)
    }

    private var openButton: some View {
        Button("Open LUT…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data, UTType(filenameExtension: "3dmesh") ?? .data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                lutState.load(from: url)
            }
        }
    }

    private var clearButton: some View {
        Button("Clear") {
            lutState.clear()
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [6]))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            .frame(minHeight: 56)
            .overlay(
                Text("Drop .cube or .3dmesh file here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            )
            .onDrop(of: [.fileURL, .data], isTargeted: $isDropTarget) { providers in
                acceptDrop(providers: providers)
            }
    }

    private func acceptDrop(providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "cube" || ext == "3dmesh" else { return }
                    DispatchQueue.main.async {
                        lutState.load(from: url)
                    }
                }
                return true
            }
        }
        return false
    }
}
