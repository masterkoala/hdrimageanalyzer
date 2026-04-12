// CS-011: .cube 3D/1D LUT parser; load to MTLTexture3D or buffer.
import Foundation
import Metal
import Logging
import Common

// MARK: - Cube LUT model

/// Parsed .cube LUT: optional title, 3D or 1D size, and R G B table (0–1 float).
/// 3D: table has size³ entries of (R,G,B) → table.count == size³ * 3. Index order: R inner, G middle, B outer (r + g*size + b*size²).
/// 1D: table has size entries of (R,G,B) → table.count == size * 3.
public struct CubeLUT: Sendable {
    public var title: String?
    /// True if LUT_3D_SIZE was specified; false if LUT_1D_SIZE.
    public var is3D: Bool
    /// LUT_3D_SIZE or LUT_1D_SIZE (e.g. 17, 33, 65).
    public var size: Int
    /// RGB values 0–1. 3D: size³*3 (order r, g, b: index = (r + g*size + b*size²)*3). 1D: size*3.
    public var table: [Float]

    public init(title: String? = nil, is3D: Bool, size: Int, table: [Float]) {
        self.title = title
        self.is3D = is3D
        self.size = size
        self.table = table
    }

    /// Expected table count: 3D → size³*3, 1D → size*3.
    public var expectedTableCount: Int {
        is3D ? (size * size * size * 3) : (size * 3)
    }

    public var isValid: Bool {
        size > 0 && table.count >= expectedTableCount
    }
}

// MARK: - Parser

/// Parses .cube format: optional TITLE, LUT_3D_SIZE or LUT_1D_SIZE, then R G B lines (floats).
public enum CubeLUTParser {
    /// Parse from UTF-8 string (e.g. file contents).
    public static func parse(_ string: String) -> Result<CubeLUT, CubeLUTError> {
        var title: String?
        var lut3DSize: Int?
        var lut1DSize: Int?
        var dataLines: [String] = []

        let lines = string.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.uppercased().hasPrefix("TITLE") {
                if let q = trimmed.firstIndex(of: "\""), let q2 = trimmed[trimmed.index(after: q)...].firstIndex(of: "\"") {
                    title = String(trimmed[trimmed.index(after: q)..<q2])
                }
                continue
            }
            if trimmed.uppercased().hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count >= 2, let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    lut3DSize = n
                }
                continue
            }
            if trimmed.uppercased().hasPrefix("LUT_1D_SIZE") {
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if parts.count >= 2, let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    lut1DSize = n
                }
                continue
            }
            // Data line: three floats
            dataLines.append(trimmed)
        }

        let is3D: Bool
        let size: Int
        if let n = lut3DSize, n > 0 {
            is3D = true
            size = n
        } else if let n = lut1DSize, n > 0 {
            is3D = false
            size = n
        } else {
            return .failure(.missingSize)
        }

        let expectedCount = is3D ? (size * size * size * 3) : (size * 3)
        var table: [Float] = []
        table.reserveCapacity(expectedCount)
        for line in dataLines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            guard let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                return .failure(.invalidDataLine(line: String(line)))
            }
            table.append(r)
            table.append(g)
            table.append(b)
        }
        if table.count < expectedCount {
            return .failure(.insufficientData(expected: expectedCount, got: table.count))
        }
        let lut = CubeLUT(title: title, is3D: is3D, size: size, table: Array(table.prefix(expectedCount)))
        return .success(lut)
    }

    /// Parse from file URL.
    public static func parse(url: URL) -> Result<CubeLUT, CubeLUTError> {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8) else {
            return .failure(.fileReadFailed(url: url))
        }
        return parse(string)
    }

    /// Parse from raw data (UTF-8).
    public static func parse(data: Data) -> Result<CubeLUT, CubeLUTError> {
        guard let string = String(data: data, encoding: .utf8) else {
            return .failure(.invalidEncoding)
        }
        return parse(string)
    }
}

public enum CubeLUTError: Error, Sendable {
    case missingSize
    case invalidDataLine(line: String)
    case insufficientData(expected: Int, got: Int)
    case fileReadFailed(url: URL)
    case invalidEncoding
}

// MARK: - Metal loader (MTLTexture3D / 1D or buffer)

/// Load a parsed CubeLUT into Metal texture or buffer.
public enum CubeLUTMetalLoader {
    /// Create a 3D texture (size × size × size) RGBA32Float from a 3D cube. Alpha = 1. Fails if cube is 1D or invalid.
    public static func makeTexture3D(device: MTLDevice, cube: CubeLUT) -> MTLTexture? {
        guard cube.is3D, cube.isValid else { return nil }
        let n = cube.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.pixelFormat = .rgba32Float
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerPixel = 16
        let bytesPerRow = n * bytesPerPixel
        let bytesPerSlice = n * bytesPerRow
        var slice = [Float](repeating: 0, count: n * n * 4)
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let idx = (x + y * n + z * n * n) * 3
                    slice[(y * n + x) * 4 + 0] = cube.table[idx]
                    slice[(y * n + x) * 4 + 1] = cube.table[idx + 1]
                    slice[(y * n + x) * 4 + 2] = cube.table[idx + 2]
                    slice[(y * n + x) * 4 + 3] = 1.0
                }
            }
            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: z), size: MTLSize(width: n, height: n, depth: 1))
            slice.withUnsafeBytes { ptr in
                texture.replace(region: region, mipmapLevel: 0, slice: z, withBytes: ptr.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerSlice)
            }
        }
        return texture
    }

    /// Create a 1D texture (width = size) RGBA32Float from a 1D cube. Alpha = 1. Fails if cube is 3D or invalid.
    public static func makeTexture1D(device: MTLDevice, cube: CubeLUT) -> MTLTexture? {
        guard !cube.is3D, cube.isValid else { return nil }
        let n = cube.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.width = n
        descriptor.height = 1
        descriptor.depth = 1
        descriptor.pixelFormat = .rgba32Float
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [Float](repeating: 0, count: n * 4)
        for i in 0..<n {
            pixels[i * 4 + 0] = cube.table[i * 3]
            pixels[i * 4 + 1] = cube.table[i * 3 + 1]
            pixels[i * 4 + 2] = cube.table[i * 3 + 2]
            pixels[i * 4 + 3] = 1.0
        }
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: n, height: 1, depth: 1))
        pixels.withUnsafeBytes { ptr in
            texture.replace(region: region, mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: n * 16)
        }
        return texture
    }

    /// Create texture appropriate for cube: 3D → MTLTexture3D, 1D → MTLTexture1D.
    public static func makeTexture(device: MTLDevice, cube: CubeLUT) -> MTLTexture? {
        cube.is3D ? makeTexture3D(device: device, cube: cube) : makeTexture1D(device: device, cube: cube)
    }

    /// Create a shared MTLBuffer containing the LUT table (Float array). 3D: size³*3 floats; 1D: size*3. Use for GPU sampling if texture path is not used.
    public static func makeBuffer(device: MTLDevice, cube: CubeLUT) -> MTLBuffer? {
        guard cube.isValid else { return nil }
        let count = cube.table.count
        return cube.table.withUnsafeBytes { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: count * MemoryLayout<Float>.size, options: .storageModeShared)
        }
    }
}
