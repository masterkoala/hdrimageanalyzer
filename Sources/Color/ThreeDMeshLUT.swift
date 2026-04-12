// CS-014: .3dmesh binary 3D LUT parser. Produces CubeLUT for use with CubeLUTMetalLoader (CS-011/CS-012).
import Foundation

// MARK: - .3dmesh binary format

/// Binary .3dmesh layout: magic "3DMH" (4 bytes), size UInt32 (4 bytes), then size³×3 Float32 (R,G,B, r inner).
/// Table order matches CubeLUT: index = (r + g*size + b*size²)*3 for 0 ≤ r,g,b < size.
private let threeDMeshMagic: [UInt8] = [0x33, 0x44, 0x4D, 0x48] // "3DMH"

// MARK: - Parser

/// Parses .3dmesh binary 3D LUT files. Output is a CubeLUT (is3D: true) for use with existing pipeline.
public enum ThreeDMeshLUTParser {
    /// Parse from raw file data.
    public static func parse(data: Data) -> Result<CubeLUT, ThreeDMeshLUTError> {
        let headerSize = 8
        guard data.count >= headerSize else {
            return .failure(.fileTooShort(got: data.count))
        }
        var offset = 0
        let magic = data.subdata(in: offset..<(offset + 4))
        offset += 4
        guard magic.elementsEqual(threeDMeshMagic) else {
            return .failure(.invalidMagic)
        }
        let size32 = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
        offset += 4
        let size = Int(size32)
        guard size >= 2, size <= 256 else {
            return .failure(.invalidSize(size))
        }
        let expectedBytes = size * size * size * 3 * MemoryLayout<Float>.size
        guard data.count >= headerSize + expectedBytes else {
            return .failure(.insufficientData(expected: headerSize + expectedBytes, got: data.count))
        }
        var table: [Float] = []
        table.reserveCapacity(size * size * size * 3)
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: headerSize).assumingMemoryBound(to: Float.self)
            let count = size * size * size * 3
            for i in 0..<count {
                table.append(ptr[i])
            }
        }
        let cube = CubeLUT(title: nil, is3D: true, size: size, table: table)
        guard cube.isValid else {
            return .failure(.invalidTable)
        }
        return .success(cube)
    }

    /// Parse from file URL.
    public static func parse(url: URL) -> Result<CubeLUT, ThreeDMeshLUTError> {
        do {
            let data = try Data(contentsOf: url)
            return parse(data: data)
        } catch {
            return .failure(.fileReadFailed(url: url, underlying: error))
        }
    }
}

public enum ThreeDMeshLUTError: Error, Sendable {
    case invalidMagic
    case invalidSize(Int)
    case fileTooShort(got: Int)
    case insufficientData(expected: Int, got: Int)
    case invalidTable
    case fileReadFailed(url: URL, underlying: Error)
}
